use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::HTTP::Server;
use Net::WebSocket::Endpoint::Client ();
use Net::WebSocket::Handshake::Client ();
use Net::WebSocket::Parser ();
use LEWS::Prototype::Connection ();
use LEWS::Prototype::Handshake ();
use LEWS::Prototype::IO ();

{
    package Local::NullOutput;
    use v5.36;
    sub new ($class) { bless {}, $class }
    sub write ($self, $bytes) { 1 }
}

{
    package Local::HTTPWebSocketServer;
    use v5.36;
    use parent 'LEWS::Prototype::Connection';

    sub websocket_endpoint_type ($class) { 'server' }

    sub on_websocket_message ($self, $message) {
        $self->data->{server_message} = [
            $message->get_type,
            $message->get_payload,
        ];
        $self->send_text('echo:' . $message->get_payload);
    }
}

{
    package Local::HTTPWebSocketClient;
    use v5.36;
    use parent 'LEWS::Prototype::Connection';

    sub websocket_endpoint_type ($class) { 'client' }

    sub on_websocket_message ($self, $message) {
        $self->data->{client_message} = [
            $message->get_type,
            $message->get_payload,
        ];
        $self->loop->stop;
    }
}

{
    package Local::HTTPUpgradeClient;
    use v5.36;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_ready ($self) {
        my $state = $self->data;
        my $handshake = Net::WebSocket::Handshake::Client->new(
            uri => 'ws://127.0.0.1:' . $state->{port} . '/chat',
            key => 'dGhlIHNhbXBsZSBub25jZQ==',
        );
        $state->{client_handshake} = $handshake;

        my $reader = LEWS::Prototype::IO->new;
        my $endpoint = Net::WebSocket::Endpoint::Client->new(
            parser => Net::WebSocket::Parser->new($reader),
            out    => Local::NullOutput->new,
        );
        my $frame = $endpoint->create_message('text', 'hello')->to_bytes;

        # One Linux::Event write deliberately contains both the complete HTTP
        # Upgrade and the first masked WebSocket frame. The server must preserve
        # those post-HTTP bytes across transition_to().
        my $wire = $handshake->to_string . $frame;
        $state->{combined_write_bytes} = length $wire;
        $self->write($wire);
    }

    sub on_data ($self, $bytes) {
        my $state = $self->data;
        $state->{http_response_bytes} .= $bytes;

        my $marker = index($state->{http_response_bytes}, "\r\n\r\n");
        return if $marker < 0;

        my $head = substr($state->{http_response_bytes}, 0, $marker + 4);
        my $tail = substr($state->{http_response_bytes}, $marker + 4);
        $state->{http_response_head} = $head;
        $state->{http_response_tail_at_transition} = length $tail;

        my @line = split /\r\n/, $head;
        my $status_line = shift @line;
        my ($code, $reason) =
            $status_line =~ /\AHTTP\/1\.1 ([0-9]{3})(?: (.*))?\z/
            or die "invalid HTTP Upgrade response status line: $status_line";

        my $handshake = $state->{client_handshake};
        $handshake->valid_status_or_die($code, $reason // '');

        my @headers;
        for my $line (@line) {
            next if $line eq '';
            my ($name, $value) = $line =~ /\A([^:]+):[ \t]*(.*)\z/
                or die "invalid HTTP Upgrade response header: $line";
            push @headers, $name, $value;
        }
        $handshake->consume_headers(@headers);
        $state->{client_handshake_valid} = 1;

        delete $state->{http_response_bytes};
        if (length $tail) {
            $self->transition_to('Local::HTTPWebSocketClient', input => $tail);
        } else {
            $self->transition_to('Local::HTTPWebSocketClient');
        }
    }

    sub on_error ($self, $error) {
        $self->data->{error} = "$error";
        $self->loop->stop;
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    error          => '',
    server_message => undef,
    client_message => undef,
};

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    data => $state,

    on_request => sub ($conn, $request, $response) {
        $state->{request_class} = ref $request;

        my $handshake = LEWS::Prototype::Handshake->server_from_request(
            $request,
        );
        LEWS::Prototype::Handshake->apply_server_response(
            $handshake,
            $response,
        );

        $conn->transaction->upgrade('Local::HTTPWebSocketServer');
    },

    on_error => sub ($conn, $error) {
        $state->{error} = "$error";
        $loop->stop;
    },

    on_listener_error => sub ($listener, $error) {
        $state->{error} = "$error";
        $loop->stop;
    },
);

$state->{port} = $server->port;

my $client = Local::HTTPUpgradeClient->connect(
    loop    => $loop,
    host    => '127.0.0.1',
    port    => $server->port,
    timeout => 2,
    data    => $state,
);

$loop->run_for(3);

is($state->{error}, '', 'HTTP Upgrade and WebSocket transport report no error');
is(
    $state->{request_class},
    'Linux::Event::HTTP::Request',
    'same handshake adapter accepts Linux::Event::HTTP request object',
);
ok($state->{client_handshake_valid}, 'client validates the generated 101 handshake');
like(
    $state->{http_response_head} // '',
    qr/\AHTTP\/1\.1 101 Switching Protocols\r\n/,
    'Linux::Event::HTTP emits 101 Switching Protocols',
);
is_deeply(
    $state->{server_message},
    [ text => 'hello' ],
    'first masked WebSocket frame survives HTTP-to-WebSocket transition',
);
is_deeply(
    $state->{client_message},
    [ text => 'echo:hello' ],
    'transitioned server sends WebSocket reply after queued 101 response',
);
isa_ok($client, 'Local::HTTPWebSocketClient', 'client also transitions in place after 101');

$client->close if !$client->is_closed;
$server->close;

done_testing;
