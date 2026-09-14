use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Net::WebSocket::Endpoint::Client ();
use Net::WebSocket::Endpoint::Server ();
use Net::WebSocket::Parser ();
use LEWS::Prototype::IO ();

{
    package Local::BridgeStream;
    use v5.36;

    sub new ($class, $peer) {
        return bless {
            peer   => $peer,
            writes => [],
        }, $class;
    }

    sub write ($self, $bytes) {
        push @{ $self->{writes} }, $bytes;
        $self->{peer}->feed($bytes);
        return 1;
    }

    sub writes ($self) {
        return $self->{writes};
    }
}

my $client_io = LEWS::Prototype::IO->new;
my $server_io = LEWS::Prototype::IO->new;

my $client_stream = Local::BridgeStream->new($server_io);
my $server_stream = Local::BridgeStream->new($client_io);

$client_io->stream($client_stream);
$server_io->stream($server_stream);

my $client = Net::WebSocket::Endpoint::Client->new(
    parser => Net::WebSocket::Parser->new($client_io),
    out    => $client_io,
    max_pings => 1,
);
my $server = Net::WebSocket::Endpoint::Server->new(
    parser => Net::WebSocket::Parser->new($server_io),
    out    => $server_io,
);

$client->do_not_die_on_close;
$server->do_not_die_on_close;

my $client_message = $client->create_message('text', 'hello');
ok(
    $client_io->write($client_message->to_bytes),
    'client message writes through the Linux::Event-style adapter',
);

my $client_wire = $client_stream->writes->[-1];
ok(
    ord(substr($client_wire, 1, 1)) & 0x80,
    'client frame is masked by Net::WebSocket',
);

my $received = $server->get_next_message;
isa_ok($received, 'Net::WebSocket::Message');
is($received->get_type, 'text', 'server receives text message type');
is($received->get_payload, 'hello', 'server receives complete payload');

my $server_message = $server->create_message('text', 'world');
ok(
    $server_io->write($server_message->to_bytes),
    'server message writes through the same adapter',
);

my $server_wire = $server_stream->writes->[-1];
ok(
    !(ord(substr($server_wire, 1, 1)) & 0x80),
    'server frame is not masked',
);

$received = $client->get_next_message;
isa_ok($received, 'Net::WebSocket::Message');
is($received->get_type, 'text', 'client receives text message type');
is($received->get_payload, 'world', 'client receives complete payload');

my $server_writes_before_ping = scalar @{ $server_stream->writes };
$client->check_heartbeat;
my $control = $server->get_next_message;
ok(!defined($control), 'server consumes ping as a control frame');
is(
    scalar(@{ $server_stream->writes }),
    $server_writes_before_ping + 1,
    'server automatically writes pong through adapter',
);

$control = $client->get_next_message;
ok(!defined($control), 'client consumes pong as a control frame');

$client->check_heartbeat;
ok(!$client->sent_close_frame, 'pong reset heartbeat state');
$server->get_next_message;
$client->get_next_message;

$client->close(code => 'SUCCESS', reason => 'done');
$control = $server->get_next_message;
ok(!defined($control), 'server consumes close as a control frame');
ok($server->received_close_frame, 'server records received close frame');
ok($server->sent_close_frame, 'server automatically replies with close frame');

$control = $client->get_next_message;
ok(!defined($control), 'client consumes close reply as a control frame');
ok($client->received_close_frame, 'client records received close reply');

is($client_io->buffered_bytes, 0, 'client adapter buffer is drained');
is($server_io->buffered_bytes, 0, 'server adapter buffer is drained');

done_testing;
