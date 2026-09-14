package LEWS::Prototype::Connection;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use parent 'Linux::Event::IO::Sock::Stream';

use Net::WebSocket::Endpoint::Client ();
use Net::WebSocket::Endpoint::Server ();
use Net::WebSocket::Parser ();
use LEWS::Prototype::IO ();

sub websocket_endpoint_type ($class) {
    croak "$class must define websocket_endpoint_type() as client or server";
}

sub _websocket_state ($self) {
    return $self->{_lews_prototype} if $self->{_lews_prototype};

    my $endpoint_type = $self->websocket_endpoint_type;
    croak 'websocket_endpoint_type() must return client or server'
        if $endpoint_type ne 'client' && $endpoint_type ne 'server';

    my $io = LEWS::Prototype::IO->new(stream => $self);
    my $parser = Net::WebSocket::Parser->new($io);
    my $endpoint_class = $endpoint_type eq 'client'
        ? 'Net::WebSocket::Endpoint::Client'
        : 'Net::WebSocket::Endpoint::Server';

    my $endpoint = $endpoint_class->new(
        parser => $parser,
        out    => $io,
    );
    $endpoint->do_not_die_on_close;

    return $self->{_lews_prototype} = {
        io            => $io,
        parser        => $parser,
        endpoint      => $endpoint,
        endpoint_type => $endpoint_type,
    };
}

sub websocket_endpoint ($self) {
    return $self->_websocket_state->{endpoint};
}

sub websocket_endpoint_type_name ($self) {
    return $self->_websocket_state->{endpoint_type};
}

sub send_text ($self, $payload) {
    return $self->_send_websocket_message('text', $payload);
}

sub send_binary ($self, $payload) {
    return $self->_send_websocket_message('binary', $payload);
}

sub _send_websocket_message ($self, $type, $payload) {
    croak 'WebSocket payload must be a defined scalar'
        if !defined($payload) || ref($payload);

    my $state = $self->_websocket_state;
    my $message = $state->{endpoint}->create_message($type, $payload);
    return $state->{io}->write($message->to_bytes);
}

sub websocket_close ($self, %option) {
    my $endpoint = $self->_websocket_state->{endpoint};
    $endpoint->close(%option);
    return $self;
}

sub on_data ($self, $bytes) {
    my $state = $self->_websocket_state;
    my $io = $state->{io};
    my $endpoint = $state->{endpoint};

    $io->feed($bytes);
    $self->_drain_websocket_messages($io, $endpoint);
    return;
}

sub on_eof ($self) {
    return if $self->is_closed;
    my $state = $self->_websocket_state;
    $state->{io}->finish;
    $self->_drain_websocket_messages($state->{io}, $state->{endpoint});
    $self->close if !$self->is_closed;
    return;
}

sub _drain_websocket_messages ($self, $io, $endpoint) {
    while (!$self->is_closed) {
        my $before = $io->buffered_bytes;
        my $message = $endpoint->get_next_message;
        my $after = $io->buffered_bytes;

        if (defined $message) {
            if (!ref($message) && $message eq '') {
                last;
            }
            $self->on_websocket_message($message);
            next;
        }

        # A control frame can be consumed without producing an application
        # message. Keep draining if bytes were consumed; stop only when the
        # parser made no progress and therefore needs more network input.
        last if $after == $before;
    }
    return;
}

sub on_websocket_message ($self, $message) {
    croak ref($self) . ' must define on_websocket_message()';
}

1;
