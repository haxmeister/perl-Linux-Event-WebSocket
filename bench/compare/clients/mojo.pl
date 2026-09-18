use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Mojo::IOLoop;
use Mojo::UserAgent;
use Time::HiRes qw(time);

my $label = 'mojolicious_client';
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
my $ua = Mojo::UserAgent->new;
$ua->max_connections($clients + 4);
$ua->inactivity_timeout(300);

my @tx;
my $opened = 0;
my $count = 0;
my $measuring = 0;
my $stopping = 0;
my $start;
my $elapsed;

sub send_one ($tx) {
    if ($type eq 'binary') {
        $tx->send({binary => $payload});
    } else {
        $tx->send({text => $payload});
    }
    return;
}

sub finish () {
    return if $stopping;
    $stopping = 1;
    $elapsed = time - $start;
    $_->finish for @tx;
    Mojo::IOLoop->stop;
    return;
}

sub start_measurement () {
    for my $tx (@tx) {
        send_one($tx) for 1 .. $window;
    }

    Mojo::IOLoop->timer($warmup => sub {
        $count = 0;
        $start = time;
        $measuring = 1;
        Mojo::IOLoop->timer($seconds => sub {
            finish();
        });
    });
    return;
}

Mojo::IOLoop->timer($warmup + $seconds + 10 => sub {
    die "Mojolicious client comparison timed out\n";
});

for my $id (1 .. $clients) {
    $ua->websocket(
        "ws://$host:$port/benchmark?type=$type" => sub ($ua, $transaction) {
            die "Mojolicious WebSocket handshake failed\n"
                if !$transaction->is_websocket;

            push @tx, $transaction;

            $transaction->on(message => sub ($tx, $message) {
                return if $stopping;
                die "message size mismatch\n"
                    if length($message) != $bytes;
                ++$count if $measuring;
                send_one($tx);
            });

            $transaction->on(finish => sub ($tx, @rest) {
                die "benchmark connection closed early\n" if !$stopping;
            });

            ++$opened;
            start_measurement() if $opened == $clients;
        },
    );
}

Mojo::IOLoop->start;

die "benchmark never started\n" if !defined $start;
die "benchmark did not finish\n" if !defined $elapsed;

my $rate = $count / $elapsed;
my $mib = $rate * $bytes / (1024 * 1024);

printf "%s,%s,%d,%d,%d,%d,%.6f,%.0f,%.2f\n",
    $label, $type, $bytes, $clients, $window, $count,
    $elapsed, $rate, $mib;
