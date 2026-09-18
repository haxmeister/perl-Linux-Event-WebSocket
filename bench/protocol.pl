use v5.36;
use strict;
use warnings;

use Time::HiRes qw(time);

use Linux::Event::WebSocket::_Frame;
use Linux::Event::WebSocket::_Parser;
use Linux::Event::WebSocket::_UTF8;

my $seconds = $ENV{BENCH_SECONDS} // 0.6;
my @sizes = @ARGV ? @ARGV : (64, 1024, 16_384);
my $batch = 64;

sub measure ($name, $size, $code) {
    my $start = time;
    my $deadline = $start + $seconds;
    my $count = 0;

    while (1) {
        $code->() for 1 .. $batch;
        $count += $batch;
        last if time >= $deadline;
    }

    my $elapsed = time - $start;
    printf "%-26s %8d %12.0f ops/s\n",
        $name, $size, $count / $elapsed;
}

say "operation                       bytes        rate";

for my $size (@sizes) {
    die "size must be a positive integer\n"
        if $size !~ /\A[0-9]+\z/ || $size < 1;

    my $payload = 'x' x $size;
    my $fixed_mask = pack('N', 0x12345678);

    my $server_wire = Linux::Event::WebSocket::_Frame->encode(
        binary => $payload,
    );
    my $client_wire = Linux::Event::WebSocket::_Frame->encode(
        binary => $payload,
        masked => 1,
        mask_key => $fixed_mask,
    );

    my $server_parser = Linux::Event::WebSocket::_Parser->new(
        endpoint_type => 'server',
        max_frame_size => $size + 64,
    );
    my $client_parser = Linux::Event::WebSocket::_Parser->new(
        endpoint_type => 'client',
        max_frame_size => $size + 64,
    );

    measure('frame server encode', $size, sub {
        Linux::Event::WebSocket::_Frame->encode(binary => $payload);
    });

    measure('frame client fixed mask', $size, sub {
        Linux::Event::WebSocket::_Frame->encode(
            binary => $payload,
            masked => 1,
            mask_key => $fixed_mask,
        );
    });

    measure('frame client random mask', $size, sub {
        Linux::Event::WebSocket::_Frame->encode(
            binary => $payload,
            masked => 1,
        );
    });

    measure('mask payload', $size, sub {
        Linux::Event::WebSocket::_Frame->mask($payload, $fixed_mask);
    });

    measure('parse client frame', $size, sub {
        $server_parser->feed($client_wire);
        my $frame = $server_parser->next_frame;
        die "parser failed to return client frame\n" if !$frame;
    });

    measure('parse server frame', $size, sub {
        $client_parser->feed($server_wire);
        my $frame = $client_parser->next_frame;
        die "parser failed to return server frame\n" if !$frame;
    });

    measure('validate ASCII UTF-8', $size, sub {
        Linux::Event::WebSocket::_UTF8->validate_bytes($payload);
    });
}
