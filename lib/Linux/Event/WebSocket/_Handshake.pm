package Linux::Event::WebSocket::_Handshake;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

use Linux::Event::HTTP::Request;
use Net::WebSocket::Handshake::Client ();
use Net::WebSocket::Handshake::Server ();

sub _message_headers ($message) {
    my @headers;
    for my $index (0 .. $message->header_count - 1) {
        push @headers,
            $message->header_name($index),
            $message->header_value($index);
    }
    return @headers;
}

sub server_from_request ($class, $request, %option) {
    croak 'server_from_request(): request object is required'
        if !defined($request) || !ref($request);

    my $subprotocols = delete($option{subprotocols}) // [];
    croak 'server_from_request(): subprotocols must be an array reference'
        if ref($subprotocols) ne 'ARRAY';
    croak 'server_from_request(): unknown option(s): '
        . join(', ', sort keys %option)
        if %option;

    my $handshake = Net::WebSocket::Handshake::Server->new(
        subprotocols => [ @$subprotocols ],
    );

    $handshake->valid_method_or_die($request->method);
    $handshake->valid_protocol_or_die('HTTP/' . $request->version);
    $handshake->consume_headers(_message_headers($request));
    return $handshake;
}

sub apply_server_response ($class, $handshake, $response) {
    croak 'apply_server_response(): handshake object is required'
        if !defined($handshake) || !ref($handshake)
        || !$handshake->can('to_string');
    croak 'apply_server_response(): response object is required'
        if !defined($response) || !ref($response);

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

sub client_request ($class, $url, %option) {
    croak 'client_request(): URL must be a non-empty scalar'
        if !defined($url) || ref($url) || $url eq '';

    my $origin = delete $option{origin};
    croak 'client_request(): origin must be a scalar'
        if defined($origin) && ref($origin);

    my $subprotocols = delete($option{subprotocols}) // [];
    croak 'client_request(): subprotocols must be an array reference'
        if ref($subprotocols) ne 'ARRAY';

    my $headers = delete($option{headers}) // [];
    croak 'client_request(): headers must be an array reference'
        if ref($headers) ne 'ARRAY';

    my $host_header = delete $option{host_header};
    croak 'client_request(): host_header must be a scalar'
        if defined($host_header) && ref($host_header);

    croak 'client_request(): unknown option(s): '
        . join(', ', sort keys %option)
        if %option;

    my @extra;
    for my $pair (@$headers) {
        croak 'client_request(): each header must be a [name, value] pair'
            if ref($pair) ne 'ARRAY' || @$pair != 2;
        my ($name, $value) = @$pair;
        croak 'client_request(): header name and value must be scalars'
            if !defined($name) || ref($name) || !defined($value) || ref($value);
        push @extra, $name, $value;
    }

    my %handshake_option = (
        uri          => "$url",
        subprotocols => [ @$subprotocols ],
    );
    $handshake_option{origin} = "$origin" if defined $origin;

    my $handshake = Net::WebSocket::Handshake::Client->new(%handshake_option);
    my $wire = $handshake->to_string(headers => \@extra);
    my @line = split /\r\n/, $wire, -1;
    my $request_line = shift @line;

    my ($method, $target, $version) =
        $request_line =~ /\A([^ ]+) ([^ ]+) HTTP\/([0-9]+(?:\.[0-9]+)?)\z/
        or croak 'client_request(): invalid generated request line';

    my @http_headers;
    for my $line (@line) {
        last if $line eq '';
        my ($name, $value) = $line =~ /\A([^:]+):[ \t]*(.*)\z/
            or croak 'client_request(): invalid generated header line';
        $value = $host_header
            if defined($host_header) && lc($name) eq 'host';
        push @http_headers, [ $name, $value ];
    }

    my $request = Linux::Event::HTTP::Request->new(
        method  => $method,
        target  => $target,
        version => $version,
        headers => \@http_headers,
    );

    return ($handshake, $request);
}

sub validate_client_response ($class, $handshake, $response) {
    croak 'validate_client_response(): handshake object is required'
        if !defined($handshake) || !ref($handshake);
    croak 'validate_client_response(): response object is required'
        if !defined($response) || !ref($response);

    $handshake->valid_status_or_die(
        $response->status,
        defined($response->reason) ? $response->reason : '',
    );
    $handshake->consume_headers(_message_headers($response));
    return $handshake;
}

sub subprotocol ($class, $handshake) {
    return $handshake->get_subprotocol;
}

1;
