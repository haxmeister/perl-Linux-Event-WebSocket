use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;
use Linux::Event::WebSocket::Server;

my $clients = 1;
my $bytes = 64;
my $seconds = 2.0;
my $warmup = 0.5;
my $window = 32;
my $type = 'binary';

GetOptions(
    'clients=i' => \$clients,
    'bytes=i'   => \$bytes,
    'seconds=f' => \$seconds,
    'warmup=f'  => \$warmup,
    'window=i'  => \$window,
    'type=s'    => \$type,
) or die "invalid benchmark option\n";

die "--clients must be positive\n" if $clients < 1;
die "--bytes must be positive\n" if $bytes < 1;
die "--seconds must be positive\n" if $seconds <= 0;
die "--warmup must be non-negative\n" if $warmup < 0;
die "--window must be positive\n" if $window < 1;
die "--type must be text or binary\n"
    if $type ne 'text' && $type ne 'binary';

my $payload = 'x' x $bytes;
my $loop = Linux::Event::Loop->new;
my @connection;
my @client;
my $opened = 0;
my $messages = 0;
my $warmup_deadline;
my $started;
my $deadline;
my $elapsed;
my $stopping = 0;
my $guard;

my $server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,

    on_message => sub ($ws, $message, $message_type) {
        if ($message_type eq 'text') {
            $ws->send_text($message);
        } else {
            $ws->send_binary($message);
        }
    },

    on_error => sub ($connection, $error) {
        die "server error: $error\n" if !$stopping;
    },
);

sub send_one ($ws) {
    if ($type eq 'text') {
        $ws->send_text($payload);
    } else {
        $ws->send_binary($payload);
    }
    return;
}

sub stop_measurement ($now) {
    return if $stopping++;
    $elapsed = $now - $started;
    $_->abort for @connection;
    $server->close;
    $guard->cancel;
    $loop->stop;
    return;
}

sub start_traffic () {
    $warmup_deadline = time + $warmup;
    for my $ws (@connection) {
        send_one($ws) for 1 .. $window;
    }
    return;
}

$guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => $warmup + $seconds + 10,
    on_timer => sub ($timer) {
        die "engine benchmark timed out\n";
    },
);

for my $id (1 .. $clients) {
    my $client = Linux::Event::WebSocket::Client->new(
        loop => $loop,

        on_open => sub ($ws) {
            push @connection, $ws;
            ++$opened;
            start_traffic() if $opened == $clients;
        },

        on_message => sub ($ws, $message, $message_type) {
            return if $stopping;
            my $now = time;

            if (!defined $started && $now >= $warmup_deadline) {
                $messages = 0;
                $started = $now;
                $deadline = $started + $seconds;
            }

            if (defined $started) {
                if ($now >= $deadline) {
                    stop_measurement($now);
                    return;
                }
                ++$messages;
            }

            send_one($ws);
        },

        on_error => sub ($connection, $error) {
            die "client $id error: $error\n" if !$stopping;
        },
    );

    push @client, $client;
    $client->connect('ws://127.0.0.1:' . $server->port . '/benchmark');
}

$loop->run;

die "benchmark never started\n" if !defined $started;
die "benchmark did not record elapsed time\n" if !defined $elapsed;

my $rate = $messages / $elapsed;
my $payload_mib = ($messages * $bytes) / $elapsed / (1024 * 1024);

printf "type=%s bytes=%d clients=%d window=%d messages=%d seconds=%.6f rate=%.0f msg/s payload=%.2f MiB/s\n",
    $type, $bytes, $clients, $window, $messages, $elapsed, $rate, $payload_mib;
