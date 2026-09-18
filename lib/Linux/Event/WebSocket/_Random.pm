package Linux::Event::WebSocket::_Random;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Fcntl qw(O_RDONLY);

sub bytes ($class, $length) {
    croak 'bytes(): length must be a positive integer'
        if !defined($length) || ref($length)
        || "$length" !~ /\A[0-9]+\z/ || $length < 1;

    sysopen(my $fh, '/dev/urandom', O_RDONLY)
        or die "open /dev/urandom: $!";

    my $bytes = '';
    while (length($bytes) < $length) {
        my $read = sysread($fh, $bytes, $length - length($bytes), length($bytes));
        next if !defined($read) && $!{EINTR};
        die "read /dev/urandom: $!" if !defined $read;
        die "read /dev/urandom: unexpected EOF" if $read == 0;
    }

    close($fh) or die "close /dev/urandom: $!";
    return $bytes;
}

1;
