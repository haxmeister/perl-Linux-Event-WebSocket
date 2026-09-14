package Linux::Event::WebSocket::_Parser;
use v5.36;
use strict;
use warnings;

use parent 'Net::WebSocket::Parser';

use Carp qw(croak);
use Encode qw(decode FB_CROAK);

sub new ($class, $reader, %option) {
    my $endpoint_type = delete $option{endpoint_type};
    croak 'new(): endpoint_type must be client or server'
        if !defined($endpoint_type)
        || ($endpoint_type ne 'client' && $endpoint_type ne 'server');
    croak 'new(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    my $self = $class->SUPER::new($reader);
    $self->{_lews_endpoint_type} = $endpoint_type;
    return $self;
}

sub _valid_close_code ($code) {
    return 0 if $code < 1000 || $code >= 5000;
    return 0 if $code == 1004 || $code == 1005 || $code == 1006;
    return 0 if $code == 1015;
    return 1;
}

sub _validate_close_frame ($frame) {
    my $payload = $frame->get_payload;
    my $length = length $payload;
    die "WebSocket close frame has a one-byte payload\n" if $length == 1;
    return if !$length;

    my ($code, $reason) = unpack 'na*', $payload;
    die "WebSocket close frame contains invalid status code $code\n"
        if !_valid_close_code($code);

    if (length $reason) {
        my $check = $reason;
        my $ok = eval {
            decode('UTF-8', $check, FB_CROAK);
            1;
        };
        die "WebSocket close frame contains invalid UTF-8 reason\n" if !$ok;
    }
    return;
}

sub _validate_peer_frame ($self, $frame) {
    my $endpoint_type = $self->{_lews_endpoint_type};
    my $masked = length($frame->get_mask_bytes) ? 1 : 0;

    if ($endpoint_type eq 'server' && !$masked) {
        die "WebSocket client frame is not masked\n";
    }
    if ($endpoint_type eq 'client' && $masked) {
        die "WebSocket server frame is masked\n";
    }

    die "WebSocket frame uses reserved bits without a negotiated extension\n"
        if $frame->get_rsv;

    if ($frame->is_control) {
        # Parsed control-frame classes expose get_fin() as a constant, so use
        # their documented wire serialization to verify the actual received
        # FIN bit before Endpoint handles the control frame.
        my $wire = $frame->to_bytes;
        die "WebSocket control frame is fragmented\n"
            if !(ord(substr($wire, 0, 1)) & 0x80);

        my $payload_length = length $frame->get_payload;
        die "WebSocket control frame payload exceeds 125 bytes\n"
            if $payload_length > 125;

        _validate_close_frame($frame) if $frame->get_type eq 'close';
    }

    return;
}

sub get_next_frame ($self) {
    my $frame = $self->SUPER::get_next_frame;
    return $frame if !ref $frame;

    $self->_validate_peer_frame($frame);
    return $frame;
}

1;
