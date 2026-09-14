use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::WebSocket::_IO;
use Linux::Event::WebSocket::_Parser;
use Net::WebSocket::Frame::text;
use Net::WebSocket::Frame::ping;

{
    package T::Writer;
    sub new ($class) { bless { output => '' }, $class }
    sub write ($self, $bytes) {
        $self->{output} .= $bytes;
        return length $bytes;
    }
}

sub parser_for ($endpoint_type, $wire, %io_option) {
    my $io = Linux::Event::WebSocket::_IO->new(
        stream => T::Writer->new,
        %io_option,
    );
    $io->feed($wire);
    return Linux::Event::WebSocket::_Parser->new(
        $io,
        endpoint_type => $endpoint_type,
    );
}

sub dies_like ($code, $pattern, $name) {
    my $ok = eval { $code->(); 1 };
    my $error = $@;
    ok(!$ok, $name);
    like($error, $pattern, "$name reports expected error");
}

my $client_payload = 'hello';
my $server_payload = 'hello';
my $rsv_payload = 'hello';
my $ping_payload = 'x';

my $client_text = Net::WebSocket::Frame::text->new(
    mask    => "\x01\x02\x03\x04",
    payload => $client_payload,
);
my $server_text = Net::WebSocket::Frame::text->new(
    payload => $server_payload,
);

is(
    parser_for('server', $client_text->to_bytes)->get_next_frame->get_payload,
    'hello',
    'server parser accepts masked client frame',
);
is(
    parser_for('client', $server_text->to_bytes)->get_next_frame->get_payload,
    'hello',
    'client parser accepts unmasked server frame',
);

dies_like(
    sub { parser_for('server', $server_text->to_bytes)->get_next_frame },
    qr/client frame is not masked/,
    'server rejects unmasked client frame',
);
dies_like(
    sub { parser_for('client', $client_text->to_bytes)->get_next_frame },
    qr/server frame is masked/,
    'client rejects masked server frame',
);

my $rsv = Net::WebSocket::Frame::text->new(
    mask    => "\x01\x02\x03\x04",
    rsv     => 1,
    payload => $rsv_payload,
);
dies_like(
    sub { parser_for('server', $rsv->to_bytes)->get_next_frame },
    qr/reserved bits/,
    'RSV bits are rejected without extensions',
);

my $ping = Net::WebSocket::Frame::ping->new(
    mask    => "\x01\x02\x03\x04",
    payload => $ping_payload,
);
my $fragmented_ping = $ping->to_bytes;
substr($fragmented_ping, 0, 1) = chr(ord(substr($fragmented_ping, 0, 1)) & 0x7f);
dies_like(
    sub { parser_for('server', $fragmented_ping)->get_next_frame },
    qr/control frame is fragmented/,
    'fragmented control frame is rejected',
);

my $long_control = chr(0x89)
    . chr(0x80 | 126)
    . pack('n', 126)
    . ("\0" x 4)
    . ("\0" x 126);
dies_like(
    sub { parser_for('server', $long_control)->get_next_frame },
    qr/control frame payload exceeds 125 bytes/,
    'oversized control frame is rejected',
);

my $one_byte_close = chr(0x88)
    . chr(0x80 | 1)
    . ("\0" x 4)
    . "\0";
dies_like(
    sub { parser_for('server', $one_byte_close)->get_next_frame },
    qr/one-byte payload/,
    'one-byte close payload is rejected',
);

my $reserved_code_payload = pack('n', 1005);
my $reserved_code_close = chr(0x88)
    . chr(0x80 | length($reserved_code_payload))
    . ("\0" x 4)
    . $reserved_code_payload;
dies_like(
    sub { parser_for('server', $reserved_code_close)->get_next_frame },
    qr/invalid status code 1005/,
    'reserved close status is rejected',
);

my $bad_reason_payload = pack('n', 1000) . "\xff";
my $bad_reason_close = chr(0x88)
    . chr(0x80 | length($bad_reason_payload))
    . ("\0" x 4)
    . $bad_reason_payload;
dies_like(
    sub { parser_for('server', $bad_reason_close)->get_next_frame },
    qr/invalid UTF-8 reason/,
    'invalid close reason UTF-8 is rejected',
);

dies_like(
    sub {
        my $parser = parser_for(
            'server',
            chr(0x82) . chr(0x80 | 127) . pack('NN', 0, 1024),
            max_read => 256,
        );
        $parser->get_next_frame;
    },
    qr/exceeds configured limit/,
    'frame reader rejects advertised payload above configured limit',
);

done_testing;
