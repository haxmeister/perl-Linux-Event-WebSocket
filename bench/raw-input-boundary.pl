use v5.36;
use strict;
use warnings;

use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);
use utf8 ();

use Linux::Event::Framer ();
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Loop;
use Linux::Event::WebSocket::_BQ ();
use Linux::Event::WebSocket::_Engine ();
use Linux::Event::WebSocket::_Frame;

{
    package Linux::Event::WebSocket::Bench::PerlInput;
    use v5.36;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($self, $bytes) {
        $self->{bench_engine}->feed($bytes);
        return;
    }
}

{
    package Linux::Event::WebSocket::Bench::RawInput;
    use v5.36;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub _websocket_raw_config ($self) {
        my $state = $self->data;
        return [ 'server', $state->{max_message_size} ];
    }

    sub _websocket_raw_native_ready ($self, $native) {
        my $state = $self->data;
        $self->{bench_engine} = Linux::Event::WebSocket::_Engine->new(
            connection       => $self,
            endpoint_type    => 'server',
            max_message_size => $state->{max_message_size},
            native           => $native,
            message_handler  => $state->{message_handler},
        );
        return $self->{bench_engine};
    }
}

Linux::Event::Framer->declare_native_consumer(
    'Linux::Event::WebSocket::Bench::RawInput',
    Linux::Event::WebSocket::_BQ->raw_consumer_definition,
);

my $seconds = $ENV{BENCH_SECONDS} // 0.75;
my @sizes = @ARGV ? @ARGV : (64, 1024, 16_384);

die "BENCH_SECONDS must be positive\n"
    if $seconds !~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/
    || $seconds <= 0;

sub text_payload ($size) {
    my $prefix = '{"m":"';
    my $suffix = '"}';
    my $emoji = "\N{U+1F680}";
    utf8::encode($emoji);

    my $minimum = length($prefix) + length($emoji) + length($suffix);
    die "text benchmark size $size is too small (minimum $minimum)\n"
        if $size < $minimum;

    return $prefix
        . ('x' x ($size - $minimum))
        . $emoji
        . $suffix;
}

sub binary_payload ($size) {
    my $unit = pack('C*', 0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff, 0x55, 0xaa);
    my $payload = $unit x (int($size / length($unit)) + 1);
    return substr($payload, 0, $size);
}

sub wire_chunk ($type, $payload) {
    my $sample = Linux::Event::WebSocket::_Frame->encode(
        $type => $payload,
        masked   => 1,
        mask_key => pack('N', 1),
    );
    my $frames = int(65_536 / length($sample));
    $frames = 1 if $frames < 1;

    my @wire;
    for my $index (1 .. $frames) {
        push @wire, Linux::Event::WebSocket::_Frame->encode(
            $type => $payload,
            masked   => 1,
            mask_key => pack('N', 0x1020_3040 + $index),
        );
    }

    return (join('', @wire), $frames);
}

sub run_case ($mode, $type, $payload, $duration) {
    socketpair(my $read_fh, my $write_fh, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";

    my $loop = Linux::Event::Loop->new;
    my ($chunk, $frames_per_chunk) = wire_chunk($type, $payload);
    my $warmup = int(1_048_576 / length($payload));
    $warmup = 128 if $warmup < 128;
    $warmup = 10_000 if $warmup > 10_000;

    my $state = {
        max_message_size => length($payload) + 1024,
        messages         => 0,
        measured         => 0,
        measuring        => 0,
        warmup           => $warmup,
        start            => undef,
        deadline         => undef,
        chunk            => $chunk,
    };

    my $handler = sub ($connection, $message, $message_type) {
        ++$state->{messages};

        if (!$state->{measuring}) {
            if ($state->{messages} >= $state->{warmup}) {
                $state->{measuring} = 1;
                $state->{start} = time;
                $state->{deadline} = $state->{start} + $duration;
            }
        } else {
            ++$state->{measured};
            if (($state->{measured} & 31) == 0
                && time >= $state->{deadline}) {
                $loop->stop;
                return;
            }
        }

        return;
    };
    $state->{message_handler} = $handler;

    my $reader_class = $mode eq 'raw'
        ? 'Linux::Event::WebSocket::Bench::RawInput'
        : 'Linux::Event::WebSocket::Bench::PerlInput';

    my $reader = $reader_class->new(
        loop => $loop,
        fh   => $read_fh,
        data => $state,
    );

    if ($mode eq 'perl') {
        $reader->{bench_engine} = Linux::Event::WebSocket::_Engine->new(
            connection       => $reader,
            endpoint_type    => 'server',
            max_message_size => $state->{max_message_size},
            message_handler  => $handler,
        );
    }

    $write_fh->blocking(0);
    my $write_offset = 0;
    my $writer = $loop->watch_fd(
        fileno($write_fh),
        fh => $write_fh,
        write => sub ($watcher) {
            while (1) {
                my $remaining = length($chunk) - $write_offset;
                my $written = syswrite(
                    $write_fh,
                    $chunk,
                    $remaining,
                    $write_offset,
                );

                if (!defined $written) {
                    next if $! == EINTR;
                    return if $! == EAGAIN || $! == EWOULDBLOCK;
                    die "benchmark syswrite failed: $!\n";
                }

                return if $written == 0;
                $write_offset += $written;
                $write_offset = 0
                    if $write_offset == length($chunk);
            }
        },
    );

    $loop->run;

    my $elapsed = time - $state->{start};
    my $rate = $state->{measured} / $elapsed;
    my $mib = $rate * length($payload) / (1024 * 1024);

    $writer->cancel;
    $reader->close if !$reader->is_closed;
    close $write_fh;

    return ($rate, $mib);
}

printf "%-8s %-7s %8s %14s %12s\n",
    'path', 'type', 'bytes', 'messages/s', 'MiB/s';

for my $size (@sizes) {
    die "size must be a positive integer\n"
        if $size !~ /\A[0-9]+\z/ || $size < 1;

    for my $type (qw(text binary)) {
        my $payload = $type eq 'text'
            ? text_payload($size)
            : binary_payload($size);

        for my $mode (qw(perl raw)) {
            my ($rate, $mib) = run_case(
                $mode, $type, $payload, $seconds,
            );
            printf "%-8s %-7s %8d %14.0f %12.2f\n",
                $mode, $type, $size, $rate, $mib;
        }
    }
}
