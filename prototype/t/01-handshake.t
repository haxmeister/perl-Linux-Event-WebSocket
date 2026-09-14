use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Uniform::HTTP::Request ();
use LEWS::Prototype::Handshake ();

my $request = Uniform::HTTP::Request->new(
    method  => 'GET',
    target  => '/chat',
    version => '1.1',
    headers => [
        [ Host                     => 'server.example.com' ],
        [ Upgrade                  => 'websocket' ],
        [ Connection               => 'keep-alive, Upgrade' ],
        [ 'Sec-WebSocket-Key'      => 'dGhlIHNhbXBsZSBub25jZQ==' ],
        [ 'Sec-WebSocket-Version'  => '13' ],
        [ 'Sec-WebSocket-Protocol' => 'chat, superchat' ],
    ],
);

my $handshake = LEWS::Prototype::Handshake->server_from_request(
    $request,
    subprotocols => [qw(superchat chat)],
);

is(
    $handshake->get_subprotocol,
    'chat',
    'Net::WebSocket negotiates a subprotocol from Uniform::HTTP headers',
);

my $response = $handshake->to_string;

like(
    $response,
    qr/\AHTTP\/1\.1 101 Switching Protocols\r\n/,
    'server handshake creates a 101 response',
);
like(
    $response,
    qr/^Upgrade: websocket\r$/m,
    'Upgrade response header is present',
);
like(
    $response,
    qr/^Connection: Upgrade\r$/m,
    'Connection response header is present',
);
like(
    $response,
    qr/^Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=\r$/m,
    'RFC 6455 sample accept value is correct',
);
like(
    $response,
    qr/^Sec-WebSocket-Protocol: chat\r$/m,
    'negotiated subprotocol is serialized',
);
like(
    $response,
    qr/\r\n\r\n\z/,
    'handshake output terminates the HTTP header block',
);

my $bad_method = Uniform::HTTP::Request->new(
    method  => 'POST',
    target  => '/chat',
    version => '1.1',
    headers => [
        [ Upgrade                 => 'websocket' ],
        [ Connection              => 'Upgrade' ],
        [ 'Sec-WebSocket-Key'     => 'dGhlIHNhbXBsZSBub25jZQ==' ],
        [ 'Sec-WebSocket-Version' => '13' ],
    ],
);

my $ok = eval {
    LEWS::Prototype::Handshake->server_from_request($bad_method);
    1;
};
ok(!$ok, 'Net::WebSocket rejects a non-GET Uniform::HTTP request');

my $bad_version = Uniform::HTTP::Request->new(
    method  => 'GET',
    target  => '/chat',
    version => '1.0',
    headers => [
        [ Upgrade                 => 'websocket' ],
        [ Connection              => 'Upgrade' ],
        [ 'Sec-WebSocket-Key'     => 'dGhlIHNhbXBsZSBub25jZQ==' ],
        [ 'Sec-WebSocket-Version' => '13' ],
    ],
);

$ok = eval {
    LEWS::Prototype::Handshake->server_from_request($bad_version);
    1;
};
ok(!$ok, 'Net::WebSocket rejects HTTP/1.0 through the adapter');

done_testing;
