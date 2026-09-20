use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::WebSocket::Server;

my $port = $ENV{PORT} // 9601;
my $path = $ENV{SEND_PATH} // 'public';
my $ack = '{"ok":true}';
my $frame = pack('CC', 0x81, length($ack)) . $ack;

die "unknown SEND_PATH=$path\n"
    if $path !~ /\A(?:public|engine|native_deferred|native_immediate|preframed)\z/;

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    max_message_size => 32 * 1024 * 1024,

    on_message => sub ($ws, $payload, $type) {
        die "send-path benchmark received non-text message\n"
            if $type ne 'text';
        die "send-path benchmark received malformed request\n"
            if substr($payload, 0, 6) ne '{"op":';

        if ($path eq 'public') {
            $ws->send_text($ack);
            return;
        }

        my $engine = $ws->_websocket_state->{engine};

        if ($path eq 'engine') {
            $engine->send_text($ack);
        } elsif ($path eq 'native_deferred') {
            $engine->{native}->queue_message(1, $ack);
        } elsif ($path eq 'native_immediate') {
            $engine->{native}->queue_message(1, $ack);
            my $wire = $engine->{native}->flush;
            $ws->write($wire) if length $wire;
        } else {
            $ws->write($frame);
        }
        return;
    },

    on_error => sub ($ws, $error) {
        warn "Linux::Event::WebSocket send-path benchmark error: $error\n";
    },
);

STDOUT->autoflush(1);
say "READY 127.0.0.1:" . $server->port;
$loop->run;
