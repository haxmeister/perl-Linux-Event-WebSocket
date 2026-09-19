use v5.36;
use strict;
use warnings;

use Encode qw(encode);
use Getopt::Long qw(GetOptions);
use Scalar::Util qw(refaddr);
use Time::HiRes qw(time);

use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;
use Linux::Event::WebSocket::Server;

my $fanout = 100;
my $target_bytes = 256;
my $seconds = 2.0;
my $warmup = 0.5;

GetOptions(
    'fanout=i' => \$fanout,
    'bytes=i'  => \$target_bytes,
    'seconds=f' => \$seconds,
    'warmup=f'  => \$warmup,
) or die "invalid benchmark option\n";

die "--fanout must be positive\n" if $fanout < 1;
die "--bytes must be positive\n" if $target_bytes < 1;
die "--seconds must be positive\n" if $seconds <= 0;
die "--warmup must be non-negative\n" if $warmup < 0;

my $unit =
    '{"type":"message","icon":"'
    . chr(0x1f642)
    . '","user":"alice","room":"general","text":"Hello from Perl","ok":true}';

sub utf8_bytes ($text) {
    return length encode('UTF-8', $text);
}

sub make_payload ($target) {
    my @character = split //, $unit;
    my @width = map { utf8_bytes($_) } @character;
    my $payload = '';
    my $used = 0;
    my $index = 0;

    for (;;) {
        my $slot = $index++ % @character;
        my $width = $width[$slot];
        last if $used + $width > $target;
        $payload .= $character[$slot];
        $used += $width;
    }

    $payload .= 'x' x ($target - $used) if $used < $target;
    return $payload;
}

my $payload = make_payload($target_bytes);
my $wire_bytes = utf8_bytes($payload);
my $characters = length $payload;

my $loop = Linux::Event::Loop->new;
my $server;

my @server_ws;
my @subscriber_client;
my @subscriber_ws;
my $producer_client;
my $producer_ws;

my $server_open = 0;
my $subscriber_open = 0;
my $producer_launching = 0;

my $cycle_deliveries = 0;
my $broadcasts = 0;
my $deliveries = 0;
my $warmup_deadline;
my $started;
my $deadline;
my $elapsed;
my $stopping = 0;
my $traffic_started = 0;
my $guard;

sub stop_measurement ($now) {
    return if $stopping++;
    $elapsed = $now - $started;

    $_->abort for @subscriber_ws;
    $producer_ws->abort if defined $producer_ws && !$producer_ws->is_closed;
    $server->close;
    $guard->cancel;
    $loop->stop;
    return;
}

sub producer_send () {
    return if $stopping;
    $producer_ws->send_text($payload);
    return;
}

sub completed_broadcast () {
    return if $stopping;

    my $now = time;

    if (!defined $started && $now >= $warmup_deadline) {
        $broadcasts = 0;
        $deliveries = 0;
        $started = $now;
        $deadline = $started + $seconds;
    }

    if (defined $started) {
        if ($now >= $deadline) {
            stop_measurement($now);
            return;
        }

        ++$broadcasts;
        $deliveries += $fanout;
    }

    producer_send();
    return;
}

sub maybe_start_traffic () {
    return if $traffic_started;
    return if !defined $producer_ws;
    return if $server_open != $fanout + 1;

    $traffic_started = 1;
    $warmup_deadline = time + $warmup;
    producer_send();
    return;
}

sub launch_producer () {
    return if $producer_launching;
    return if $subscriber_open != $fanout;
    return if $server_open != $fanout;

    $producer_launching = 1;
    $producer_client = Linux::Event::WebSocket::Client->new(
        loop => $loop,

        on_open => sub ($ws) {
            $producer_ws = $ws;
            maybe_start_traffic();
        },

        on_message => sub ($ws, $message, $type) {
            die "producer unexpectedly received a broadcast\n";
        },

        on_error => sub ($connection, $error) {
            die "producer error: $error\n" if !$stopping;
        },
    );

    $producer_client->connect(
        'ws://127.0.0.1:' . $server->port . '/producer'
    );
    return;
}

$server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,

    on_open => sub ($ws) {
        push @server_ws, $ws;
        ++$server_open;
        launch_producer();
        maybe_start_traffic();
    },

    on_message => sub ($sender, $message, $type) {
        my $sender_id = refaddr($sender);
        my $targets = 0;

        for my $ws (@server_ws) {
            next if refaddr($ws) == $sender_id;
            $ws->send_text($message);
            ++$targets;
        }

        die "broadcast target count $targets != fanout $fanout\n"
            if $targets != $fanout;
    },

    on_error => sub ($connection, $error) {
        die "server error: $error\n" if !$stopping;
    },
);

$guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => $warmup + $seconds + 45,
    on_timer => sub ($timer) {
        die "fanout benchmark timed out\n";
    },
);

for my $id (1 .. $fanout) {
    my $client = Linux::Event::WebSocket::Client->new(
        loop => $loop,

        on_open => sub ($ws) {
            push @subscriber_ws, $ws;
            ++$subscriber_open;
            launch_producer();
        },

        on_message => sub ($ws, $message, $type) {
            ++$cycle_deliveries;
            if ($cycle_deliveries == $fanout) {
                $cycle_deliveries = 0;
                completed_broadcast();
            } elsif ($cycle_deliveries > $fanout) {
                die "subscriber delivery count exceeded fanout\n";
            }
        },

        on_error => sub ($connection, $error) {
            die "subscriber $id error: $error\n" if !$stopping;
        },
    );

    push @subscriber_client, $client;
    $client->connect(
        'ws://127.0.0.1:' . $server->port . '/subscriber'
    );
}

$loop->run;

die "benchmark never started\n" if !defined $started;
die "benchmark did not record elapsed time\n" if !defined $elapsed;

my $broadcast_rate = $broadcasts / $elapsed;
my $delivery_rate = $deliveries / $elapsed;
my $payload_mib =
    ($deliveries * $wire_bytes) / $elapsed / (1024 * 1024);

printf "fanout=%d target=%d wire=%d chars=%d broadcasts=%d deliveries=%d seconds=%.6f broadcast_rate=%.2f/s delivery_rate=%.0f/s payload=%.2f MiB/s\n",
    $fanout, $target_bytes, $wire_bytes, $characters,
    $broadcasts, $deliveries, $elapsed,
    $broadcast_rate, $delivery_rate, $payload_mib;
