use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Linux::Event::Loop;
use LEWS::Prototype::Connection ();

{
    package Local::WebSocketServer;
    use v5.36;
    use parent 'LEWS::Prototype::Connection';

    sub websocket_endpoint_type ($class) { 'server' }

    sub on_websocket_message ($self, $message) {
        push @{ $self->data->{server_messages} }, [
            $message->get_type,
            $message->get_payload,
        ];
        $self->send_text('echo:' . $message->get_payload);
    }

    sub on_error ($self, $error) {
        $self->data->{error} = "$error";
        $self->loop->stop;
    }
}

{
    package Local::WebSocketClient;
    use v5.36;
    use parent 'LEWS::Prototype::Connection';

    sub websocket_endpoint_type ($class) { 'client' }

    sub on_websocket_message ($self, $message) {
        push @{ $self->data->{client_messages} }, [
            $message->get_type,
            $message->get_payload,
        ];
        $self->loop->stop;
    }

    sub on_error ($self, $error) {
        $self->data->{error} = "$error";
        $self->loop->stop;
    }
}

socketpair(my $client_fh, my $server_fh, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";

my $loop = Linux::Event::Loop->new;
my $state = {
    server_messages => [],
    client_messages => [],
    error           => '',
};

my $server = Local::WebSocketServer->new(
    loop => $loop,
    fh   => $server_fh,
    data => $state,
);

my $client = Local::WebSocketClient->new(
    loop => $loop,
    fh   => $client_fh,
    data => $state,
);

ok($client->send_text('hello'), 'adopted client queues first WebSocket message');
$loop->run_for(2);

is($state->{error}, '', 'Linux::Event transport reported no error');
is_deeply(
    $state->{server_messages},
    [ [ text => 'hello' ] ],
    'server endpoint parsed masked client message',
);
is_deeply(
    $state->{client_messages},
    [ [ text => 'echo:hello' ] ],
    'client endpoint parsed unmasked server reply',
);

is(
    $client->websocket_endpoint_type_name,
    'client',
    'client endpoint type is retained in connection state',
);
is(
    $server->websocket_endpoint_type_name,
    'server',
    'server endpoint type is retained in connection state',
);

$client->close if !$client->is_closed;
$server->close if !$server->is_closed;

done_testing;
