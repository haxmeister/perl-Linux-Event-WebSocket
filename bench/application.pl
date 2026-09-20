use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;
use Linux::Event::WebSocket::Server;

my $clients = 20;
my $bytes = 1024;
my $seconds = 1.5;
my $window = 4;
my $label = 'current';

GetOptions(
    'clients=i' => \$clients,
    'bytes=i'   => \$bytes,
    'seconds=f' => \$seconds,
    'window=i'  => \$window,
    'label=s'   => \$label,
) or die "invalid benchmark option\n";

die "--clients must be positive\n" if $clients < 1;
die "--bytes must be positive\n" if $bytes < 1;
die "--seconds must be positive\n" if $seconds <= 0;
die "--window must be positive\n" if $window < 1;

my $prefix = '{"op":"message","room":"bench","body":"';
my $suffix = '","seq":12345}';
my $minimum = length($prefix) + length($suffix);
die "--bytes must be at least $minimum for the application payload\n"
    if $bytes < $minimum;

my $payload = $prefix . ('x' x ($bytes - $minimum)) . $suffix;
my $ack = '{"ok":true}';

my $loop = Linux::Event::Loop->new;
my @connection;
my @client;
my $opened = 0;
my $transactions = 0;
my $server_messages = 0;
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
        die "server received non-text application message\n"
            if $message_type ne 'text';
        die "server received malformed application message\n"
            if substr($message, 0, 6) ne '{"op":';

        ++$server_messages;
        $ws->send_text($ack);
    },

    on_error => sub ($connection, $error) {
        die "server error: $error\n" if !$stopping;
    },
);

sub send_request ($ws) {
    $ws->send_text($payload);
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
        send_request($ws) for 1 .. $window;
    }
    return;
}

$guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => $seconds + 10,
    on_timer => sub ($timer) {
        die "application benchmark timed out\n";
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
            die "client $id received non-text acknowledgement\n"
                if $message_type ne 'text';
            die "client $id received unexpected acknowledgement\n"
                if $message ne $ack;

            ++$transactions;
            send_request($ws);
        },

        on_error => sub ($connection, $error) {
            die "client $id error: $error\n" if !$stopping;
        },
    );

    push @client, $client;
    $client->connect('ws://127.0.0.1:' . $server->port . '/application');
}

$loop->run;

die "benchmark never started\n" if !defined $started;
die "benchmark did not record elapsed time\n" if !defined $elapsed;
die "server/client transaction accounting diverged\n"
    if $server_messages < $transactions;

my $rate = $transactions / $elapsed;
my $ingress_mib = ($transactions * $bytes) / $elapsed / (1024 * 1024);
my $wire_payload_mib =
    ($transactions * ($bytes + length($ack))) / $elapsed / (1024 * 1024);

printf "label=%s bytes=%d clients=%d window=%d transactions=%d seconds=%.6f rate=%.0f txn/s ingress=%.2f MiB/s payload=%.2f MiB/s\n",
    $label, $bytes, $clients, $window, $transactions, $elapsed, $rate,
    $ingress_mib, $wire_payload_mib;
