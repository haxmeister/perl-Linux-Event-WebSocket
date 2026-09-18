use v5.36;
use strict;
use warnings;

use Fcntl qw(O_RDONLY);
use Time::HiRes qw(time);

use Linux::Event::WebSocket::_Frame;
use Linux::Event::WebSocket::_Random;
use Linux::Event::WebSocket::_UTF8;

my $seconds = $ENV{BENCH_SECONDS} // 0.6;
my $batch = 64;

my $RFC3629 = qr{
    \A(?:
        [\x00-\x7f]
      | [\xc2-\xdf][\x80-\xbf]
      | \xe0[\xa0-\xbf][\x80-\xbf]
      | [\xe1-\xec\xee-\xef][\x80-\xbf]{2}
      | \xed[\x80-\x9f][\x80-\xbf]
      | \xf0[\x90-\xbf][\x80-\xbf]{2}
      | [\xf1-\xf3][\x80-\xbf]{3}
      | \xf4[\x80-\x8f][\x80-\xbf]{2}
    )*\z
}x;

sysopen(my $random_fh, '/dev/urandom', O_RDONLY)
    or die "open /dev/urandom: $!";

sub persistent_random ($length) {
    my $bytes = '';
    while (length($bytes) < $length) {
        my $read = sysread(
            $random_fh,
            $bytes,
            $length - length($bytes),
            length($bytes),
        );
        next if !defined($read) && $!{EINTR};
        die "read /dev/urandom: $!" if !defined $read;
        die "read /dev/urandom: unexpected EOF" if !$read;
    }
    return $bytes;
}

sub regex_validate ($bytes) {
    return $bytes =~ $RFC3629 ? 1 : 0;
}

sub decode_validate ($bytes) {
    my $copy = "$bytes";
    return 0 if !utf8::downgrade($copy, 1);
    return 0 if !utf8::decode($copy);
    return 0 if $copy =~ /[\x{d800}-\x{dfff}]|[^\x{0}-\x{10ffff}]/;
    return 1;
}

sub ascii_fast_validate ($bytes) {
    return 1 if $bytes !~ /[\x80-\xff]/;
    return eval {
        Linux::Event::WebSocket::_UTF8->validate_bytes($bytes);
        1;
    } ? 1 : 0;
}

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
    printf "%-31s %8d %12.0f ops/s\n",
        $name, $size, $count / $elapsed;
}

my %valid = (
    ascii       => pack('H*', '41'),
    two_byte    => pack('H*', 'c280'),
    three_byte  => pack('H*', 'e0a080'),
    nonchar     => pack('H*', 'efbfbf'),
    four_byte   => pack('H*', 'f0908080'),
    max_scalar  => pack('H*', 'f48fbfbf'),
);
my %invalid = (
    lone_continuation => pack('H*', '80'),
    overlong_nul      => pack('H*', 'c080'),
    overlong_three    => pack('H*', 'e08080'),
    surrogate         => pack('H*', 'eda080'),
    overlong_four     => pack('H*', 'f0808080'),
    above_unicode     => pack('H*', 'f4908080'),
    truncated         => pack('H*', 'f09080'),
);

for my $name (sort keys %valid) {
    die "regex validator rejected valid vector $name\n"
        if !regex_validate($valid{$name});
    die "decode validator rejected valid vector $name\n"
        if !decode_validate($valid{$name});
    die "ASCII-fast validator rejected valid vector $name\n"
        if !ascii_fast_validate($valid{$name});
}
for my $name (sort keys %invalid) {
    die "regex validator accepted invalid vector $name\n"
        if regex_validate($invalid{$name});
    die "decode validator accepted invalid vector $name\n"
        if decode_validate($invalid{$name});
    die "ASCII-fast validator accepted invalid vector $name\n"
        if ascii_fast_validate($invalid{$name});
}

say "operation                            bytes        rate";

for my $size (64, 1024, 16_384) {
    my $payload = 'x' x $size;

    measure('UTF8 current byte loop', $size, sub {
        Linux::Event::WebSocket::_UTF8->validate_bytes($payload);
    });

    measure('UTF8 RFC3629 regex', $size, sub {
        die "regex validation failure\n" if !regex_validate($payload);
    });

    measure('UTF8 utf8::decode candidate', $size, sub {
        die "decode validation failure\n" if !decode_validate($payload);
    });

    measure('UTF8 ASCII fast path', $size, sub {
        die "ASCII-fast validation failure\n" if !ascii_fast_validate($payload);
    });

    measure('random production persistent', 4, sub {
        Linux::Event::WebSocket::_Random->bytes(4);
    });

    measure('random benchmark persistent', 4, sub {
        Linux::Event::WebSocket::_Random->bytes(4);
    });

        persistent_random(4);
    });

    measure('frame production random mask', $size, sub {
        Linux::Event::WebSocket::_Frame->encode(
            binary => $payload,
            masked => 1,
        );
    });

    measure('frame benchmark persistent', $size, sub {
        my $mask = persistent_random(4);
        Linux::Event::WebSocket::_Frame->encode(
            binary => $payload,
            masked => 1,
            mask_key => $mask,
        );
    });
}
