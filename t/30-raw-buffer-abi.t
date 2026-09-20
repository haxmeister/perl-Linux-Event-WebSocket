use v5.36;
use strict;
use warnings;

use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Framer ();
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::_BQ ();
use Linux::Event::WebSocket::_Frame;

{
    package Linux::Event::WebSocket::_RawABITestConnection;
    use v5.36;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub _websocket_raw_endpoint_type ($self) { 'server' }
    sub _websocket_raw_max_message_size ($self) { 1024 * 1024 }

    sub _websocket_raw_event ($self, $opcode, $payload) {
        my $state = $self->data;
        push @{$state->{events}}, [ $opcode, $payload ];
        $self->loop->stop if @{$state->{events}} >= $state->{expected};
        return;
    }

    sub _websocket_raw_invalid_utf8 ($self) {
        push @{$self->data->{errors}}, 'invalid utf8';
        $self->loop->stop;
        return;
    }

    sub _websocket_raw_error ($self, $code, $name) {
        push @{$self->data->{errors}}, "$code:$name";
        $self->loop->stop;
        return;
    }
}

Linux::Event::Framer->declare_native_consumer(
    'Linux::Event::WebSocket::_RawABITestConnection',
    Linux::Event::WebSocket::_BQ->raw_consumer_definition,
);

socketpair(my $socket, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";

my $loop = Linux::Event::Loop->new;
my $state = {
    events   => [],
    errors   => [],
    expected => 2,
};

my $stream = Linux::Event::WebSocket::_RawABITestConnection->new(
    loop => $loop,
    fh   => $socket,
    data => $state,
);

my $text = Linux::Event::WebSocket::_Frame->encode(
    text => 'hello raw ABI',
    masked   => 1,
    mask_key => "\x01\x02\x03\x04",
);
my $binary = Linux::Event::WebSocket::_Frame->encode(
    binary => "\x00\x01\xff\x7f",
    masked   => 1,
    mask_key => "\x05\x06\x07\x08",
);

my $split = int(length($text) / 2);
syswrite($peer, substr($text, 0, $split))
    == $split or die "first syswrite: $!";

my $finish = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 0,
    on_timer => sub ($timer) {
        my $tail = substr($text, $split) . $binary;
        syswrite($peer, $tail) == length($tail)
            or die "second syswrite: $!";
        return;
    },
);

my $guard = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 2,
    on_timer => sub ($timer) {
        die "raw-buffer ABI test timed out\n";
    },
);

$loop->run;
$guard->cancel;
$finish->cancel;

is_deeply(
    $state->{errors},
    [],
    'raw native consumer reports no bq errors',
);
is_deeply(
    $state->{events},
    [
        [ 1, 'hello raw ABI' ],
        [ 2, "\x00\x01\xff\x7f" ],
    ],
    'raw native consumer delivers complete text and binary messages',
);

ok(
    !$stream->can('on_data'),
    'raw ABI fixture has no Perl on_data receive callback',
);

$stream->close if !$stream->is_closed;
close $peer;

done_testing;
