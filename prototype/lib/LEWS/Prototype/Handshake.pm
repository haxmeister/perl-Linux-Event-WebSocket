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

# Net::WebSocket intentionally owns the WebSocket-specific response semantics.
# For HTTP stacks that serialize their own response object, translate only the
# documented to_string() result rather than reaching into handshake internals.
sub apply_server_response ($class, $handshake, $response) {
    croak 'apply_server_response(): handshake object is required'
        if !defined($handshake) || !ref($handshake)
        || !$handshake->can('to_string');
    croak 'apply_server_response(): response object is required'
        if !defined($response) || !ref($response);

    for my $method (qw(status reason add_header)) {
        croak "apply_server_response(): response object needs $method()"
            if !$response->can($method);
    }

    my $wire = $handshake->to_string;
    my @line = split /\r\n/, $wire, -1;
    my $status_line = shift @line;

    my ($version, $status, $reason) =
        $status_line =~ /\AHTTP\/([0-9]+(?:\.[0-9]+)?) ([0-9]{3})(?: (.*))?\z/
        or croak 'apply_server_response(): invalid handshake status line';

    $response->status($status);
    $response->reason(defined($reason) ? $reason : '');

    for my $line (@line) {
        last if $line eq '';
        my ($name, $value) = $line =~ /\A([^:]+):[ \t]*(.*)\z/
            or croak 'apply_server_response(): invalid handshake header line';
        $response->add_header($name, $value);
    }

    return $response;
}

1;
