# Linux::Event::WebSocket

High-performance WebSocket client and server for Linux::Event, with a simple
callback-first API.

## Status

Development version: `0.001_001`.

The distribution now has working `ws://` and `wss://` client/server paths and a
real production test suite. It has not yet been released to CPAN and the public
API is still allowed to change before the first release.

The GitHub Actions test matrix targets Perl 5.36 and Perl 5.44.0.

## What works today

- WebSocket client and server APIs.
- `ws://` and `wss://`.
- Text and binary messages.
- UTF-8 validation and decoding for text messages.
- Client masking and server unmasked output.
- Fragmented WebSocket messages with interleaved control frames.
- Automatic ping/pong control handling plus explicit `ping()`.
- Graceful WebSocket close handshake with a configurable close timeout.
- Hard transport abort when graceful close is not appropriate.
- Subprotocol negotiation.
- Access to the HTTP handshake request and response.
- Configurable message-size protection, defaulting to 16 MiB.
- Linux::Event Stream output buffering and backpressure.
- Linux::Event TLS transport retained across the HTTP-to-WebSocket transition.
- Same-read handoff: WebSocket bytes that arrive immediately after the HTTP
  Upgrade headers are preserved across the protocol transition.

## Server

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Server;

my $loop = Linux::Event::Loop->new;

my $server = Linux::Event::WebSocket::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,

    on_open => sub ($ws) {
        $ws->send_text('hello');
    },

    on_message => sub ($ws, $payload, $type) {
        if ($type eq 'text') {
            $ws->send_text("echo: $payload");
        }
    },

    on_close => sub ($ws, $code, $reason) {
        # Connection finished.
    },
);

$loop->run;
```

For `wss://`, pass the normal Linux::Event HTTP server `tls` policy containing
the certificate and key.

## Client

```perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::WebSocket::Client;

my $loop = Linux::Event::Loop->new;

my $client = Linux::Event::WebSocket::Client->new(
    loop => $loop,

    on_open => sub ($ws) {
        $ws->send_text('hello');
    },

    on_message => sub ($ws, $payload, $type) {
        say $payload if $type eq 'text';
    },

    on_close => sub ($ws, $code, $reason) {
        $loop->stop;
    },
);

$client->connect('wss://example.com/socket');
$loop->run;
```

## Connection API

Established client and server connections share the common
`Linux::Event::WebSocket::Connection` API. Important operations include:

```perl
$ws->send_text($text);
$ws->send_binary($bytes);
$ws->ping($bytes);
$ws->close(code => 'SUCCESS', reason => 'done');
$ws->abort;

$ws->is_open;
$ws->is_closing;
$ws->subprotocol;
$ws->secure;
$ws->url;
$ws->handshake_request;
$ws->handshake_response;
$ws->data;
```

`close()` starts the WebSocket close handshake. `abort()` closes the underlying
transport immediately.

## Architecture

Linux::Event::WebSocket deliberately composes the existing ecosystem instead of
reimplementing each layer:

```text
Linux::Event
    socket, TLS, ordered bytes, buffering, backpressure, lifecycle
        |
Linux::Event::HTTP
    HTTP/1.1 opening Upgrade and live-stream handoff
        |
Linux::Event::WebSocket
    WebSocket connection API, RFC 6455 framing, messages, masking,
    fragmentation, control semantics, and protocol policy
```

A successful HTTP Upgrade calls Linux::Event's in-place `transition_to()` on the
same live connection. The socket, TLS transport, queued output, application
state, and already-read post-HTTP bytes stay attached.

There is no second miniature HTTP parser in this distribution.

## Inheritance policy

Connection classes use ordinary single inheritance only:

```text
Linux::Event::WebSocket::Client::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

and separately:

```text
Linux::Event::WebSocket::Server::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

There are no Perl roles, mixins, multiple-inheritance trees, or method injection
in the connection design.

## Protocol engine

The RFC 6455 engine is implemented by private modules in this distribution.
It incrementally parses frames, enforces endpoint masking rules, reassembles
fragmented messages, validates UTF-8, and handles control and close frames.
Client handshake keys and frame masks come from `/dev/urandom`.

## Protocol policy

The wrapper enforces peer-side RFC 6455 rules that should not depend on a generic
transport-neutral parser, including:

- clients must mask frames sent to servers;
- servers must not mask frames sent to clients;
- RSV bits are rejected while no extensions are negotiated;
- control frames must be final and no larger than 125 bytes;
- close payload, status-code, and UTF-8 reason validation;
- frame/message size limits before accepting large advertised payloads.

## Native-code policy

The initial implementation intentionally has no WebSocket-specific XS.

If benchmarks later show that parsing or masking is a material bottleneck,
WebSocket-specific native code belongs in this distribution. Linux::Event core
should change only when a reusable facility would benefit multiple protocol
distributions. A WebSocket-specific built-in core framer is not currently
planned.

See `docs/ARCHITECTURE.md` for the detailed design and `handoff.md` for the
current development state and next work.
