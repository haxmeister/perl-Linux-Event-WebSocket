package Linux::Event::WebSocket::_UTF8;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use utf8 ();

sub _continuation ($byte) {
    return $byte >= 0x80 && $byte <= 0xbf;
}

sub validate_bytes ($class, $bytes) {
    croak 'UTF-8 input must be a defined scalar'
        if !defined($bytes) || ref($bytes);

    my $copy = "$bytes";
    croak 'UTF-8 input must contain bytes'
        if !utf8::downgrade($copy, 1);

    my $length = length $copy;
    my $at = 0;

    while ($at < $length) {
        my $first = vec($copy, $at, 8);

        if ($first <= 0x7f) {
            ++$at;
            next;
        }

        if ($first >= 0xc2 && $first <= 0xdf) {
            croak 'invalid RFC 3629 UTF-8'
                if $at + 1 >= $length
                || !_continuation(vec($copy, $at + 1, 8));
            $at += 2;
            next;
        }

        if ($first >= 0xe0 && $first <= 0xef) {
            croak 'invalid RFC 3629 UTF-8' if $at + 2 >= $length;
            my $second = vec($copy, $at + 1, 8);
            my $third = vec($copy, $at + 2, 8);

            my $second_ok =
                $first == 0xe0 ? ($second >= 0xa0 && $second <= 0xbf)
              : $first == 0xed ? ($second >= 0x80 && $second <= 0x9f)
              :                  _continuation($second);

            croak 'invalid RFC 3629 UTF-8'
                if !$second_ok || !_continuation($third);
            $at += 3;
            next;
        }

        if ($first >= 0xf0 && $first <= 0xf4) {
            croak 'invalid RFC 3629 UTF-8' if $at + 3 >= $length;
            my $second = vec($copy, $at + 1, 8);
            my $third = vec($copy, $at + 2, 8);
            my $fourth = vec($copy, $at + 3, 8);

            my $second_ok =
                $first == 0xf0 ? ($second >= 0x90 && $second <= 0xbf)
              : $first == 0xf4 ? ($second >= 0x80 && $second <= 0x8f)
              :                  _continuation($second);

            croak 'invalid RFC 3629 UTF-8'
                if !$second_ok
                || !_continuation($third)
                || !_continuation($fourth);
            $at += 4;
            next;
        }

        croak 'invalid RFC 3629 UTF-8';
    }

    return 1;
}

sub decode ($class, $bytes) {
    $class->validate_bytes($bytes);
    my $copy = "$bytes";
    utf8::decode($copy)
        or croak 'internal UTF-8 decode failure after RFC 3629 validation';
    return $copy;
}

sub encode ($class, $text) {
    croak 'UTF-8 text must be a defined scalar'
        if !defined($text) || ref($text);

    my $copy = "$text";
    if (!utf8::is_utf8($copy)) {
        $class->validate_bytes($copy);
        return $copy;
    }

    croak 'UTF-8 text contains a surrogate code point'
        if $copy =~ /[\x{d800}-\x{dfff}]/;
    croak 'UTF-8 text contains a code point above U+10FFFF'
        if $copy =~ /[^\x{0}-\x{10ffff}]/;

    utf8::encode($copy);
    return $copy;
}

1;
