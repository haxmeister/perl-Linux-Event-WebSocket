use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;

my $label = 'linux_event_client';
my $host = '127.0.0.1';
my $port = 9200;
my $type = 'binary';
my $bytes = 64;
my $clients = 1;
my $window = 32;
my $warmup = 0.5;
my $seconds = 1.5;

GetOptions(
    'label=s'   => \$label,
    'host=s'    => \$host,
    'port=i'    => \$port,
    'type=s'    => \$type,
    'bytes=i'   => \$bytes,
    'clients=i' => \$clients,
    'window=i'  => \$window,
    'warmup=f'  => \$warmup,
    'seconds=f' => \$seconds,
) or die "invalid benchmark option\n";

die "--type must be text or binary\n"
    if $type ne 'text' && $type ne 'binary';
die "--bytes must be positive\n" if $bytes < 1;
die "--clients must be positive\n" if $clients < 1;
die "--window must be positive\n" if $window < 1;
die "--warmup must be non-negative\n" if $warmup < 0;
die "--seconds must be positive\n" if $seconds <= 0;

my $payload = 'x' x $bytes;
my $loop = Linux::Event::Loop->new;
my @connection;
my @client;
my $opened = 0;
my $count = 0;
my $measuring = 0;
my $stopping = 0;
my $start;
my $elapsed;
my ($warmup_timer, $measure_timer, $guard);

sub send_one ($ws) {
    if ($type eq 'text') {
        $ws->send_text($payload);
    } else {
        $ws->send_binary($payload);
    }
    return;
}

sub finish () {
    return if $stopping;
    $stopping = 1;
    $elapsed = time - $start;
    $_->abort for @connection;
    $guard->cancel if $guard;
    $loop->stop;
    return;
}

sub start_measurement () {
    send_one($_) for map { ($_) x $window } @connection;

    $warmup_timer = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => $warmup,
        on_timer => sub ($timer) {
            $count = 0;
            $start = time;
            $measuring = 1;

            $measure_timer = Linux::Event::Kernel::Timer->new(
                loop => $loop,
                after => $seconds,
                on_timer => sub ($measure) {
                    finish();
                },
            );
        },
    );
    return;
}

$guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => $warmup + $seconds + 10,
    on_timer => sub ($timer) {
        die "Linux::Event client comparison timed out\n";
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
            die "message type mismatch: expected $type\n"
                if $message_type ne $type;
            die "message size mismatch\n"
                if length($message) != $bytes;
            ++$count if $measuring;
            send_one($ws);
        },

        on_close => sub ($ws, $code, $reason) {
            die "benchmark connection closed early\n" if !$stopping;
        },

        on_error => sub ($ws, $error) {
            die "Linux::Event client error: $error\n" if !$stopping;
        },
    );

    push @client, $client;
    $client->connect("ws://$host:$port/benchmark?type=$type");
}

$loop->run;

die "benchmark never started\n" if !defined $start;
die "benchmark did not finish\n" if !defined $elapsed;

my $rate = $count / $elapsed;
my $mib = $rate * $bytes / (1024 * 1024);

printf "%s,%s,%d,%d,%d,%d,%.6f,%.0f,%.2f\n",
    $label, $type, $bytes, $clients, $window, $count,
    $elapsed, $rate, $mib;
