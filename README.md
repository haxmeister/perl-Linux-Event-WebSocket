# Linux::Event::WebSocket

Fast, composable WebSocket client and server built on Linux::Event.

## Status

Early architecture and prototype work. This distribution is not yet released.

## Direction

Linux::Event::WebSocket is a protocol layer for the Linux::Event communications
ecosystem. It will provide callback-first WebSocket client and server APIs while
leaving transport, TLS, buffering, backpressure, and lifecycle management to
Linux::Event.

The initial implementation deliberately starts without WebSocket-specific XS.
The first milestone is to prove the protocol and HTTP-upgrade boundaries using
public APIs, then benchmark before deciding whether native protocol machinery is
warranted.

Key design rules:

- Established WebSocket connections are Linux::Event socket-stream subclasses.
- A standalone WebSocket server composes Linux::Event::IO::Sock::Listener.
- HTTP Upgrade changes protocol in place with Linux::Event transition_to().
- Net::WebSocket is the initial candidate RFC 6455 protocol engine.
- Net::WebSocket private internals are off limits.
- IO::Framed is not a required dependency unless experiments prove it necessary.
- Uniform::HTTP may provide the framework-neutral handshake request/response
  representation; it does not own byte parsing or transport.
- Linux::Event::HTTP integration uses its existing live-stream HTTP Upgrade
  handoff rather than duplicating an HTTP server inside this distribution.
- WebSocket-specific native code, if benchmarks justify it, belongs here. Core
  changes should provide only reusable protocol-engine facilities.

See `docs/ARCHITECTURE.md` for the working design and `handoff.md` for current
exploration status.
