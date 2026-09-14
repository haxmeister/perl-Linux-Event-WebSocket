package Linux::Event::WebSocket::Client::_HTTPConnection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::HTTP::Client::Connection';

use Carp qw(croak);
use Scalar::Util qw(blessed);

sub _websocket_state ($self) {
    my $state = $self->SUPER::data;
    croak 'WebSocket client connection state is unavailable'
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

# HTTP Client::Connection captures this method as its user drain handler and
# keeps that constructor override through transition_to(). Forward it after the
# same object becomes a WebSocket connection.
sub on_drain ($self) {
    if ($self->isa('Linux::Event::WebSocket::Connection')) {
        Linux::Event::WebSocket::Connection::on_drain($self);
    }
    return;
}

1;
