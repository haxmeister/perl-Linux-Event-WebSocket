package Linux::Event::WebSocket::_UTF8;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use utf8 ();

sub _byte_copy ($bytes) {
    croak 'UTF-8 input must be a defined scalar'
        if !defined($bytes) || ref($bytes);

    my $copy = "$bytes";
    croak 'UTF-8 input must contain bytes'
        if !utf8::downgrade($copy, 1);
    return $copy;
}

sub _decode_bytes ($bytes) {
    my $copy = _byte_copy($bytes);

    # Most WebSocket text in practice is JSON/protocol ASCII. Keep that path
    # entirely inside Perl's C regex engine instead of walking every byte in
    # Perl space.
    return $copy if $copy !~ /[\x80-\xff]/;

    my $decoded = $copy;
    croak 'invalid RFC 3629 UTF-8' if !utf8::decode($decoded);

    # Perl can represent code points outside Unicode scalar-value space.
    # RFC 3629 cannot, and surrogate code points are also forbidden.
    croak 'invalid RFC 3629 UTF-8'
        if $decoded =~ /[\x{d800}-\x{dfff}]|[^\x{0}-\x{10ffff}]/;

    return $decoded;
}

sub validate_bytes ($class, $bytes) {
    _decode_bytes($bytes);
    return 1;
}

sub decode ($class, $bytes) {
    return _decode_bytes($bytes);
}

sub encode ($class, $text) {
    croak 'UTF-8 text must be a defined scalar'
        if !defined($text) || ref($text);

    my $copy = "$text";
    if (!utf8::is_utf8($copy)) {
        $class->validate_bytes($copy);
        return $copy;
    }

    croak 'UTF-8 text contains a non-Unicode scalar value'
        if $copy =~ /[\x{d800}-\x{dfff}]|[^\x{0}-\x{10ffff}]/;

    utf8::encode($copy);
    return $copy;
}

1;
