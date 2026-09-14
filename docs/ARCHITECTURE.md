# Linux::Event::WebSocket Architecture

This document records the working architecture while the first vertical
prototype is being built. Public API names are not yet frozen.

## Goals

- Provide WebSocket client and server support for Linux::Event.
- Keep the common API callback-first and easy to use correctly.
- Reuse Linux::Event transport, TLS, buffering, backpressure, lifecycle, and
  in-place protocol transitions.
- Reuse established protocol code where it fits through supported public APIs.
- Keep HTTP and WebSocket as separate protocol layers.
- Add native code only after measurement identifies a material bottleneck.

## Connection model

An established WebSocket connection is a subclass of
`Linux::Event::IO::Sock::Stream`.

The Stream remains the transport owner. WebSocket adds protocol state and
application-facing WebSocket operations; it does not wrap or replace the live
socket after negotiation.

A standalone server owns a `Linux::Event::IO::Sock::Listener`. Accepted streams
begin in an HTTP-handshake protocol class and transition in place to the
WebSocket connection class after a successful Upgrade.

Conceptually:

```
Linux::Event::IO::Sock::Listener
        |
        v
HTTP handshake Stream
        |
        | successful Upgrade
        v
transition_to(WebSocket connection, input => leftover_bytes)
        |
        v
established WebSocket Stream
```

The transition must preserve the socket, transport state, TLS state, queued
output, and any already-read bytes following the end of the HTTP headers.
Linux::Event core already provides and tests this behavior.

## HTTP boundaries

### Uniform::HTTP

`Uniform::HTTP::Request` and `Uniform::HTTP::Response` are suitable canonical
representations for HTTP handshake messages. Uniform::HTTP deliberately does no
parsing, serialization, or I/O.

A standalone WebSocket listener may therefore use a small handshake byte parser
to produce a Uniform::HTTP request, then pass the relevant method, version, and
headers into WebSocket handshake validation.

Uniform::HTTP should not become the transport or incremental HTTP parser.

### Linux::Event::HTTP

Linux::Event::HTTP already defines a live-stream Upgrade handoff: after a
validated `101 Switching Protocols`, the HTTP transaction completes and the
same Linux::Event Stream transitions to the requested protocol class while
preserving already-read post-HTTP bytes.

Linux::Event::WebSocket should consume that handoff for applications that are
already using Linux::Event::HTTP rather than embedding or duplicating the HTTP
server.

Standalone WebSocket service and Linux::Event::HTTP integration should converge
on the same established WebSocket connection class.

## Initial WebSocket protocol engine

`Net::WebSocket` is the first protocol-engine candidate because it separates
RFC 6455 logic from transport and HTTP parsing. The prototype must use only its
documented public APIs.

Rules for the experiment:

- No access to private object hashes or undocumented methods.
- Do not make `IO::Framed` a distribution dependency merely because
  Net::WebSocket examples use it.
- Supply a small compatible input/output adapter if the documented contracts are
  sufficient.
- HTTP::Request and HTTP::Response from the HTTP distribution are not required;
  Net::WebSocket handshake objects may be fed headers directly.
- If the adapter becomes invasive or depends on private implementation details,
  reject the approach rather than entrenching the dependency.

## Native-code policy

The first implementation is pure Perl at the WebSocket protocol layer.

WebSocket-specific framing is not currently planned as a built-in
`Linux::Event::Framer`. Core framers are generic ordered-byte wire policies,
whereas WebSocket framing includes endpoint-role masking, fragmented logical
messages, interleaved control frames, and additional protocol state.

If benchmarks later justify native work:

- WebSocket-specific parsing/masking code belongs in this distribution.
- Linux::Event core should change only if the work reveals a reusable extension
  facility needed by multiple protocol distributions.
- A likely reusable core direction would be an external incremental native
  byte-consumer/protocol-parser boundary, not a WebSocket-specific core framer.

## First vertical prototype

The first milestone is intentionally narrow:

1. Accept one plain TCP connection.
2. Read an HTTP/1.1 WebSocket Upgrade request incrementally.
3. Represent or expose the request through the chosen HTTP boundary.
4. Validate/generate WebSocket handshake data with public Net::WebSocket APIs.
5. Queue the `101 Switching Protocols` response.
6. Preserve bytes following the HTTP header terminator.
7. Transition the same Stream into the WebSocket connection class.
8. Receive one text message.
9. Echo that text message.
10. Exercise ping/pong.
11. Complete a clean close handshake.

Then repeat the same path over TLS.

## Benchmark decision gate

Only after the vertical prototype is correct should performance work begin.
Benchmark at least small, medium, and large messages in both directions, because
client-to-server masking may have a different cost profile from server-to-client
traffic.

Measure:

- raw Linux::Event Stream ceiling;
- WebSocket echo throughput;
- latency where useful;
- parser cost;
- masking/unmasking cost;
- copies/allocations;
- Perl callback crossings.

Optimize only demonstrated bottlenecks.
