package LEWS::Prototype::Handshake;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Net::WebSocket::Handshake::Server ();

sub server_from_request ($class, $request, %option) {
    croak 'server_from_request(): request object is required'
        if !defined $request || !ref $request;

    for my $method (qw(method version header_count header_name header_value)) {
        croak "server_from_request(): request object needs $method()"
            if !$request->can($method);
    }

    my %handshake_option;
    for my $name (qw(subprotocols extensions)) {
        $handshake_option{$name} = $option{$name}
            if exists $option{$name};
        delete $option{$name};
    }

    croak 'server_from_request(): unknown option(s): '
        . join(', ', sort keys %option)
        if %option;

    my $handshake = Net::WebSocket::Handshake::Server->new(
        %handshake_option,
    );

    $handshake->valid_method_or_die($request->method);

    my $version = $request->version;
    croak 'server_from_request(): request has no HTTP version'
        if !defined $version;
    $handshake->valid_protocol_or_die("HTTP/$version");

    my @headers;
    for my $index (0 .. $request->header_count - 1) {
        push @headers,
            $request->header_name($index),
            $request->header_value($index);
    }

    $handshake->consume_headers(@headers);
    return $handshake;
}

1;
