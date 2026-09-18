package Linux::Event::WebSocket::_Engine;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed weaken);

use Linux::Event::WebSocket::_Frame;
use Linux::Event::WebSocket::_Parser;
use Linux::Event::WebSocket::_UTF8;

sub new ($class, %option) {
    my $connection = delete $option{connection};
    croak 'new(): connection object is required'
        if !blessed($connection) || !$connection->can('write');

    my $endpoint_type = delete $option{endpoint_type};
    croak 'new(): endpoint_type must be client or server'
        if !defined($endpoint_type)
        || ($endpoint_type ne 'client' && $endpoint_type ne 'server');

    my $max_message_size = delete $option{max_message_size};
    croak 'new(): max_message_size must be a positive integer'
        if !defined($max_message_size) || ref($max_message_size)
        || "$max_message_size" !~ /\A[0-9]+\z/ || $max_message_size < 1;
    croak 'new(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    my $max_frame_size = $max_message_size < 125
        ? 125 : $max_message_size;

    my $self = bless {
        connection       => $connection,
        endpoint_type    => $endpoint_type,
        max_message_size => 0 + $max_message_size,
        parser            => Linux::Event::WebSocket::_Parser->new(
            endpoint_type  => $endpoint_type,
            max_frame_size => $max_frame_size,
        ),
        fragment_type    => undef,
        fragment_payload => '',
        sent_close       => 0,
        received_close   => 0,
        failed           => 0,
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

sub _write_frame ($self, $type, $payload, %option) {
    my $wire = Linux::Event::WebSocket::_Frame->encode(
        $type,
        $payload,
        masked => $self->{endpoint_type} eq 'client' ? 1 : 0,
        %option,
    );
    return $self->_connection->write($wire);
}

sub send_text ($self, $bytes) {
    croak 'send_text(): WebSocket connection is closing' if $self->is_closing;
    return $self->_write_frame('text', $bytes);
}

sub send_binary ($self, $bytes) {
    croak 'send_binary(): WebSocket connection is closing' if $self->is_closing;
    return $self->_write_frame('binary', $bytes);
}

sub ping ($self, $bytes = '') {
    croak 'ping(): WebSocket connection is closing' if $self->is_closing;
    return $self->_write_frame('ping', $bytes);
}

sub start_close ($self, $code, $reason = '') {
    return $self if $self->{sent_close};
    my $payload = Linux::Event::WebSocket::_Frame->close_payload($code, $reason);
    $self->_write_frame('close', $payload);
    $self->{sent_close} = 1;
    $self->_connection->_websocket_engine_closing;
    return $self;
}

sub _failure_code ($error) {
    return 1009 if $error =~ /exceeds configured limit/;
    return 1007 if $error =~ /UTF-8/;
    return 1002;
}

sub _fail ($self, $error, $connection = undef) {
    return if $self->{failed}++;
    my $message = "$error";
    $message =~ s/\s+\z//;

    $connection //= $self->_connection;
    $connection->_websocket_engine_error($message);

    if (!$self->{sent_close} && !$connection->is_closed) {
        my $payload = Linux::Event::WebSocket::_Frame->close_payload(
            _failure_code($message),
            '',
        );
        $self->_write_frame('close', $payload);
        $self->{sent_close} = 1;
    }
    $connection->_websocket_engine_closing;
    $connection->end if !$connection->is_write_ended;
    return;
}

sub _deliver ($self, $type, $payload, $connection) {
    if ($type eq 'text') {
        my $decoded = eval { Linux::Event::WebSocket::_UTF8->decode($payload) };
        if ($@) {
            $self->_fail('invalid UTF-8 in WebSocket text message', $connection);
            return 0;
        }
        $payload = $decoded;
    }
    $connection->_websocket_engine_message($payload, $type);
    return 1;
}

sub _handle_data ($self, $frame, $type, $connection) {
    return 0 if $self->{received_close};
    return 1 if $self->{sent_close};

    my $payload = $frame->{payload};
    if ($type eq 'continuation') {
        if (!defined $self->{fragment_type}) {
            $self->_fail('WebSocket continuation frame received outside a fragmented message', $connection);
            return 0;
        }
        if (length($self->{fragment_payload}) + length($payload)
            > $self->{max_message_size}) {
            $self->_fail('WebSocket message exceeds configured limit', $connection);
            return 0;
        }
        $self->{fragment_payload} .= $payload;
        if ($frame->{fin}) {
            my $message_type = $self->{fragment_type};
            my $message = $self->{fragment_payload};
            $self->{fragment_type} = undef;
            $self->{fragment_payload} = '';
            return $self->_deliver($message_type, $message, $connection);
        }
        return 1;
    }

    if (defined $self->{fragment_type}) {
        $self->_fail("WebSocket $type frame received while a fragmented message is unfinished", $connection);
        return 0;
    }
    if (length($payload) > $self->{max_message_size}) {
        $self->_fail('WebSocket message exceeds configured limit', $connection);
        return 0;
    }

    if ($frame->{fin}) {
        return $self->_deliver($type, $payload, $connection);
    }
    $self->{fragment_type} = $type;
    $self->{fragment_payload} = $payload;
    return 1;
}

sub _handle_close ($self, $payload, $connection) {
    my ($code, $reason);
    my $ok = eval {
        ($code, $reason) = Linux::Event::WebSocket::_Frame->parse_close_payload(
            $payload,
        );
        1;
    };
    if (!$ok) {
        $self->_fail($@, $connection);
        return 0;
    }

    $self->{received_close} = 1;
    if (!$self->{sent_close}) {
        $self->_write_frame('close', $payload);
        $self->{sent_close} = 1;
    }
    $connection->_websocket_engine_closing;

    my $decoded = '';
    $decoded = Linux::Event::WebSocket::_UTF8->decode($reason) if length $reason;
    $connection->_websocket_engine_close($code, $decoded);
    $connection->end if !$connection->is_write_ended;
    return 0;
}

sub _handle_frame ($self, $frame, $connection) {
    my $type = $frame->{type};
    return $self->_handle_data($frame, $type, $connection)
        if $frame->{opcode} < 8;

    if ($type eq 'ping') {
        $self->_write_frame('pong', $frame->{payload})
            if !$self->{received_close};
        return 1;
    }
    return 1 if $type eq 'pong';
    return $self->_handle_close($frame->{payload}, $connection);
}

sub feed ($self, $bytes) {
    my $connection = $self->_connection;
    return if $self->{failed} || $self->{received_close}
        || $connection->is_closed;

    my $ok = eval {
        $self->{parser}->feed($bytes);
        1;
    };
    if (!$ok) {
        $self->_fail($@);
        return;
    }

    while (!$self->{failed} && !$self->{received_close}) {
        my $frame;
        $ok = eval {
            $frame = $self->{parser}->next_frame;
            1;
        };
        if (!$ok) {
            $self->_fail($@);
            last;
        }
        last if !$frame;
        last if !$self->_handle_frame($frame, $connection);
        last if $connection->is_closed;
    }
    return;
}

1;
