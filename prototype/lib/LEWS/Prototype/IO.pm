package LEWS::Prototype::IO;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %option) {
    my $stream = delete $option{stream};
    croak 'new(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    return bless {
        input  => '',
        eof    => 0,
        stream => $stream,
    }, $class;
}

sub stream ($self, @value) {
    croak 'stream() accepts at most one value' if @value > 1;
    $self->{stream} = $value[0] if @value;
    return $self->{stream};
}

sub feed ($self, $bytes) {
    croak 'feed(): cannot add bytes after EOF' if $self->{eof};
    croak 'feed(): bytes must be a defined scalar'
        if !defined($bytes) || ref($bytes);
    $self->{input} .= $bytes;
    return $self;
}

sub finish ($self) {
    $self->{eof} = 1;
    return $self;
}

sub buffered_bytes ($self) {
    return length $self->{input};
}

# Net::WebSocket::Parser documents IO::Framed::Read-compatible semantics:
# return exactly the requested bytes when available, undef while the read is
# incomplete, and an empty string at EOF when no more bytes remain.
sub read ($self, $length) {
    croak 'read(): length must be a positive integer'
        if !defined($length) || ref($length)
        || $length !~ /\A[0-9]+\z/ || $length < 1;

    if (length($self->{input}) >= $length) {
        return substr($self->{input}, 0, $length, '');
    }

    return '' if $self->{eof} && !length($self->{input});
    return undef;
}

# Net::WebSocket::Endpoint only requires an output object with write().
# Linux::Event::IO::Sock::Stream already owns ordered nonblocking output,
# queueing, limits, and backpressure, so no second write queue belongs here.
sub write ($self, $bytes) {
    croak 'write(): bytes must be a defined scalar'
        if !defined($bytes) || ref($bytes);

    my $stream = $self->{stream}
        or croak 'write(): no stream is attached';
    croak 'write(): attached stream needs write()'
        if !$stream->can('write');

    return $stream->write($bytes);
}

1;
