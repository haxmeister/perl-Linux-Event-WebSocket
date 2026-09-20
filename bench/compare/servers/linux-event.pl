use v5.36;
use strict;
use warnings;

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;
use Linux::Event::WebSocket::Server;

my $port = $ENV{PORT} // 9101;
my $mode = $ENV{BENCH_MODE} // 'echo';
my $ack = '{"ok":true}';
my $collect_stats = $ENV{BENCH_STATS} // 0;
my @connections;
my $stats_timer;

my $loop = Linux::Event::Loop->new;
my $server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => $port,
    max_message_size => 32 * 1024 * 1024,

    on_open => sub ($ws) {
        return if !$collect_stats;
        push @connections, $ws;
        return if $stats_timer;

        $stats_timer = Linux::Event::Kernel::Timer->new(
            loop => $loop,
            after => 1.5,
            on_timer => sub ($timer) {
                my %sum;
                my $active = 0;
                for my $connection (@connections) {
                    my $state = $connection->{xs_state} or next;
                    my $stats = $state->stats;
                    ++$active;
                    $sum{$_} += $stats->{$_} // 0 for qw(
                        consumer_input_calls read_calls bytes_read
                        input_appends write_submit_calls write_calls writev_calls
                        bytes_written queued_segments write_eagain_count
                        pending_bytes
                    );
                }
                warn join(' ',
                    'BENCH_STATS',
                    "active=$active",
                    map { "$_=" . ($sum{$_} // 0) } qw(
                        consumer_input_calls read_calls bytes_read
                        input_appends write_submit_calls write_calls writev_calls
                        bytes_written queued_segments write_eagain_count
                        pending_bytes
                    ),
                ) . "\n";
            },
        );
    },

    on_message => sub ($ws, $payload, $type) {
        if ($mode eq 'application') {
            die "application benchmark received non-text message\n"
                if $type ne 'text';
            die "application benchmark received malformed request\n"
                if substr($payload, 0, 6) ne '{"op":';
            $ws->send_text($ack);
            return;
        }

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
