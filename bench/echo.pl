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
my $seconds = 1.5;
my $window = 32;
my $type = 'binary';

GetOptions(
    'clients=i' => \$clients,
    'bytes=i'   => \$bytes,
    'seconds=f' => \$seconds,
    'window=i'  => \$window,
    'type=s'    => \$type,
) or die "invalid benchmark option\n";

die "--clients must be positive\n" if $clients < 1;
die "--bytes must be positive\n" if $bytes < 1;
die "--seconds must be positive\n" if $seconds <= 0;
die "--window must be positive\n" if $window < 1;
die "--type must be text or binary\n"
    if $type ne 'text' && $type ne 'binary';

my $payload = 'x' x $bytes;
my $loop = Linux::Event::Loop->new;
my @connection;
my @client;
my $opened = 0;
my $messages = 0;
my $started;
my $elapsed;
my $stopping = 0;
my $bench_timer;
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
        die "server error: $error\n";
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

sub start_measurement () {
    $started = time;

    $bench_timer = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => $seconds,
        on_timer => sub ($timer) {
            $elapsed = time - $started;
            $stopping = 1;
            $_->abort for @connection;
            $server->close;
            $guard->cancel;
            $loop->stop;
        },
    );

    for my $ws (@connection) {
        send_one($ws) for 1 .. $window;
    }
    return;
}

$guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => $seconds + 10,
    on_timer => sub ($timer) {
        die "echo benchmark timed out\n";
    },
);

for my $id (1 .. $clients) {
    my $client = Linux::Event::WebSocket::Client->new(
        loop => $loop,

        on_open => sub ($ws) {
            push @connection, $ws;
            ++$opened;
            start_measurement() if $opened == $clients;
        },

        on_message => sub ($ws, $message, $message_type) {
            return if $stopping;
            ++$messages;
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
