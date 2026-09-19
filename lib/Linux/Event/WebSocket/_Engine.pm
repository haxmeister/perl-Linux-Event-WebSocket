package Linux::Event::WebSocket::_Engine;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed weaken);
use Linux::Event::WebSocket::_Frame;
use Linux::Event::WebSocket::_Wslay;

sub new ($class, %option) {
    my $connection = delete $option{connection};
    croak 'new(): connection object is required'
        if !blessed($connection) || !$connection->can('write');

    my $endpoint_type = delete $option{endpoint_type};
    croak 'new(): endpoint_type must be client or server'
        if !defined($endpoint_type)
        || ($endpoint_type ne 'client' && $endpoint_type ne 'server');

    my $message_handler_supplied = exists $option{message_handler};
    my $message_handler = delete $option{message_handler};
    croak 'new(): message_handler must be a coderef'
        if defined($message_handler) && ref($message_handler) ne 'CODE';

    my $max_message_size = delete $option{max_message_size};
    croak 'new(): max_message_size must be a positive integer'
        if !defined($max_message_size) || ref($max_message_size)
        || "$max_message_size" !~ /\A[0-9]+\z/ || $max_message_size < 1;
    croak 'new(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    my $native_limit = $max_message_size < 125 ? 125 : $max_message_size;
    my $self = bless {
        connection       => $connection,
        endpoint_type    => $endpoint_type,
        message_handler_supplied => $message_handler_supplied ? 1 : 0,
        message_handler  => $message_handler,
        max_message_size => 0 + $max_message_size,
        native           => Linux::Event::WebSocket::_Wslay->new(
            $endpoint_type,
            $native_limit,
        ),
        sent_close       => 0,
        received_close   => 0,
        failed           => 0,
        pending_end      => 0,
    }, $class;
    weaken($self->{connection});
    return $self;
}

sub _connection ($self) {
    return $self->{connection}
        // die "WebSocket connection was destroyed while its engine remained alive\n";
}

sub is_closing ($self) {
    return !!($self->{sent_close} || $self->{received_close});
}

sub _write_native ($self, $connection = undef) {
    my $wire = $self->{native}->flush;
    return 0 if !length $wire;
    $connection //= $self->_connection;
    return 0 if $connection->is_closed;
    return $connection->write($wire);
}

sub _queue_message ($self, $opcode, $bytes, $connection = undef) {
    $self->{native}->queue_message($opcode, $bytes);
    return $self->_write_native($connection);
}

sub send_text ($self, $bytes) {
    croak 'send_text(): WebSocket connection is closing'
        if $self->{sent_close} || $self->{received_close};
    return $self->_queue_message(1, $bytes);
}

sub send_binary ($self, $bytes) {
    croak 'send_binary(): WebSocket connection is closing'
        if $self->{sent_close} || $self->{received_close};
    return $self->_queue_message(2, $bytes);
}

sub ping ($self, $bytes = '') {
    croak 'ping(): WebSocket connection is closing' if $self->is_closing;
    croak 'ping(): control frame payload exceeds 125 bytes'
        if length($bytes) > 125;
    return $self->_queue_message(9, $bytes);
}

sub start_close ($self, $code, $reason = '') {
    return $self if $self->{sent_close};
    croak 'close reason exceeds 123 bytes' if length($reason) > 123;
    my $number = Linux::Event::WebSocket::_Frame->close_code($code);
    $self->{native}->queue_close($number, $reason);
    $self->{sent_close} = 1;
    my $connection = $self->_connection;
    $connection->_websocket_engine_closing;
    $self->_write_native($connection);
    return $self;
}

sub _failure_message ($code) {
    return 'invalid UTF-8 in WebSocket frame' if $code == 1007;
    return 'WebSocket message exceeds configured limit' if $code == 1009;
    return 'WebSocket protocol error';
}

sub _native_failure ($self, $code, $connection) {
    return if $self->{failed}++;
    $self->{sent_close} = 1;
    $connection->_websocket_engine_error(_failure_message($code));
    $connection->_websocket_engine_closing;
    $self->{pending_end} = 1;
    return;
}

sub _deliver ($self, $opcode, $payload, $connection) {
    return if $self->{sent_close} || $self->{received_close};

    if (length($payload) > $self->{max_message_size}) {
        $self->{native}->queue_close(1009, '');
        $self->_native_failure(1009, $connection);
        return;
    }

    my $type = $opcode == 1 ? 'text' : 'binary';

    if ($self->{message_handler_supplied}) {
        if (my $handler = $self->{message_handler}) {
            $handler->($connection, $payload, $type);
        }
    } else {
        $connection->_websocket_engine_message($payload, $type);
    }

    $self->{native}->shutdown_read if $connection->is_closed;
    return;
}

sub _wslay_event ($self, $opcode, $payload, $status_code) {
    my $connection = $self->_connection;
    return if $self->{failed} || $connection->is_closed;

    if ($opcode == 1 || $opcode == 2) {
        $self->_deliver($opcode, $payload, $connection);
        return;
    }

    return if $opcode != 8 || $self->{received_close};

    $self->{received_close} = 1;
    $self->{sent_close} = 1;
    $connection->_websocket_engine_closing;

    my $reason = $payload;
    my $code = $status_code ? 0 + $status_code : undef;
    $connection->_websocket_engine_close($code, $reason);
    $self->{pending_end} = 1;
    return;
}

sub feed ($self, $bytes) {
    my $connection = $self->_connection;
    return if $self->{failed} || $self->{received_close}
        || $connection->is_closed;

    my ($wire, $failure_code) = $self->{native}->feed($self, $bytes);
    $connection->write($wire) if length($wire) && !$connection->is_closed;

    if (defined $failure_code && !$self->{received_close}) {
        $self->_native_failure($failure_code, $connection);
    }

    if ($self->{pending_end} && !$connection->is_write_ended
        && !$connection->is_closed) {
        $self->{pending_end} = 0;
        $connection->end;
    }
    return;
}

1;
