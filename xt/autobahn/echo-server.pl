use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::WebSocket::Server;

my $host = $ENV{AUTOBahn_HOST} // '127.0.0.1';
my $port = $ENV{AUTOBahn_PORT} // 9001;

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => $host,
    port => $port,

    on_message => sub ($ws, $payload, $type) {
        if ($type eq 'text') {
            $ws->send_text($payload);
        } else {
            $ws->send_binary($payload);
        }
    },

    on_error => sub ($ws, $error) {
        warn "Autobahn testee error: $error\n";
    },
);

STDOUT->autoflush(1);
say "READY " . $server->host . ":" . $server->port;
$loop->run;
