# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`

Default branch: `main`

## Current status

Architecture exploration has started. No public API is frozen and no release has
been made.

The repository currently records the initial design in `README.md` and
`docs/ARCHITECTURE.md`.

## Agreed architecture

- Established WebSocket connections inherit from
  `Linux::Event::IO::Sock::Stream`.
- A standalone WebSocket server composes
  `Linux::Event::IO::Sock::Listener`.
- HTTP Upgrade uses Linux::Event `transition_to()` so the same live Stream,
  transport, TLS state, queued output, and already-read bytes survive the
  protocol change.
- `Net::WebSocket` 0.24 is the initial RFC 6455 protocol-engine candidate.
- Use only documented Net::WebSocket APIs. Do not reach into private internals.
- Avoid an IO::Framed dependency if a small compatible adapter can satisfy the
  documented read/write contracts.
- `Uniform::HTTP` is useful as the framework-neutral HTTP request/response
  representation. It deliberately does no parsing, serialization, or I/O.
- `Linux::Event::HTTP` already has the exact Upgrade handoff WebSocket needs:
  server code can call `$conn->transaction->upgrade($target_class)` after
  setting the Upgrade response metadata; the HTTP transaction completes and the
  same Stream transitions to the requested protocol class with post-HTTP bytes
  preserved.
- Standalone WebSocket operation must not require Linux::Event::HTTP.
- Linux::Event::HTTP integration should use its existing Upgrade mechanism rather
  than duplicate HTTP server logic here.
- Do not add a WebSocket framer to Linux::Event core at this stage.
- If native WebSocket parsing/masking is later justified by benchmarks, protocol
  code belongs in this distribution. Core changes should expose only reusable
  facilities useful to multiple protocol distributions.

## Important existing core proof

Linux::Event core already has a TLS regression test that reads an HTTP 101
response and the first WebSocket bytes in the same TLS application read,
extracts the HTTP boundary, calls `transition_to()` with the leftover bytes, and
verifies that the new protocol class receives those bytes while TLS remains
attached. This substantially de-risks the WebSocket handoff model.

## Net::WebSocket findings

Net::WebSocket 0.24 is still marked beta, but the useful integration boundaries
are documented public API:

- `Net::WebSocket::Handshake::Server->valid_method_or_die()`
- `Net::WebSocket::Handshake::Server->valid_protocol_or_die()`
- `consume_headers()`
- `to_string()`
- `Net::WebSocket::Parser` accepts anything implementing IO::Framed::Read-like
  `read()` behavior.
- Endpoint output may be IO::Framed::Write or a compatible object.

The next prototype must prove these contracts without private access.

## First implementation milestone

Build a vertical plain `ws://` echo prototype:

1. Accept one TCP connection.
2. Incrementally parse the HTTP/1.1 Upgrade request.
3. Produce/expose a clean HTTP request representation.
4. Validate the WebSocket handshake with public Net::WebSocket APIs.
5. Queue `101 Switching Protocols`.
6. Preserve bytes following `\r\n\r\n`.
7. Transition the same Stream into the WebSocket connection class.
8. Receive one text message.
9. Echo it.
10. Exercise ping/pong.
11. Perform a clean close handshake.

Then repeat the same flow over TLS.

## After correctness

Benchmark raw Linux::Event Stream versus WebSocket echo across small through
large payloads, in both directions. Pay special attention to client masking,
parser overhead, copies/allocations, and Perl callback crossings.

Do not begin XS work until the benchmark identifies a material bottleneck.
