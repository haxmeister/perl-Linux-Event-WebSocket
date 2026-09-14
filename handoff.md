# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`

Default branch: `main`

## Current status

The architecture prototype is successful. Public API names are now being promoted
into the real distribution, but no CPAN release has been made yet.

GitHub Actions run 34802469241 passed all four prototype files: 43 tests total
against released `Net::WebSocket` 0.24, `Uniform::HTTP` 0.02, Linux::Event
0.114, and Linux::Event::HTTP 0.001.

## Proven boundaries

- `Uniform::HTTP::Request` can feed `Net::WebSocket::Handshake::Server` entirely
  through documented public methods.
- A tiny reader/writer adapter satisfies `Net::WebSocket::Parser` and Endpoint
  without depending on `IO::Framed`.
- Net::WebSocket client/server endpoints work over a real
  `Linux::Event::IO::Sock::Stream` socketpair, including endpoint-specific
  masking.
- Ping/pong and close control frames work through the adapter.
- Linux::Event::HTTP server Upgrade transitions the same live connection into a
  WebSocket Stream subclass correctly.
- A client can send the complete HTTP Upgrade request and its first masked
  WebSocket frame in one socket write; Linux::Event::HTTP preserves the
  post-HTTP frame bytes across `transition_to()` and the WebSocket target parses
  them correctly.
- The transitioned server can queue a WebSocket reply after the queued HTTP 101
  without violating output ordering.
- Client-side in-place transition after a validated 101 is also proven.

## Inheritance policy

This distribution uses ordinary single inheritance only.

There are no Perl roles, mixins, multiple inheritance, or method injection in
the WebSocket connection design.

The intended chains are exactly:

```
Linux::Event::WebSocket::Client::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

and separately:

```
Linux::Event::WebSocket::Server::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

Use `endpoint_type` for the client/server distinction. Avoid the term "role" in
this project because it can imply a Perl role/mixin design that is explicitly
not being used.

## Dependency decision

`Linux::Event::HTTP` is now planned as a normal runtime dependency for the
high-level WebSocket client/server API. This is intentional: the HTTP
handshake is security-sensitive protocol work, and Linux::Event::HTTP already
provides the exact client/server Upgrade validation, TLS integration, output
ordering, and same-read handoff needed here.

Do not add a second miniature HTTP parser to Linux::Event::WebSocket merely to
avoid that dependency.

`Uniform::HTTP` remains an important semantic contract and the prototype proves
compatibility, but it is not currently needed as a direct runtime dependency by
this distribution. Linux::Event::HTTP message objects expose the same relevant
message behavior.

## Agreed architecture

- Established connections ultimately inherit from
  `Linux::Event::IO::Sock::Stream` through the single-inheritance chain above.
- Common established behavior belongs in
  `Linux::Event::WebSocket::Connection`.
- Endpoint-specific established classes are
  `Linux::Event::WebSocket::Client::Connection` and
  `Linux::Event::WebSocket::Server::Connection`.
- High-level coordinators are planned as `Linux::Event::WebSocket::Client` and
  `Linux::Event::WebSocket::Server`.
- `Net::WebSocket` owns RFC 6455 handshake/frame/message/control semantics.
- `Linux::Event::HTTP` owns the opening HTTP/1.1 Upgrade exchange.
- Linux::Event owns transport, TLS, buffering, backpressure, lifecycle, and
  `transition_to()`.
- `IO::Framed` is not required.
- Net::WebSocket private internals remain off limits.

## Transition-state rule

Linux::Event constructor callbacks deliberately survive `transition_to()`.
HTTP also feeds same-read post-101 bytes to the target during transition before
client `on_upgrade` fires. Therefore WebSocket protocol/application state must
be attached to the live connection before handoff.

Server-side state can be carried in the HTTP Server connection data/state and
preserved through transition. Client-side work should use the public low-level
`Linux::Event::HTTP::Client::Connection` so WebSocket state can be seeded at
connect time before requesting `upgrade_to`.

Do not try to install WebSocket state only from the client `on_upgrade`
callback; that is too late for same-read post-101 data.

## Native-code policy

Do not add a WebSocket framer to Linux::Event core.

The first production implementation remains Perl at the WebSocket layer. If
benchmarks later justify native parsing/masking, WebSocket-specific XS belongs
in this distribution. Core should change only for a reusable facility useful to
multiple protocol distributions, such as a generic external incremental native
byte-consumer boundary.

## Current prototype files

- `prototype/lib/LEWS/Prototype/Handshake.pm`
- `prototype/lib/LEWS/Prototype/IO.pm`
- `prototype/lib/LEWS/Prototype/Connection.pm`
- `prototype/t/01-handshake.t`
- `prototype/t/02-net-websocket-adapter.t`
- `prototype/t/03-linux-event-stream.t`
- `prototype/t/04-http-upgrade.t`
- `.github/workflows/prototype.yml`

These are evidence, not the final public namespace.

## Next implementation work

1. Promote the adapter and established connection into the real namespace.
2. Implement high-level Server using Linux::Event::HTTP::Server Upgrade.
3. Implement Client using Linux::Event::HTTP::Client::Connection with state
   attached before handoff.
4. Expose a callback-first API without leaking Net::WebSocket Message objects.
5. Define graceful WebSocket close behavior separately from hard transport
   close.
6. Add plain ws:// integration tests, then wss:// tests.
7. Only after correctness/API stabilization, benchmark raw Stream versus
   WebSocket traffic across small through large payloads in both directions.
