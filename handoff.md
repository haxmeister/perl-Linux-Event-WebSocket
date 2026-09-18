# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`, branch `main`.

Development version: `0.001_001`. No CPAN release has been made.

Do not modify Linux::Event core, Linux::Event::HTTP, Uniform::HTTP, or another
repository unless the user explicitly authorizes it.

## Current implementation

The distribution contains its own private RFC 6455 implementation and has no
external WebSocket protocol-engine dependency.

Public coordinators and connections:

```text
Linux::Event::WebSocket::Server
Linux::Event::WebSocket::Client
Linux::Event::WebSocket::Connection
Linux::Event::WebSocket::Client::Connection
Linux::Event::WebSocket::Server::Connection
```

Private protocol modules:

```text
Linux::Event::WebSocket::_Random
Linux::Event::WebSocket::_Handshake
Linux::Event::WebSocket::_Frame
Linux::Event::WebSocket::_Parser
Linux::Event::WebSocket::_Engine
Linux::Event::WebSocket::_State
```

The implementation supports `ws://` and `wss://`, text and binary messages,
fragmentation with interleaved control frames, UTF-8 validation, client masking,
automatic pong, graceful close with timeout, hard abort, subprotocols,
message-size limits, and access to HTTP handshake objects.

Linux::Event owns transport and TLS. Linux::Event::HTTP owns the opening HTTP/1.1
exchange. The same Stream is transitioned in place, preserving object identity,
queued output, TLS state, application state, and post-header bytes.

## Public behavior

Common methods:

```text
send_text  send_binary  ping  close  abort
is_open    is_closing   subprotocol  secure  url
handshake_request  handshake_response  data
```

Callbacks:

```text
on_open  on_message  on_close  on_error  on_drain
```

The server also accepts `on_handshake`.

The connection design uses ordinary single inheritance only. Do not introduce
roles, mixins, multiple inheritance, or method injection.

## Tests

The test suite includes:

```text
t/00-load.t
t/01-handshake.t
t/02-frame-parser.t
t/03-engine.t
t/10-client-server.t
t/11-message-types.t
t/12-upgrade-tail.t
t/13-core-close-boundary.t
t/14-close-lifecycle.t
t/20-tls-client-server.t
```

Coverage includes deterministic RFC handshake vectors, incremental parsing,
masking and length policy, fragmentation, control frames, close errors, size
limits, production HTTP handoff, same-read Upgrade tails, object identity,
subprotocols, TLS, the Linux::Event protocol-subclass close boundary, abrupt
transport loss, simultaneous close, and peer loss during local close.

CI targets Perl 5.36 and Perl 5.44.

## Resolved core close boundary

The inherited Stream `close()` collision has been resolved in Linux::Event
0.115. Core involuntary teardown now bypasses protocol-subclass public
`close()` semantics, while explicit semantic close requests remain virtual.

This distribution now requires Linux::Event 0.115 or newer.
`t/13-core-close-boundary.t` verifies the WebSocket side of that contract.

## Remaining release work

1. Test against an independent peer and the Autobahn WebSocket test suite.
2. Benchmark only after correctness and the API are stable; add native code only
   for a measured bottleneck.
3. Perform a release-readiness review before the first CPAN upload.

## Files to read first

```text
docs/ARCHITECTURE.md
lib/Linux/Event/WebSocket/Connection.pm
lib/Linux/Event/WebSocket/_Handshake.pm
lib/Linux/Event/WebSocket/_Parser.pm
lib/Linux/Event/WebSocket/_Engine.pm
t/10-client-server.t
t/12-upgrade-tail.t
t/13-core-close-boundary.t
t/14-close-lifecycle.t
t/20-tls-client-server.t
```
