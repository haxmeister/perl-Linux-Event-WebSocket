use v5.36;
use strict;
use warnings;

use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;

my $base = $ENV{AUTOBAHN_URL} // 'ws://127.0.0.1:9001';
my $agent = 'LinuxEventWebSocket';

my $loop = Linux::Event::Loop->new;
my $phase = 'count';
my $case_count;
my $case_number = 0;
my $current_client;
my $failed;

my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 180,
    on_timer => sub ($timer) {
        $failed = 'Autobahn client test timed out';
        $loop->stop;
    },
);

sub schedule_next;

sub finish_failure ($message) {
    return if $failed;
    $failed = $message;
    $guard->cancel;
    $loop->stop;
    return;
}

sub connection_url () {
    return "$base/getCaseCount" if $phase eq 'count';
    return "$base/updateReports?agent=$agent" if $phase eq 'report';
    return "$base/runCase?case=$case_number&agent=$agent";
}

sub advance () {
    if ($phase eq 'count') {
        return finish_failure('Autobahn did not provide a valid case count')
            if !defined $case_count || $case_count < 1;
        $phase = 'case';
        $case_number = 1;
        say "Autobahn client cases: $case_count";
        schedule_next();
        return;
    }

    if ($phase eq 'case') {
        if ($case_number < $case_count) {
            ++$case_number;
            schedule_next();
            return;
        }

        $phase = 'report';
        schedule_next();
        return;
    }

    $guard->cancel;
    $loop->stop;
    return;
}

sub schedule_next () {
    Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 0,
        on_timer => sub ($timer) {
            my $advanced = 0;
            my $url = connection_url();

            $current_client = Linux::Event::WebSocket::Client->new(
                loop => $loop,

                on_message => sub ($ws, $payload, $type) {
                    if ($phase eq 'count') {
                        return finish_failure(
                            'Autobahn case count was not a decimal text message'
                        ) if $type ne 'text'
                            || $payload !~ /\A[0-9]+\z/;
                        $case_count = 0 + $payload;
                        return;
                    }

                    if ($phase eq 'case') {
                        if ($type eq 'text') {
                            $ws->send_text($payload);
                        } else {
                            $ws->send_binary($payload);
                        }
                    }
                    return;
                },

                on_close => sub ($ws, $code, $reason) {
                    return if $advanced++;
                    advance();
                    return;
                },

                on_error => sub ($connection, $error) {
                    if ($phase ne 'case') {
                        return finish_failure(
                            "Autobahn control connection failed: $error"
                        );
                    }

                    # Protocol-error cases intentionally make the client report
                    # an error before transport close. Autobahn judges the wire
                    # behavior; progression happens from on_close.
                    warn "Autobahn case $case_number client error: $error\n";
                    return;
                },
            );

            say "Running Autobahn client case $case_number/$case_count"
                if $phase eq 'case';

            my $ok = eval {
                $current_client->connect($url);
                1;
            };
            finish_failure("Autobahn client connect failed: $@") if !$ok;
            return;
        },
    );
    return;
}

schedule_next();
$loop->run;

die "$failed\n" if $failed;
say "Autobahn client run completed.";
