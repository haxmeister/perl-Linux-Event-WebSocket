package Linux::Event::WebSocket;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001_001';

1;

__END__

=head1 NAME

Linux::Event::WebSocket - WebSocket client and server for Linux::Event

=head1 SYNOPSIS

    use Linux::Event::WebSocket::Server;
    use Linux::Event::WebSocket::Client;

=head1 DESCRIPTION

C<Linux::Event::WebSocket> provides callback-first WebSocket client and server
support on top of Linux::Event.

Linux::Event owns the live socket, TLS transport, ordered byte buffering,
backpressure, and protocol transition. Linux::Event::HTTP owns the opening
HTTP/1.1 Upgrade exchange. Private modules in this distribution own RFC 6455
handshake validation, framing, masking, fragmentation, and control semantics.

The WebSocket protocol engine is intentionally kept behind private classes so
it can evolve without changing the public Linux::Event API.

=head1 STATUS

This is an early development version. Public API details are not yet frozen.

=cut
