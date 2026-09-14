package Linux::Event::WebSocket::_IO;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %option) {
    my $stream = delete $option{stream};
    my $max_read = delete $option{max_read};

    croak 'new(): stream is required' if !defined $stream;
    croak 'new(): stream must implement write()'
        if !ref($stream) || !$stream->can('write');
    croak 'new(): max_read must be a positive integer'
        if defined($max_read)
        && (ref($max_read) || "$max_read" !~ /\A[0-9]+\z/ || $max_read < 1);
    croak 'new(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    return bless {
        input    => '',
        eof      => 0,
        stream   => $stream,
        max_read => $max_read,
    }, $class;
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

sub read ($self, $length) {
    croak 'read(): length must be a positive integer'
        if !defined($length) || ref($length)
        || "$length" !~ /\A[0-9]+\z/ || $length < 1;

    if (defined($self->{max_read}) && $length > $self->{max_read}) {
        die "WebSocket frame payload exceeds configured limit ($length > $self->{max_read})";
    }

    if (length($self->{input}) >= $length) {
        return substr($self->{input}, 0, $length, '');
    }

    return '' if $self->{eof} && !length($self->{input});
    return undef;
}

sub write ($self, $bytes) {
    croak 'write(): bytes must be a defined scalar'
        if !defined($bytes) || ref($bytes);
    return $self->{stream}->write($bytes);
}

1;
