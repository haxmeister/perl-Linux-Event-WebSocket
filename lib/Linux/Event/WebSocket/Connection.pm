package Linux::Event::WebSocket::Connection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::IO::Sock::Stream';

use Carp qw(croak);
use Encode qw(decode encode FB_CROAK);
use Scalar::Util qw(blessed);
use utf8 ();

use Linux::Event::Kernel::Timer;
use Linux::Event::WebSocket::_IO;
use Linux::Event::WebSocket::_Parser;
use Linux::Event::WebSocket::_State;
use Net::WebSocket::Endpoint::Client ();
use Net::WebSocket::Endpoint::Server ();

sub _websocket_state ($self) {
    my $state = $self->SUPER::data;
    croak ref($self) . ': missing Linux::Event::WebSocket connection state'
        if !blessed($state)
        || !$state->isa('Linux::Event::WebSocket::_State');
    return $state;
}

sub data ($self, @value) {
    my $state = $self->_websocket_state;
    croak 'data() accepts at most one value' if @value > 1;
    $state->{data} = $value[0] if @value;
    return $state->{data};
}

sub endpoint_type ($self) { $self->_websocket_state->{endpoint_type} }
sub is_open       ($self) { !!$self->_websocket_state->{open} }
sub is_closing    ($self) { !!$self->_websocket_state->{closing} }
sub subprotocol   ($self) { $self->_websocket_state->{subprotocol} }
sub secure        ($self) { !!$self->_websocket_state->{secure} }
sub url           ($self) { $self->_websocket_state->{url} }
sub handshake_request  ($self) { $self->_websocket_state->{request} }
sub handshake_response ($self) { $self->_websocket_state->{response} }

sub _dispatch_websocket ($self, $name, @argument) {
    my $state = $self->_websocket_state;
    if (my $callback = $state->{callbacks}{$name}) {
        return $callback->($self, @argument);
    }

    my $method = "websocket_$name";
    if (my $handler = $self->can($method)) {
        return $handler->($self, @argument);
    }

    return;
}

sub _count_data_frame ($state, $frame) {
    my $limit = $state->{max_message_size};
    return if !defined $limit;

    my $type = $frame->get_type;
    $state->{fragment_bytes} = 0 if $type ne 'continuation';
    $state->{fragment_bytes} += length $frame->get_payload;

    if ($state->{fragment_bytes} > $limit) {
        die "WebSocket message exceeds configured limit ($state->{fragment_bytes} > $limit)";
    }

    $state->{fragment_bytes} = 0 if $frame->get_fin;
    return;
}

sub _initialize_endpoint ($self) {
    my $state = $self->_websocket_state;
    return $state->{endpoint} if $state->{endpoint};

    my %io_option = (stream => $self);
    $io_option{max_read} = $state->{max_message_size}
        if defined $state->{max_message_size};
    my $io = Linux::Event::WebSocket::_IO->new(%io_option);
    my $parser = Linux::Event::WebSocket::_Parser->new(
        $io,
        endpoint_type => $state->{endpoint_type},
    );
    my $endpoint_class = $state->{endpoint_type} eq 'client'
        ? 'Net::WebSocket::Endpoint::Client'
        : 'Net::WebSocket::Endpoint::Server';

    my %endpoint_option = (
        parser => $parser,
        out    => $io,
    );
    if (defined $state->{max_message_size}) {
        $endpoint_option{on_data_frame} = sub ($frame) {
            _count_data_frame($state, $frame);
        };
    }

    my $endpoint = $endpoint_class->new(%endpoint_option);
    $endpoint->do_not_die_on_close;

    $state->{io} = $io;
    $state->{parser} = $parser;
    $state->{endpoint} = $endpoint;
    return $endpoint;
}

sub _ensure_websocket_open ($self) {
    my $state = $self->_websocket_state;
    return $self if $state->{open};

    $self->_initialize_endpoint;
    if (my $handshake = $state->{handshake}) {
        my $protocol = eval { $handshake->get_subprotocol };
        $state->{subprotocol} = $protocol if !$@;
    }

    $state->{open} = 1;
    $self->_dispatch_websocket('open');
    return $self;
}

sub _byte_payload ($operation, $payload) {
    croak "$operation(): payload must be a defined scalar"
        if !defined($payload) || ref($payload);
    my $bytes = "$payload";
    if (utf8::is_utf8($bytes)) {
        croak "$operation(): payload contains wide characters; encode it to bytes first"
            if !utf8::downgrade($bytes, 1);
    }
    return $bytes;
}

sub send_text ($self, $payload) {
    croak 'send_text(): payload must be a defined scalar'
        if !defined($payload) || ref($payload);
    $self->_ensure_websocket_open;
    croak 'send_text(): WebSocket connection is closing'
        if $self->is_closing;

    my $bytes;
    if (utf8::is_utf8($payload)) {
        $bytes = encode('UTF-8', $payload, FB_CROAK);
    } else {
        $bytes = "$payload";
        my $check = $bytes;
        decode('UTF-8', $check, FB_CROAK);
    }

    my $state = $self->_websocket_state;
    my $message = $state->{endpoint}->create_message('text', $bytes);
    return $state->{io}->write($message->to_bytes);
}

sub send_binary ($self, $payload) {
    $self->_ensure_websocket_open;
    croak 'send_binary(): WebSocket connection is closing'
        if $self->is_closing;
    my $bytes = _byte_payload('send_binary', $payload);
    my $state = $self->_websocket_state;
    my $message = $state->{endpoint}->create_message('binary', $bytes);
    return $state->{io}->write($message->to_bytes);
}

sub ping ($self, $payload = '') {
    $self->_ensure_websocket_open;
    croak 'ping(): WebSocket connection is closing' if $self->is_closing;
    my $bytes = _byte_payload('ping', $payload);
    my $state = $self->_websocket_state;
    my $message = $state->{endpoint}->create_message('ping', $bytes);
    return $state->{io}->write($message->to_bytes);
}

sub _cancel_close_timer ($self) {
    my $state = $self->_websocket_state;
    if (my $timer = delete $state->{close_timer}) {
        $timer->cancel;
    }
    return;
}

sub _close_timeout_fired ($timer) {
    my $self = $timer->data;
    return if !$self || $self->is_closed;
    $self->abort;
    return;
}

sub _arm_close_timeout ($self) {
    my $state = $self->_websocket_state;
    return if $state->{close_timer};

    if ($state->{close_timeout} == 0) {
        $self->end;
        return;
    }

    $state->{close_timer} = Linux::Event::Kernel::Timer->new(
        loop     => $self->loop,
        after    => $state->{close_timeout},
        data     => $self,
        on_timer => \&_close_timeout_fired,
    );
    return;
}

sub close ($self, %option) {
    return $self if $self->is_closed;
    $self->_ensure_websocket_open;

    my $state = $self->_websocket_state;
    return $self if $state->{closing};

    my $code = exists($option{code}) ? delete($option{code}) : 'SUCCESS';
    my $reason = delete $option{reason};
    croak 'close(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    my %close = (code => $code);
    $close{reason} = $reason if defined $reason;
    $state->{endpoint}->close(%close);
    $state->{closing} = 1;
    $self->_arm_close_timeout;
    return $self;
}

sub abort ($self) {
    return $self if $self->is_closed;
    $self->_cancel_close_timer;
    $self->SUPER::close;
    return $self;
}

sub _notify_websocket_close ($self, $code, $reason) {
    my $state = $self->_websocket_state;
    return if $state->{close_notified}++;
    $self->_cancel_close_timer;
    $state->{closing} = 1;
    $self->_dispatch_websocket('close', $code, $reason);
    return;
}

sub _check_received_close ($self) {
    my $state = $self->_websocket_state;
    my $frame = $state->{endpoint}->received_close_frame or return 0;
    return 1 if $state->{close_notified};

    my ($code, $reason) = $frame->get_code_and_reason;
    $self->_notify_websocket_close($code, $reason);
    $self->end if !$self->is_write_ended;
    return 1;
}

sub _protocol_failure ($self, $error) {
    my $state = $self->_websocket_state;
    my $message = "$error";
    $message =~ s/\s+\z//;
    $self->_dispatch_websocket('error', $message);

    if (!$state->{closing}) {
        my $code = $message =~ /exceeds configured limit/
            ? 'MESSAGE_TOO_BIG' : 'PROTOCOL_ERROR';
        eval { $state->{endpoint}->close(code => $code); 1 };
        $state->{closing} = 1;
    }

    $self->end if !$self->is_write_ended;
    return;
}

sub _deliver_message ($self, $message) {
    my $type = $message->get_type;
    my $payload = $message->get_payload;

    if ($type eq 'text') {
        my $text = eval { decode('UTF-8', $payload, FB_CROAK) };
        if ($@) {
            $self->_protocol_failure('invalid UTF-8 in WebSocket text message');
            return;
        }
        $payload = $text;
    }

    $self->_dispatch_websocket('message', $payload, $type);
    return;
}

sub _drain_websocket_input ($self) {
    my $state = $self->_websocket_state;
    my $io = $state->{io};
    my $endpoint = $state->{endpoint};

    while (!$self->is_closed) {
        my $before = $io->buffered_bytes;
        my ($message, $ok, $error);
        {
            local $@;
            $ok = eval {
                $message = $endpoint->get_next_message;
                1;
            };
            $error = $@;
        }

        if (!$ok) {
            $self->_protocol_failure($error);
            last;
        }

        my $after = $io->buffered_bytes;
        $self->_check_received_close;
        last if $self->is_closing && !$message;

        if (defined $message) {
            last if !ref($message) && $message eq '';
            $self->_deliver_message($message);
            next;
        }

        last if $after == $before;
    }
    return;
}

sub on_data ($self, $bytes) {
    $self->_ensure_websocket_open;
    my $state = $self->_websocket_state;
    $state->{io}->feed($bytes);
    $self->_drain_websocket_input;
    return;
}

sub on_eof ($self) {
    return if $self->is_closed;
    my $state = $self->_websocket_state;
    $state->{io}->finish if $state->{io};
    $self->_notify_websocket_close(undef, 'transport EOF')
        if !$state->{close_notified};
    $self->SUPER::close if !$self->is_closed;
    return;
}

sub on_error ($self, $error) {
    return if $self->is_closed;
    $self->_dispatch_websocket('error', $error);
    return;
}

sub on_close ($self) {
    $self->_websocket_transport_closed;
    return;
}

sub on_drain ($self) {
    return if !$self->is_open;
    $self->_dispatch_websocket('drain');
    return;
}

sub _websocket_transport_closed ($self) {
    my $state = $self->_websocket_state;
    $self->_cancel_close_timer;
    $self->_notify_websocket_close(undef, 'transport closed')
        if $state->{open} && !$state->{close_notified};
    return;
}

1;
