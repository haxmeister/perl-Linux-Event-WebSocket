use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::WebSocket::Server;

my $port = $ENV{PORT} // 9101;

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    max_message_size => 32 * 1024 * 1024,

    on_message => sub ($ws, $payload, $type) {
        if ($type eq 'text') {
            $ws->send_text($payload);
        } else {
            $ws->send_binary($payload);
        }
    },

    on_error => sub ($ws, $error) {
        warn "Linux::Event::WebSocket benchmark error: $error\n";
    },
);

STDOUT->autoflush(1);
say "READY 127.0.0.1:" . $server->port;
$loop->run;
