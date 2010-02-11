# Copyright (C) 2008-2010, Sebastian Riedel.

package Mojo::IOLoop;

use strict;
use warnings;

use base 'Mojo::Base';
use bytes;

use Carp 'croak';
use IO::Poll qw/POLLERR POLLHUP POLLIN POLLOUT/;
use IO::Socket;
use Mojo::ByteStream;
use Socket qw/IPPROTO_TCP TCP_NODELAY/;

use constant CHUNK_SIZE => $ENV{MOJO_CHUNK_SIZE} || 8192;

# Epoll support requires IO::Epoll
use constant EPOLL => ($ENV{MOJO_POLL} || $ENV{MOJO_KQUEUE})
  ? 0
  : eval { require IO::Epoll; 1 };

# IPv6 support requires IO::Socket::INET6
use constant IPV6 => $ENV{MOJO_NO_IPV6}
  ? 0
  : eval { require IO::Socket::INET6; 1 };

# KQueue support requires IO::KQueue
use constant KQUEUE => ($ENV{MOJO_POLL} || $ENV{MOJO_EPOLL})
  ? 0
  : eval { require IO::KQueue; 1 };

# TLS support requires IO::Socket::SSL
use constant TLS => $ENV{MOJO_NO_TLS}
  ? 0
  : eval { require IO::Socket::SSL; 1 };

__PACKAGE__->attr(
    [qw/lock_cb unlock_cb/] => sub {
        sub {1}
    }
);
__PACKAGE__->attr([qw/accept_timeout connect_timeout/] => 5);
__PACKAGE__->attr(max_connections                      => 1000);
__PACKAGE__->attr(timeout                              => '0.1');

__PACKAGE__->attr([qw/_connections _fds _listen _timers/] => sub { {} });
__PACKAGE__->attr([qw/_listening _running/]);
__PACKAGE__->attr(
    _loop => sub {

        # Initialize as late as possible because kqueues don't survive a fork
        return IO::KQueue->new if KQUEUE;
        return IO::Epoll->new  if EPOLL;
        return IO::Poll->new;
    }
);

# Singleton
our $LOOP;

sub new {
    my $self = shift->SUPER::new(@_);

    # Ignore PIPE signal
    $SIG{PIPE} = 'IGNORE';

    return $self;
}

sub connect {
    my $self = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Options (TLS handshake only works blocking)
    my %options = (
        Blocking => $args->{tls} ? 1 : 0,
        PeerAddr => $args->{address},
        PeerPort => $args->{port} || ($args->{tls} ? 443 : 80),
        Proto    => 'tcp',
        Type     => SOCK_STREAM
    );

    # TLS certificate verification
    if ($args->{tls} && $args->{tls_ca_file}) {
        $options{SSL_ca_file}         = $args->{tls_ca_file};
        $options{SSL_verify_mode}     = 0x01;
        $options{SSL_verify_callback} = $args->{tls_verify_cb};
    }

    # New connection
    my $class =
        TLS && $args->{tls} ? 'IO::Socket::SSL'
      : IPV6 ? 'IO::Socket::INET6'
      :        'IO::Socket::INET';
    my $socket = $class->new(%options) or return;
    my $id = "$socket";

    # Non blocking
    $socket->blocking(0);

    # Disable Nagle's algorithm
    setsockopt $socket, IPPROTO_TCP, TCP_NODELAY, 1;

    # Add connection
    $self->_connections->{$id} = {
        buffer     => Mojo::ByteStream->new,
        connect_cb => $args->{cb},
        connecting => 1,
        socket     => $socket
    };

    # Timeout
    $self->_connections->{$id}->{connect_timer} = $self->timer(
        $id => (
            after => $self->connect_timeout,
            cb    => sub { shift->_error($id, 'Connect timeout.') }
        )
    );

    # File descriptor
    my $fd = fileno $socket;
    $self->_fds->{$fd} = $id;

    # Add socket to poll
    $self->writing($id);

    return $id;
}

sub connection_timeout {
    my ($self, $id, $timeout) = @_;
    $self->_connections->{$id}->{timeout} = $timeout and return $self
      if $timeout;
    return $self->_connections->{$id}->{timeout};
}

sub drop {
    my ($self, $id) = @_;

    # Finish connection once buffer is empty
    if (my $c = $self->_connections->{$id}) {
        $self->_connections->{$id}->{finish} = 1;
        return $self;
    }

    # Drop
    return $self->_drop($id);
}

sub error_cb { shift->_add_event('error', @_) }

sub generate_port {
    my $self = shift;

    # Ports
    my $port = 1 . int(rand 10) . int(rand 10) . int(rand 10) . int(rand 10);
    while ($port++ < 30000) {

        # Try port
        return $port
          if IO::Socket::INET->new(
            Listen    => 5,
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp'
          );
    }

    # Nothing
    return;
}

sub hup_cb { shift->_add_event('hup', @_) }

# Fat Tony is a cancer on this fair city!
# He is the cancer and I am the… uh… what cures cancer?
sub listen {
    my $self = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Options (TLS handshake only works blocking)
    my %options = (
        Blocking => $args->{tls} ? 1 : 0,
        Listen => $args->{queue_size} || SOMAXCONN,
        Type => SOCK_STREAM
    );

    # Listen on UNIX domain socket
    my $socket;
    if (my $file = $args->{file}) {

        # Path
        $options{Local} = $file;

        # Create socket
        $socket = IO::Socket::UNIX->new(%options)
          or croak "Can't create listen socket: $!";
    }

    # Listen on port
    else {

        # Socket options
        my $address = $args->{address};
        $options{LocalAddr} = $address if $address;
        $options{LocalPort} = $args->{port} || 3000;
        $options{Proto}     = 'tcp';
        $options{ReuseAddr} = 1;
        my $cert = $args->{tls_cert};
        $options{SSL_cert_file} = $cert if $cert;
        my $key = $args->{tls_key};
        $options{SSL_key_file} = $key if $key;

        # Create socket
        my $class =
            TLS && $args->{tls} ? 'IO::Socket::SSL'
          : IPV6 ? 'IO::Socket::INET6'
          :        'IO::Socket::INET';
        $socket = $class->new(%options)
          or croak "Can't create listen socket: $!";
    }
    my $id = "$socket";

    # Add listen socket
    $self->_listen->{$id} =
      {cb => $args->{cb}, file => $args->{file} ? 1 : 0, socket => $socket};

    # File descriptor
    my $fd = fileno $socket;
    $self->_fds->{$fd} = $id;

    return $id;
}

sub local_info {
    my ($self, $id) = @_;
    return {} unless my $c      = $self->_connections->{$id};
    return {} unless my $socket = $c->{socket};
    return {address => $socket->sockhost, port => $socket->sockport};
}

sub not_writing {
    my ($self, $id) = @_;

    # Active
    $self->_active($id);

    # Connection
    my $c = $self->_connections->{$id};

    # Chunk still in buffer or called from write event
    my $buffer = $c->{buffer};
    return $c->{read_only} = 1
      if $c->{protected} || ($buffer && $buffer->size);

    # Socket
    return unless my $socket = $c->{socket};

    # KQueue
    if (KQUEUE) {
        my $fd = fileno $socket;

        # Writing
        my $writing = $c->{writing};
        $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_READ(),
            IO::KQueue::EV_ADD())
          unless defined $writing;
        $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_WRITE(),
            IO::KQueue::EV_DELETE())
          if $writing;

        # Not writing anymore
        $c->{writing} = 0;
    }

    # Epoll
    elsif (EPOLL) { $self->_loop->mask($socket, IO::Epoll::POLLIN()) }

    # Poll
    else { $self->_loop->mask($socket, POLLIN) }
}

sub read_cb { shift->_add_event('read', @_) }

sub remote_info {
    my ($self, $id) = @_;
    return {} unless my $c      = $self->_connections->{$id};
    return {} unless my $socket = $c->{socket};
    return {address => $socket->peerhost, port => $socket->peerport};
}

sub singleton { $LOOP ||= shift->new(@_) }

sub start {
    my $self = shift;

    # Already running
    return if $self->_running;

    # Running
    $self->_running(1);

    # Mainloop
    $self->_spin while $self->_running;

    # Cleanup before stopping
    $self->_spin;

    return $self;
}

sub stop { shift->_running(0) }

sub timer {
    my $self = shift;
    my $id   = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Started
    $args->{started} = time;

    # Connection
    $args->{connection} = $id;

    # Connection doesn't exist
    return unless $self->_connections->{$id};
    my $tid = "$args";

    # Add timer
    $self->_timers->{$tid} = $args;

    # Bind timer to connection
    my $timers = $self->_connections->{$id}->{timers} ||= [];
    push @{$timers}, $tid;

    return $tid;
}

sub write_cb { shift->_add_event('write', @_) }

sub writing {
    my ($self, $id) = @_;

    # Active
    $self->_active($id);

    # Connection
    my $c = $self->_connections->{$id};

    # Socket
    return unless my $socket = $c->{socket};

    # KQueue
    if (KQUEUE) {
        my $fd = fileno $socket;

        # Writing
        my $writing = $c->{writing};
        $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_READ(),
            IO::KQueue::EV_ADD())
          unless defined $writing;
        $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_WRITE(),
            IO::KQueue::EV_ADD())
          unless $writing;

        # Writing
        $c->{writing} = 1;
    }

    # Epoll
    elsif (EPOLL) {
        $self->_loop->mask($socket,
            IO::Epoll::POLLIN() | IO::Epoll::POLLOUT());
    }

    # Poll
    else { $self->_loop->mask($socket, POLLIN | POLLOUT) }
}

sub _accept {
    my ($self, $listen) = @_;

    # Accept
    my $socket = $listen->accept or return;
    my $id = "$socket";

    # Add connection
    $self->_connections->{$id} = {
        accepting => 1,
        buffer    => Mojo::ByteStream->new,
        socket    => $socket
    };

    # Timeout
    $self->_connections->{$socket}->{accept_timer} = $self->timer(
        $id => (
            after => $self->accept_timeout,
            cb    => sub { shift->_error($id, 'Accept timeout.') }
        )
    );

    # Disable Nagle's algorithm
    setsockopt($socket, IPPROTO_TCP, TCP_NODELAY, 1)
      unless $self->_listen->{$listen}->{file};

    # File descriptor
    my $fd = fileno $socket;
    $self->_fds->{$fd} = $id;

    # Accept callback
    my $cb = $self->_listen->{$listen}->{cb};
    $self->_event('accept', $cb, $id) if $cb;

    # Unlock callback
    $self->_callback('unlock', $self->unlock_cb);

    # Remove listen sockets
    for my $lid (keys %{$self->_listen}) {
        my $listen = $self->_listen->{$lid}->{socket};

        # Remove listen socket from kqueue
        if (KQUEUE) {
            $self->_loop->EV_SET(fileno $listen,
                IO::KQueue::EVFILT_READ(), IO::KQueue::EV_DELETE());
        }

        # Remove listen socket from poll or epoll
        else { $self->_loop->remove($listen) }
    }

    # Not listening anymore
    $self->_listening(0);
}

sub _accepting {
    my ($self, $id) = @_;

    # Connection
    my $c = $self->_connections->{$id};

    # Connected
    return unless $c->{socket}->connected;

    # Accepted
    delete $c->{accepting};

    # Remove timeout
    $self->_drop(delete $c->{accept_timer});

    # Non blocking
    $c->{socket}->blocking(0);

    # Add socket to poll
    $self->not_writing($id);
}

sub _active {
    my ($self, $id) = @_;
    return $self->_connections->{$id}->{active} = time;
}

sub _add_event {
    my ($self, $event, $id, $cb) = @_;

    # Add event callback to connection
    $self->_connections->{$id}->{$event} = $cb;

    return $self;
}

# Failed callbacks should not kill everything
sub _callback {
    my $self  = shift;
    my $event = shift;
    my $cb    = shift;

    # Invoke callback
    my $value = eval { $self->$cb(@_) };

    # Callback error
    warn qq/Callback "$event" failed: $@/ if $@;

    return $value;
}

sub _connecting {
    my ($self, $id) = @_;

    # Connection
    my $c = $self->_connections->{$id};

    # Not yet connected
    return unless $c->{socket}->connected;

    # Connected
    delete $c->{connecting};

    # Remove timeout
    $self->_drop(delete $c->{connect_timer});

    # Connect callback
    my $cb = $c->{connect_cb};
    $self->_event('connect', $cb, $id) if $cb;
}

sub _drop {
    my ($self, $id) = @_;

    # Drop timer
    if ($self->_timers->{$id}) {

        # Connection for timer
        my $cid = $self->_timers->{$id}->{connection};

        # Connection exists
        if (my $c = $self->_connections->{$cid}) {

            # Cleanup
            my @timers;
            for my $timer (@{$c->{timers}}) {
                next if $timer eq $id;
                push @timers, $timer;
            }
            $c->{timers} = \@timers;
        }

        # Drop
        delete $self->_timers->{$id};
        return $self;
    }

    # Delete connection
    my $c = delete $self->_connections->{$id};

    # Drop listen socket
    if (!$c && ($c = delete $self->_listen->{$id})) {

        # Not listening
        return $self unless $self->_listening;

        # Not listening anymore
        $self->_listening(0);
    }

    # Drop socket
    if (my $socket = $c->{socket}) {

        # Cleanup timers
        if (my $timers = $c->{timers}) {
            for my $tid (@$timers) { $self->_drop($tid) }
        }

        # Remove file descriptor
        my $fd = fileno $socket;
        delete $self->_fds->{$fd};

        # Shortcut
        return $self unless $self->_loop;

        # Remove socket from kqueue
        if (KQUEUE) {

            # Writing
            my $writing = $c->{writing};
            $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_READ(),
                IO::KQueue::EV_DELETE())
              if defined $writing;
            $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_WRITE(),
                IO::KQueue::EV_DELETE())
              if $writing;
        }

        # Remove socket from poll or epoll
        else { $self->_loop->remove($socket) }

        # Close socket
        close $socket;
    }

    return $self;
}

sub _error {
    my ($self, $id, $error) = @_;

    # Get error callback
    my $event = $self->_connections->{$id}->{error};

    # Cleanup
    $self->_drop($id);

    # No event
    return unless $event;

    # Error callback
    $self->_event('error', $event, $id, $error);
}

# Failed events should not kill everything
sub _event {
    my $self  = shift;
    my $event = shift;
    my $cb    = shift;
    my $id    = shift;

    # Invoke callback
    my $value = eval { $self->$cb($id, @_) };

    # Event error
    if ($@) {
        my $message = qq/Event "$event" failed for connection "$id": $@/;
        ($event eq 'error' || $event eq 'timer')
          ? ($self->_drop($id) and warn $message)
          : $self->_error($id, $message);
    }

    return $value;
}

sub _hup {
    my ($self, $id) = @_;

    # Get hup callback
    my $event = $self->_connections->{$id}->{hup};

    # Cleanup
    $self->_drop($id);

    # No event
    return unless $event;

    # HUP callback
    $self->_event('hup', $event, $id);
}

sub _is_listening {
    my $self = shift;
    return 1
      if keys %{$self->_listen}
          && keys %{$self->_connections} < $self->max_connections
          && $self->_callback('lock', $self->lock_cb,
              !keys %{$self->_connections});
    return 0;
}

sub _prepare {
    my $self = shift;

    # Prepare
    for my $id (keys %{$self->_connections}) {

        # Connection
        my $c = $self->_connections->{$id};

        # Accepting
        $self->_accepting($id) if $c->{accepting};

        # Connecting
        $self->_connecting($id) if $c->{connecting};

        # Drop if buffer is empty
        $self->_drop($id) and next
          if $c->{finish} && (!$c->{buffer} || !$c->{buffer}->size);

        # Read only
        $self->not_writing($id) if delete $c->{read_only};

        # Timeout
        my $timeout = $c->{timeout} || 15;

        # Last active
        my $time = $c->{active} || $self->_active($id);

        # HUP
        $self->_hup($id) if (time - $time) >= $timeout;
    }

    # Nothing to do
    return $self->_running(0)
      unless keys %{$self->_connections}
          || $self->_listening
          || ($self->max_connections > 0 && keys %{$self->_listen});

    return;
}

sub _read {
    my ($self, $id) = @_;

    # Listen socket (new connection)
    my $listen;
    for my $lid (keys %{$self->_listen}) {
        my $socket = $self->_listen->{$lid}->{socket};
        if ($id eq $socket) {
            $listen = $socket;
            last;
        }
    }

    # Accept new connection
    return $self->_accept($listen) if $listen;

    # Connection
    my $c = $self->_connections->{$id};

    # Read chunk
    my $read = $c->{socket}->sysread(my $buffer, CHUNK_SIZE, 0);

    # Read error
    return $self->_error($id, $!)
      unless defined $read && defined $buffer && length $buffer;

    # Callback
    my $event = $c->{read};
    $self->_event('read', $event, $id, $buffer) if $event;

    # Active
    $self->_active($id);
}

sub _spin {
    my $self = shift;

    # Listening
    if (!$self->_listening && $self->_is_listening) {

        # Add listen sockets
        for my $lid (keys %{$self->_listen}) {
            my $socket = $self->_listen->{$lid}->{socket};
            my $fd     = fileno $socket;

            # KQueue
            $self->_loop->EV_SET($fd, IO::KQueue::EVFILT_READ(),
                IO::KQueue::EV_ADD())
              if KQUEUE;

            # Epoll
            $self->_loop->mask($socket, IO::Epoll::POLLIN()) if EPOLL;

            # Poll
            $self->_loop->mask($socket, POLLIN) unless KQUEUE || EPOLL;
        }

        # Listening
        $self->_listening(1);
    }

    # Prepare
    return if $self->_prepare;

    # KQueue
    if (KQUEUE) {
        my $kq = $self->_loop;

        # Catch interrupted system call errors
        my @ret;
        eval { @ret = $kq->kevent($self->timeout * 50) };
        die "KQueue error: $@" if $@;

        # Events
        my (@error, @hup, @read, @write);
        for my $kev (@ret) {
            my ($fd, $filter, $flags, $fflags) = @$kev;

            # Id
            my $id = $self->_fds->{$fd};
            next unless $id;

            # Error
            if ($flags == IO::KQueue::EV_EOF()) {
                if   ($fflags) { push @error, $id }
                else           { push @hup,   $id }
            }

            # Read
            push @read, $id if $filter == IO::KQueue::EVFILT_READ();

            # Write
            push @write, $id if $filter == IO::KQueue::EVFILT_WRITE();
        }

        # Error
        $self->_error($_) for @error;

        # HUP
        $self->_hup($_) for @hup;

        # Read
        $self->_read($_) for @read;

        # Write
        $self->_write($_) for @write;
    }

    # Epoll
    elsif (EPOLL) {
        my $epoll = $self->_loop;
        $epoll->poll($self->timeout);

        # Error
        $self->_error("$_", $!) for $epoll->handles(IO::Epoll::POLLERR());

        # HUP
        $self->_hup("$_") for $epoll->handles(IO::Epoll::POLLHUP());

        # Read
        $self->_read("$_") for $epoll->handles(IO::Epoll::POLLIN());

        # Write
        $self->_write("$_") for $epoll->handles(IO::Epoll::POLLOUT());
    }

    # Poll
    else {
        my $poll = $self->_loop;
        $poll->poll($self->timeout);

        # Error
        $self->_error("$_", $!) for $poll->handles(POLLERR);

        # HUP
        $self->_hup("$_") for $poll->handles(POLLHUP);

        # Read
        $self->_read("$_") for $poll->handles(POLLIN);

        # Write
        $self->_write("$_") for $poll->handles(POLLOUT);
    }

    # Timers
    $self->_timing;
}

sub _timing {
    my $self = shift;

    # Timers
    for my $id (keys %{$self->_timers}) {
        my $t = $self->_timers->{$id};

        # Timer
        my $run = 0;
        if (defined $t->{after} && $t->{after} <= time - $t->{started}) {

            # Done
            delete $t->{after};
            $run++;
        }

        # Recurring
        elsif (!defined $t->{after} && defined $t->{interval}) {
            $t->{last} ||= 0;
            $run++ if $t->{last} + $t->{interval} <= time;
        }

        # Callback
        if ((my $cb = $t->{cb}) && $run) {
            $self->_event('timer', $cb, $t->{connection}, "$t");
            $t->{last} = time;
        }

        # Continue
        $self->_drop($id)
          unless defined $t->{after} || defined $t->{interval};
    }
}

sub _write {
    my ($self, $id) = @_;

    # Connection
    my $c = $self->_connections->{$id};

    # Connect has just completed
    return if $c->{connecting};

    # Buffer
    my $buffer = $c->{buffer};

    # Try to fill the buffer before writing
    my $more = !$c->{read_only} && !$c->{finish} ? 1 : 0;
    my $event = $c->{write};
    if ($more && $event && $buffer->size < CHUNK_SIZE) {

        # Write callback
        $c->{protected} = 1;
        my $chunk = $self->_event('write', $event, $id);
        delete $c->{protected};

        # Add to buffer
        $buffer->add_chunk($chunk);
    }

    # Try to write whole buffer
    my $chunk = $buffer->to_string;

    # Write
    my $written = $c->{socket}->syswrite($chunk, length $chunk);

    # Write error
    return $self->_error($id, $!) unless defined $written;

    # Remove written chunk from buffer
    $buffer->remove($written);

    # Active
    $self->_active($id) if $written;
}

1;
__END__

=head1 NAME

Mojo::IOLoop - Minimalistic Event Loop For TCP Clients And Servers

=head1 SYNOPSIS

    use Mojo::IOLoop;

    # Create loop
    my $loop = Mojo::IOLoop->new;

    # Listen on port 3000
    $loop->listen(
        port => 3000,
        cb   => sub {
            my ($self, $id) = @_;

            # Start read only when accepting a new connection
            $self->not_writing($id);

            # Incoming data
            $self->read_cb($id => sub {
                my ($self, $id, $chunk) = @_;

                # Got some data, time to write
                $self->writing($id);
            });

            # Ready to write
            $self->write_cb($id => sub {
                my ($self, $id) = @_;

                # Back to reading only
                $self->not_writing($id);

                # The loop will take care of buffering for us
                return 'HTTP/1.1 200 OK';
            });
        }
    );

    # Connect to port 3000 with TLS activated
    my $id = $loop->connect(address => 'localhost', port => 3000, tls => 1);

    # Loop starts writing
    $loop->writing($id);

    # Writing request
    $loop->write_cb($id => sub {
        my ($self, $id) = @_;

        # Back to reading only
        $self->not_writing($id);

        # The loop will take care of buffering for us
        return "GET / HTTP/1.1\r\n\r\n";
    });

    # Reading response
    $loop->read_cb($id => sub {
        my ($self, $id, $chunk) = @_;

        # Time to write more
        $self->writing($id);
    });

    # Add a timer
    $loop->timer($id => (after => 5, cb => sub {
        my ($self, $cid, $tid) = @_;
        $self->drop($cid);
    }));

    # Add another timer
    $loop->timer($id => (interval => 3, cb => sub {
        print "Timer is running again!\n";
    }));

    # Start and stop loop
    $loop->start;
    $loop->stop;

=head1 DESCRIPTION

L<Mojo::IOLoop> is a very minimalistic event loop that has been reduced to
the absolute minimal feature set required to build solid and scalable TCP
clients and servers, easy to extend and replace with alternative
implementations.

Optional modules L<IO::KQueue>, L<IO::Epoll>, L<IO::Socket::INET6> and
L<IO::Socket::SSL> are supported transparently and used if installed.

=head2 ATTRIBUTES

L<Mojo::IOLoop> implements the following attributes.

=head2 C<accept_timeout>

    my $timeout = $loop->accept_timeout;
    $loop       = $loop->accept_timeout(5);

Maximum time in seconds a connection can take to be accepted before being
dropped, defaults to C<5>.

=head2 C<connect_timeout>

    my $timeout = $loop->connect_timeout;
    $loop       = $loop->connect_timeout(5);

Maximum time in seconds a conenction can take to be connected before being
dropped, defaults to C<5>.

=head2 C<lock_cb>

    my $cb = $loop->lock_cb;
    $loop  = $loop->lock_cb(sub {...});

A locking callback that decides if this loop is allowed to listen for new
incoming connections, used to sync multiple server processes.
The callback should return true or false.

    $loop->lock_cb(sub {
        my ($loop, $blocking) = @_;

        # Got the lock, listen for new connections
        return 1;
    });

=head2 C<max_connections>

    my $max = $loop->max_connections;
    $loop   = $loop->max_connections(1000);

The maximum number of connections this loop is allowed to handle before
stopping to accept new incoming connections, defaults to C<1000>.
Setting the value to C<0> will make this loop stop accepting new connections
and allow it to shutdown gracefully without interrupting existing
connections.

=head2 C<unlock_cb>

    my $cb = $loop->unlock_cb;
    $loop  = $loop->unlock_cb(sub {...});

A callback to free the listen lock, called after accepting a new connection
and used to sync multiple server processes.

=head2 C<timeout>

    my $timeout = $loop->timeout;
    $loop       = $loop->timeout(5);

Maximum time in seconds our loop waits for new events to happen, defaults to
C<0.25>.

=head1 METHODS

L<Mojo::IOLoop> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 C<new>

    my $loop = Mojo::IOLoop->new;

Construct a new L<Mojo::IOLoop> object.
Multiple of these will block each other, so use C<singleton> instead if
possible.

=head2 C<connect>

    my $id = $loop->connect(
        address => '127.0.0.1',
        port    => 3000,
        cb      => sub {...}
    );
    my $id = $loop->connect({
        address => '127.0.0.1',
        port    => 3000,
        cb      => sub {...}
    });
    my $id = $loop->connect({
        address => '[::1]',
        port    => 443,
        tls     => 1,
        cb      => sub {...}
    });

Open a TCP connection to a remote host, IPv6 will be used automatically if
available.
Note that IPv6 support depends on L<IO::Socket::INET6> and TLS support on
L<IO::Socket::SSL>.

These options are currently available.

=over 4

=item C<address>

Address or host name of the peer to connect to.

=item C<cb>

Callback to be invoked once the connection is established.

=item C<port>

Port to connect to.

=item C<tls>

Enable TLS.

=item C<tls_ca_file>

CA file to use for TLS.

=item C<tls_verify_cb>

Callback to invoke for TLS verification.

=back

=head2 C<connection_timeout>

    my $timeout = $loop->connection_timeout($id);
    $loop       = $loop->connection_timeout($id => 45);

Maximum amount of time in seconds a connection can be inactive before being
dropped.

=head2 C<drop>

    $loop = $loop->drop($id);

Drop a connection, listen socket or timer.
Connections will be dropped gracefully by allowing them to finish writing all
data in it's write buffer.

=head2 C<error_cb>

    $loop = $loop->error_cb($id => sub {...});

Callback to be invoked if an error event happens on the connection.

=head2 C<generate_port>

    my $port = $loop->generate_port;

Find a free TCP port, this is a utility function primarily used for tests.

=head2 C<hup_cb>

    $loop = $loop->hup_cb($id => sub {...});

Callback to be invoked if the connection gets closed.

=head2 C<listen>

    my $id = $loop->listen(port => 3000);
    my $id = $loop->listen({port => 3000});
    my $id = $loop->listen(file => '/foo/myapp.sock');
    my $id = $loop->listen(
        port     => 443,
        tls      => 1,
        tls_cert => '/foo/server.cert',
        tls_key  => '/foo/server.key'
    );

Create a new listen socket, IPv6 will be used automatically if available.
Note that IPv6 support depends on L<IO::Socket::INET6> and TLS support on
L<IO::Socket::SSL>.

These options are currently available.

=over 4

=item C<address>

Local address to listen on, defaults to all.

=item C<cb>

Callback to invoke for each accepted connection.

=item C<file>

A unix domain socket to listen on.

=item C<port>

Port to listen on.

=item C<queue_size>

Maximum queue size, defaults to C<SOMAXCONN>.

=item C<tls>

Enable TLS.

=item C<tls_cert>

Path to the TLS cert file.

=item C<tls_key>

Path to the TLS key file.

=back

=head2 C<local_info>

    my $info = $loop->local_info($id);

Get local information about a connection.

    my $address = $info->{address};

These values are to be expected in the returned hash reference.

=over 4

=item C<address>

The local address.

=item C<port>

The local port.

=back

=head2 C<not_writing>

    $loop->not_writing($id);

Activate read only mode for a connection.
Note that connections have no mode after they are created.

=head2 C<read_cb>

    $loop = $loop->read_cb($id => sub {...});

Callback to be invoked if new data arrives on the connection.

    $loop->read_cb($id => sub {
        my ($loop, $id, $chunk) = @_;

        # Process chunk
    });

=head2 C<remote_info>

    my $info = $loop->remote_info($id);

Get remote information about a connection.

    my $address = $info->{address};

These values are to be expected in the returned hash reference.

=over 4

=item C<address>

The remote address.

=item C<port>

The remote port.

=back

=head2 C<singleton>

    my $loop = Mojo::IOLoop->singleton;

The global loop object, used to access a single shared loop instance from
everywhere inside the process.

=head2 C<start>

    $loop->start;

Start the loop, this will block until the loop is finished or return
immediately if the loop is already running.

=head2 C<stop>

    $loop->stop;

Stop the loop immediately, this will not interrupt any existing connections
and the loop can be restarted by running C<start> again.

=head2 C<timer>

    my $id = $loop->timer($id => (after => 5, cb => sub {...}));
    my $id = $loop->timer($id => {interval => 5, cb => sub {...}}));

Create a new timer, invoking the callback afer a given amount of seconds.
Note that timers are bound to connections and will get destroyed together
with them.

These options are currently available.

=over 4

=item C<after>

Start timer after this exact amount of seconds.

=item C<cb>

Callback to invoke.

=item C<interval>

Interval in seconds to run timer recurringly.

=back

=head2 C<write_cb>

    $loop = $loop->write_cb($id => sub {...});

Callback to be invoked if new data can be written to the connection.
The callback should return a chunk of data which will be buffered inside the
loop to guarantee safe writing.

    $loop->write_ab($id => sub {
        my ($loop, $id) = @_;
        return 'Data to be buffered by the loop!';
    });

=head2 C<writing>

    $loop->writing($id);

Activate read/write mode for a connection.
Note that connections have no mode after they are created.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Book>, L<http://mojolicious.org>.

=cut
