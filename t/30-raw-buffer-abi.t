use v5.36;
use strict;
use warnings;

use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Framer ();
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::WebSocket::_BQ ();
use Linux::Event::WebSocket::_Engine ();
use Linux::Event::WebSocket::_Frame;
use Scalar::Util qw(refaddr);

{
    package Linux::Event::WebSocket::_RawABITestConnection;
    use v5.36;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub _websocket_raw_config ($self) {
        return [ 'server', 1024 * 1024 ];
    }

    sub _websocket_raw_native_ready ($self, $native) {
        my $state = $self->data;
        $state->{provider_native} = $native;
        $self->{raw_engine} = Linux::Event::WebSocket::_Engine->new(
            connection       => $self,
            endpoint_type    => 'server',
            max_message_size => 1024 * 1024,
            native           => $native,
            message_handler  => sub ($connection, $payload, $type) {
                push @{$state->{events}}, [ $type, $payload ];
                $connection->loop->stop
                    if @{$state->{events}} >= $state->{expected};
            },
        );
        $state->{engine_native} = $self->{raw_engine}{native};
        return;
    }

    sub _websocket_raw_event ($self, $opcode, $payload) {
        my $engine = $self->{raw_engine}
            or die "raw WebSocket engine was not attached\n";
        local $engine->{in_feed} = 1;
        $engine->_bq_event($self, $opcode, $payload);
        return;
    }

    sub _websocket_raw_invalid_utf8 ($self) {
        my $engine = $self->{raw_engine}
            or die "raw WebSocket engine was not attached\n";
        local $engine->{in_feed} = 1;
        $engine->_bq_invalid_utf8($self);
        return;
    }

    sub _websocket_raw_error ($self, $code, $name) {
        push @{$self->data->{errors}}, "$code:$name";
        $self->loop->stop;
        return;
    }

    sub _websocket_raw_complete ($self) {
        my $engine = $self->{raw_engine}
            or die "raw WebSocket engine was not attached\n";
        $engine->_finish_feed($self);
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
        [ text   => 'hello raw ABI' ],
        [ binary => "\x00\x01\xff\x7f" ],
    ],
    'raw native consumer enters the normal Engine message path',
);

is(
    refaddr($state->{provider_native}),
    refaddr($state->{engine_native}),
    'raw consumer and Engine share one bq native state object',
);

ok(
    !$stream->can('on_data'),
    'raw ABI fixture has no Perl on_data receive callback',
);

$stream->close if !$stream->is_closed;
close $peer;

done_testing;
