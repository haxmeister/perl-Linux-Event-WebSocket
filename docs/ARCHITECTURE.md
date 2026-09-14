# Linux::Event::WebSocket Architecture

This document records the implemented architecture of the development version of
Linux::Event::WebSocket. The distribution has not yet had its first CPAN release,
so public API details may still change.

## Goals

- Provide WebSocket client and server support for Linux::Event.
- Keep the common API callback-first and easy to use correctly.
- Reuse Linux::Event transport, TLS, buffering, backpressure, lifecycle, and
  in-place protocol transitions.
- Reuse Linux::Event::HTTP for the opening HTTP/1.1 Upgrade instead of carrying
  another HTTP parser.
- Reuse established WebSocket protocol code through supported public APIs.
- Keep protocol-engine details behind a private boundary.
- Add native code only after measurement identifies a material bottleneck.

## Layer ownership

The current implementation divides responsibility this way:

```text
Linux::Event
    socket ownership
    TLS transport
    ordered byte delivery
    write buffering
    backpressure
    lifecycle
    transition_to()

Linux::Event::HTTP
    HTTP/1.1 request/response parsing
    opening Upgrade exchange
    Upgrade validation
    live-stream protocol handoff
    same-read post-HTTP byte preservation

Linux::Event::WebSocket
    public WebSocket API
    connection state
    callback dispatch
    peer framing policy
    message-size policy
    UTF-8 text policy
    graceful close policy

Net::WebSocket
    RFC 6455 frame objects
    frame parsing
    message defragmentation
    masking/unmasking
    ping/pong handling
    close control-frame machinery
```

This separation is deliberate. HTTP and WebSocket remain separate protocol
layers, and Linux::Event remains the transport engine.

## Inheritance policy

This distribution uses ordinary single inheritance only.

There are no Perl roles, mixins, multiple-inheritance trees, or injected methods
in the connection design.

The implemented class chains are:

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

Client versus server is called the `endpoint_type`. The term `role` is avoided
in this distribution because it can imply a Perl role/mixin mechanism that is
not being used.

## Connection model

An established WebSocket connection is a specialized Linux::Event socket Stream.
The Stream remains the live transport owner. WebSocket adds protocol state and
application-facing WebSocket operations; it does not wrap or replace the live
socket after negotiation.

The common established-connection API lives in:

```text
Linux::Event::WebSocket::Connection
```

with client/server subclasses providing endpoint-specific identity and policy.

Important common methods currently include:

```text
send_text
send_binary
ping
close
abort
is_open
is_closing
subprotocol
secure
url
handshake_request
handshake_response
data
```

`close()` starts a WebSocket close handshake. `abort()` is the immediate
transport-close escape hatch.

## Server model

The high-level server composes `Linux::Event::HTTP::Server`.

Accepted connections begin as a private HTTP server connection class. After a
successful WebSocket handshake, Linux::Event::HTTP transitions the same live
object in place to `Linux::Event::WebSocket::Server::Connection` or the
configured subclass.

Conceptually:

```text
Linux::Event::WebSocket::Server
        |
        | owns
        v
Linux::Event::HTTP::Server
        |
        v
private HTTP connection
        |
        | successful Upgrade
        v
transition_to(WebSocket server connection,
              input => post_http_bytes)
        |
        v
established WebSocket Stream
```

The transition preserves the socket, transport state, TLS state, queued output,
application data, and already-read bytes following the end of the HTTP headers.

The production tests prove that a client may send its first masked WebSocket
frame in the same write as the HTTP Upgrade request and that those frame bytes
arrive correctly in the transitioned WebSocket connection.

## Client model

The high-level client uses the public low-level
`Linux::Event::HTTP::Client::Connection` machinery for the opening HTTP exchange.

This matters because Linux::Event::HTTP can deliver already-read bytes following
the HTTP 101 response to the transition target before its public `on_upgrade`
callback runs.

WebSocket state is therefore attached to the live connection before the Upgrade
request is issued. A valid 101 response is checked for the WebSocket-specific
handshake requirements before the target class is considered open.

Conceptually:

```text
Linux::Event::WebSocket::Client
        |
        v
private HTTP client connection
        |
        | validated 101 Upgrade
        v
transition_to(WebSocket client connection,
              input => post_http_bytes)
        |
        v
established WebSocket Stream
```

The same object identity is retained across the transition.

## Transition-state rule

Linux::Event constructor callbacks deliberately survive `transition_to()`.
Linux::Event::HTTP may also feed post-HTTP bytes into the target class during the
transition itself.

Therefore all state needed to parse WebSocket input must already be attached to
the live Stream before handoff.

The current implementation stores WebSocket protocol/application state in the
connection data that Linux::Event preserves across transition.

This rule is fundamental. Installing WebSocket state only from an `on_upgrade`
callback is too late for same-read post-101 data.

## HTTP boundary

`Linux::Event::HTTP` is a normal runtime dependency for the high-level client and
server APIs.

This is intentional. Opening negotiation is HTTP/1.1 protocol work, and the HTTP
distribution already provides:

- incremental HTTP parsing and serialization;
- client and server Upgrade validation;
- TLS integration;
- output ordering;
- same-read post-Upgrade byte preservation;
- in-place `transition_to()` handoff.

Linux::Event::WebSocket therefore does not contain a second miniature HTTP
parser.

## Uniform::HTTP

`Uniform::HTTP` remains useful as the ecosystem's framework-neutral HTTP message
contract. The early prototype proved that a `Uniform::HTTP::Request` can drive a
WebSocket server handshake through public interfaces.

Linux::Event::WebSocket does not currently need a separate direct
`Uniform::HTTP` prerequisite because Linux::Event::HTTP already supplies the
request/response objects used by the high-level transport path.

That does not prevent future integration points from exposing or accepting
Uniform HTTP objects where doing so improves interoperability.

## Net::WebSocket boundary

`Net::WebSocket` is the current RFC 6455 engine.

The production dependency is deliberately isolated behind private modules such
as:

```text
Linux::Event::WebSocket::_Handshake
Linux::Event::WebSocket::_IO
Linux::Event::WebSocket::_Parser
Linux::Event::WebSocket::_State
```

The public Linux::Event::WebSocket API does not expose Net::WebSocket objects as
part of its normal connection API.

The integration uses documented public Net::WebSocket interfaces. It does not
require `IO::Framed`, and it does not depend on Net::WebSocket's optional
HTTP::Request/HTTP::Response convenience wrapper.

A small input/output adapter implements the byte-read/write contract expected by
Net::WebSocket while Linux::Event remains the actual transport owner.

This private boundary is important because it allows a future protocol engine or
native implementation to replace Net::WebSocket without redesigning the public
API.

## Net::WebSocket Perl 5.44 compatibility issue

Released `Net::WebSocket` 0.24 has a test-only compatibility problem on Perl
5.44. A backslash inside a `qw()` list in `t/Net-WebSocket-HTTP.t` emits a new
warning, and `Test::FailWarnings` promotes that warning to a test failure.

A minimal patch is stored in:

```text
contrib/Net-WebSocket-0.24-perl-5.44.patch
```

The full patched upstream test suite passes on Perl 5.36 and Perl 5.44.0. An
upstream issue has been filed with Felipe Gasper.

Development CI currently checks out upstream Net::WebSocket, applies the patch
when needed, and installs that source. This is temporary development plumbing;
it is not intended to become a user-facing `--notest` or force-install
requirement.

Before the first CPAN release, either an upstream fixed release should be
available or the dependency/release policy should be revisited explicitly.

## Peer framing policy

Net::WebSocket provides general frame parsing and endpoint behavior, but
Linux::Event::WebSocket also enforces peer-side RFC 6455 rules at its private
parser boundary.

Current checks include:

- client-to-server frames must be masked;
- server-to-client frames must not be masked;
- nonzero RSV bits are rejected while no extension has been negotiated;
- control frames must not be fragmented;
- control payloads must not exceed 125 bytes;
- close frames may not contain a one-byte payload;
- close status codes are validated;
- close reasons must be valid UTF-8;
- advertised frame payload sizes are checked against configured limits before
  accepting large reads.

Text messages are decoded to Perl character strings only after UTF-8 validation.
Binary messages remain byte strings.

## Message-size protection

The high-level client and server default `max_message_size` to 16 MiB.

The limit serves two purposes:

1. prevent a peer from advertising an unreasonable frame payload and causing an
   oversized parser read request;
2. limit the accumulated size of a fragmented logical WebSocket message.

The limit is configurable upward or downward by the application.

## Ping/pong behavior

Incoming pings are handled by Net::WebSocket and receive a matching pong.
Applications may also call `ping($payload)` explicitly.

Explicit user pings are intentionally separate from Net::WebSocket's optional
heartbeat counter. If heartbeat policy is later exposed as a high-level feature,
it should be designed explicitly rather than silently coupling it to `ping()`.

## Close behavior

The connection API distinguishes graceful WebSocket shutdown from immediate
transport termination:

```text
close(...)  -> send WebSocket close frame and wait for peer/timeout
abort       -> immediately close the underlying Stream transport
```

A configurable close timeout prevents a peer from leaving a connection stuck in
the closing state indefinitely.

### Open audit item: Stream close override

`Linux::Event::WebSocket::Connection` overrides the inherited Stream `close()`
name to mean graceful WebSocket close. Linux::Event core contains a small number
of internal dynamic `$self->close` calls in Stream infrastructure.

Before the first release, those call paths must be audited so a hard internal
transport failure can never accidentally dispatch to the WebSocket graceful
close override. If necessary, the public naming or guarded dispatch should be
adjusted before API freeze.

## TLS

`wss://` uses Linux::Event TLS through the HTTP opening phase. The live transport
remains attached across `transition_to()`.

Production integration tests cover a local TLS WebSocket client/server exchange
and verify that the real public path works after the HTTP-to-WebSocket handoff.

## Current test coverage

The production suite currently includes:

```text
t/00-load.t
t/02-parser-policy.t
t/10-client-server.t
t/11-message-types.t
t/20-tls-client-server.t
```

Coverage includes module loading, malformed peer framing policy, plain client and
server Upgrade, subprotocol negotiation, object identity across transition,
text/binary messaging, Unicode text, explicit ping processing, graceful close,
and TLS client/server operation.

The original architecture prototype remains under `prototype/` as executable
historical evidence for the integration boundary.

GitHub Actions run 34805543586 for commit
`f71c7ab2e9fcac7a3ed59f4d5c9fed62da2caf62` passed both the production suite and
prototype suite on Perl 5.36 and Perl 5.44.0.

## Native-code policy

The first implementation remains Perl at the WebSocket protocol layer.

WebSocket-specific framing is not planned as a built-in `Linux::Event::Framer`.
Core framers are generic ordered-byte wire policies, whereas WebSocket framing
includes endpoint-specific masking, fragmented logical messages, interleaved
control frames, and additional protocol state.

If benchmarks later justify native work:

- WebSocket-specific parsing/masking code belongs in this distribution;
- Linux::Event core should change only if the work reveals a reusable extension
  facility useful to multiple protocol distributions;
- a likely reusable core direction would be an external incremental native
  byte-consumer/protocol-parser boundary, not a WebSocket-specific core framer.

## Benchmark decision gate

Performance work begins only after correctness and the public API are stable
enough to measure meaningfully.

Benchmark at least small, medium, and large messages in both directions because
client-to-server masking may have a different cost profile from
server-to-client traffic.

Measure:

- raw Linux::Event Stream ceiling;
- WebSocket echo throughput;
- latency where useful;
- parser cost;
- masking/unmasking cost;
- copies/allocations;
- Perl callback crossings.

Optimize only demonstrated bottlenecks.

## Deferred work

The following are intentionally not part of the current initial implementation:

- `permessage-deflate` negotiation and compression;
- WebSocket-specific XS;
- a WebSocket framer in Linux::Event core;
- async/await-first APIs;
- a second standalone HTTP parser inside this distribution.
