#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Net::WebSocket::Handshake::Server ();
use Uniform::HTTP::Request ();

# This is deliberately a prototype, not public API.
#
# It proves that a framework-neutral Uniform::HTTP request can feed the
# documented Net::WebSocket handshake interface without HTTP::Request,
# HTTP::Response, Net::WebSocket::HTTP_R, or IO::Framed.

my $request = Uniform::HTTP::Request->new(
    method  => 'GET',
    target  => '/chat',
    version => '1.1',
    headers => [
        [ Host                    => 'server.example.com' ],
        [ Upgrade                 => 'websocket' ],
        [ Connection              => 'Upgrade' ],
        [ 'Sec-WebSocket-Key'     => 'dGhlIHNhbXBsZSBub25jZQ==' ],
        [ 'Sec-WebSocket-Origin'  => 'http://example.com' ],
        [ 'Sec-WebSocket-Version' => '13' ],
    ],
);

my $handshake = Net::WebSocket::Handshake::Server->new;

$handshake->valid_method_or_die($request->method);
$handshake->valid_protocol_or_die('HTTP/' . $request->version);

my @headers;
for my $index (0 .. $request->header_count - 1) {
    push @headers,
        $request->header_name($index),
        $request->header_value($index);
}

$handshake->consume_headers(@headers);

print $handshake->to_string;
