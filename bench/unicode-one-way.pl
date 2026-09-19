use v5.36;
use strict;
use warnings;

use Encode qw(encode);
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;
use Linux::Event::WebSocket::Server;

my $direction = 'c2s';
my $clients = 1;
my $target_bytes = 1024;
my $seconds = 2.0;
my $warmup = 0.5;
my $window = 32;
my $profile = 'json-mixed';

GetOptions(
    'direction=s' => \$direction,
    'clients=i'   => \$clients,
    'bytes=i'     => \$target_bytes,
    'seconds=f'   => \$seconds,
    'warmup=f'    => \$warmup,
    'window=i'    => \$window,
    'profile=s'   => \$profile,
) or die "invalid benchmark option\n";

die "--direction must be c2s or s2c\n"
    if $direction ne 'c2s' && $direction ne 's2c';
die "--clients must be positive\n" if $clients < 1;
die "--bytes must be positive\n" if $target_bytes < 1;
die "--seconds must be positive\n" if $seconds <= 0;
die "--warmup must be non-negative\n" if $warmup < 0;
die "--window must be positive\n" if $window < 1;

my %unit = (
    ascii =>
        'type=message user=alice room=general text=hello status=ok ',

    'json-mixed' =>
        '{"type":"message","user":"alice","room":"general","text":"Hello '
        . chr(0x1f642)
        . ' from Perl","ok":true}',

    european =>
        'Cafe' . chr(0x00e9)
        . ' deja' . chr(0x00e0)
        . ' vu - Gru' . chr(0x00fc) . 'sse '
        . 'na' . chr(0x00ef) . 've facade' . chr(0x00e7) . 'ade '
        . chr(0x20ac) . ' ',

    cjk =>
        chr(0x4f60) . chr(0x597d)
        . chr(0x4e16) . chr(0x754c)
        . chr(0x4eca) . chr(0x5929)
        . chr(0x6211) . chr(0x4eec)
        . chr(0x6d4b) . chr(0x8bd5)
        . chr(0x6587) . chr(0x672c),

    emoji =>
        chr(0x1f642) . chr(0x1f680)
        . chr(0x1f4ac) . chr(0x1f525)
        . chr(0x2705) . chr(0x1f389)
        . chr(0x1f4a1) . chr(0x1f44d),
);

die "unknown profile '$profile'\n" if !exists $unit{$profile};

sub utf8_bytes ($text) {
    return length encode('UTF-8', $text);
}

sub make_payload ($name, $target) {
    my @character = split //, $unit{$name};
    die "empty profile unit\n" if !@character;

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

    # These profiles naturally contain ASCII, so using ASCII for the last
    # byte or two preserves their intended character mix while making the
    # requested wire size exact. Dense CJK/emoji profiles remain dense.
    if ($name eq 'ascii' || $name eq 'json-mixed' || $name eq 'european') {
        $payload .= 'x' x ($target - $used) if $used < $target;
    }

    return $payload;
}

my $payload = make_payload($profile, $target_bytes);
my $wire_bytes = utf8_bytes($payload);
my $characters = length $payload;

my $loop = Linux::Event::Loop->new;
my @client_ws;
my @server_ws;
my @client;
my $client_open = 0;
my $server_open = 0;
my $next_sender = 0;
my $messages = 0;
my $warmup_deadline;
my $started;
my $deadline;
my $elapsed;
my $stopping = 0;
my $started_traffic = 0;
my $guard;
my $server;

sub send_one ($ws) {
    $ws->send_text($payload);
    return;
}

sub sender_list () {
    return $direction eq 'c2s' ? \@client_ws : \@server_ws;
}

sub replenish () {
    return if $stopping;
    my $senders = sender_list();
    return if !@$senders;
    my $ws = $senders->[$next_sender++ % @$senders];
    send_one($ws);
    return;
}

sub stop_measurement ($now) {
    return if $stopping++;
    $elapsed = $now - $started;
    $_->abort for @client_ws;
    $server->close;
    $guard->cancel;
    $loop->stop;
    return;
}

sub received_one () {
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

    replenish();
    return;
}

sub maybe_start_traffic () {
    return if $started_traffic;
    return if $client_open != $clients || $server_open != $clients;

    $started_traffic = 1;
    $warmup_deadline = time + $warmup;
    my $senders = sender_list();
    for my $ws (@$senders) {
        send_one($ws) for 1 .. $window;
    }
    return;
}

$server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,

    on_open => sub ($ws) {
        push @server_ws, $ws;
        ++$server_open;
        maybe_start_traffic();
    },

    on_message => sub ($ws, $message, $message_type) {
        received_one() if $direction eq 'c2s';
    },

    on_error => sub ($connection, $error) {
        die "server error: $error\n" if !$stopping;
    },
);

$guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => $warmup + $seconds + 10,
    on_timer => sub ($timer) {
        die "Unicode one-way benchmark timed out\n";
    },
);

for my $id (1 .. $clients) {
    my $client = Linux::Event::WebSocket::Client->new(
        loop => $loop,

        on_open => sub ($ws) {
            push @client_ws, $ws;
            ++$client_open;
            maybe_start_traffic();
        },

        on_message => sub ($ws, $message, $message_type) {
            received_one() if $direction eq 's2c';
        },

        on_error => sub ($connection, $error) {
            die "client $id error: $error\n" if !$stopping;
        },
    );

    push @client, $client;
    $client->connect('ws://127.0.0.1:' . $server->port . '/unicode-one-way');
}

$loop->run;

die "benchmark never started\n" if !defined $started;
die "benchmark did not record elapsed time\n" if !defined $elapsed;

my $rate = $messages / $elapsed;
my $payload_mib = ($messages * $wire_bytes) / $elapsed / (1024 * 1024);

printf "direction=%s profile=%s target=%d wire=%d chars=%d clients=%d window=%d messages=%d seconds=%.6f rate=%.0f msg/s payload=%.2f MiB/s\n",
    $direction, $profile, $target_bytes, $wire_bytes, $characters,
    $clients, $window, $messages, $elapsed, $rate, $payload_mib;
