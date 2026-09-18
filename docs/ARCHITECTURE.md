# Linux::Event::WebSocket Architecture

This document describes the development architecture. The distribution has not
yet had its first CPAN release, so public API details may still change.

## Layer ownership

`Linux::Event` owns sockets, TLS, ordered byte delivery, write buffering,
backpressure, lifecycle, timers, and in-place `transition_to()` operations.

`Linux::Event::HTTP` owns the opening HTTP/1.1 request/response exchange and
preserves bytes read after the Upgrade headers during the protocol transition.

`Linux::Event::WebSocket` owns the public connection API and its private RFC 6455
implementation: handshake validation, framing, masking, fragmentation, message
assembly, UTF-8 policy, control frames, and graceful close behavior.

HTTP and WebSocket remain distinct protocol layers. This distribution does not
contain a second HTTP parser, and Linux::Event core does not contain
WebSocket-specific framing.

## Connection model

An established WebSocket connection is the same live Linux::Event Stream that
performed the HTTP Upgrade. It is transitioned in place, rather than wrapped or
replaced. Socket identity, TLS state, queued output, application data, and
already-read bytes remain attached.

The class chains use ordinary single inheritance:

```text
Linux::Event::WebSocket::Client::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream

Linux::Event::WebSocket::Server::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

There are no roles, mixins, multiple-inheritance trees, or injected methods in
the connection design. Client versus server is called the `endpoint_type`.

The common public connection operations are:

```text
send_text  send_binary  ping  close  abort
is_open    is_closing   subprotocol  secure  url
handshake_request  handshake_response  data
```

`close()` starts the RFC 6455 close handshake. `abort()` closes the transport
immediately.

## HTTP Upgrade handoff

The high-level server composes `Linux::Event::HTTP::Server`. Accepted streams
start as a private HTTP connection and transition to the configured WebSocket
server connection class after a valid handshake.

The high-level client uses `Linux::Event::HTTP::Client::Connection` for the
opening exchange. WebSocket state is attached before the request is sent,
because post-101 bytes may be delivered to the transitioned class before the
public HTTP `on_upgrade` callback runs.

This ordering is essential for the same-read case: a peer may put its first
WebSocket frame in the same transport read as the final HTTP headers. Production
test `t/12-upgrade-tail.t` covers that boundary in both directions.

## Private RFC 6455 engine

The private implementation is split by responsibility:

```text
_Random     exact-length bytes from /dev/urandom
_Handshake  client request, server response, and Upgrade validation
_Frame      frame encoding, masking, opcodes, and close payloads
_Parser     incremental frame parsing and wire-policy validation
_Engine     message assembly, UTF-8, control frames, and close state
_State      connection/application state preserved across transition
```

The handshake implementation validates method, HTTP version, Upgrade and
Connection tokens, version 13, keys, accepts, extensions, and subprotocol
selection. Client keys are 16 random bytes encoded as base64.

The parser accepts arbitrarily split or coalesced input. It rejects non-minimal
lengths, invalid 64-bit lengths, reserved bits and opcodes, incorrect masking,
oversized frames, and malformed control frames before accepting their payloads.

The engine reassembles fragmented text and binary messages while allowing
interleaved control frames. Text and close reasons are validated as UTF-8.
Binary messages remain byte strings. Incoming pings receive an identical pong.

Client frames use a fresh four-byte mask from `/dev/urandom`. Server frames are
not masked. No extensions are currently negotiated.

## Size limits

The high-level client and server default `max_message_size` to 16 MiB. It bounds
an advertised data frame before its payload is accumulated and the combined
payload of a fragmented logical message. Valid control frames retain their RFC
6455 limit of 125 bytes even when the application message limit is smaller.

## Close behavior

Receiving a close frame validates its payload, echoes it when necessary,
dispatches `on_close`, and ends transport output. A locally initiated close
waits for the peer response, with a configurable timeout that falls back to a
hard abort.

Protocol violations produce the applicable close status when possible:

- 1002 for protocol errors;
- 1007 for invalid UTF-8 payloads;
- 1009 for configured size-limit violations.

## Stream close ownership

`Linux::Event::WebSocket::Connection` intentionally overrides the inherited
Stream `close()` name to mean the RFC 6455 graceful close handshake. Immediate
transport termination remains `abort()`.

Linux::Event 0.115 establishes the complementary core invariant: involuntary
Stream teardown uses private terminal-close machinery instead of dynamically
dispatching through a protocol subclass's public `close()`. This lets a
protocol subclass give `close()` protocol-level semantics without risking a
transport failure accidentally starting a graceful protocol shutdown.

This distribution therefore requires Linux::Event 0.115 or newer. Regression
test `t/13-core-close-boundary.t` verifies that forced Stream cleanup of a
WebSocket subclass bypasses its public `close()`, does not initialize the
WebSocket engine, and still closes the underlying descriptor.

## Test coverage

The suite covers handshake vectors and failures, incremental frame parsing at
every byte boundary, masking direction, length encodings, fragmentation,
message-size limits, UTF-8 failures, ping/pong, close validation, same-read HTTP
handoff, object identity, subprotocols, text and binary messages, graceful
close, and local TLS client/server operation.

CI targets Perl 5.36 and Perl 5.44.

## Native-code policy

The protocol layer remains Perl until measurement demonstrates a material
bottleneck. If parsing or masking later justifies native work, WebSocket-specific
code belongs in this distribution. Linux::Event core should change only for a
reusable facility useful to multiple protocol distributions.

## Deferred work

- `permessage-deflate` negotiation and compression;
- WebSocket-specific XS;
- async/await-first APIs;
- independent-peer and Autobahn interoperability testing.
