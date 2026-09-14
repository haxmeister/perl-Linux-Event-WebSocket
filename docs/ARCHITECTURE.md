# Linux::Event::WebSocket Architecture

This document records the working architecture while the distribution is being
implemented. Public API names are not yet frozen.

## Goals

- Provide WebSocket client and server support for Linux::Event.
- Keep the common API callback-first and easy to use correctly.
- Reuse Linux::Event transport, TLS, buffering, backpressure, lifecycle, and
  in-place protocol transitions.
- Reuse established protocol code where it fits through supported public APIs.
- Keep HTTP and WebSocket as separate protocol layers.
- Add native code only after measurement identifies a material bottleneck.

## Inheritance policy

This distribution uses ordinary single inheritance only.

There are no Perl roles, mixins, multiple-inheritance trees, or injected methods
in the connection design.

The intended class chains are:

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

Client versus server is called the endpoint type. The term "role" is avoided in
this distribution because it can imply a Perl role/mixin mechanism that is not
being used.

## Connection model

An established WebSocket connection is ultimately a
`Linux::Event::IO::Sock::Stream` through the single-inheritance chain above.

The Stream remains the transport owner. WebSocket adds protocol state and
application-facing WebSocket operations; it does not wrap or replace the live
socket after negotiation.

A standalone server uses `Linux::Event::HTTP::Server`. Accepted streams begin as
HTTP server connections and transition in place to
`Linux::Event::WebSocket::Server::Connection` after a successful Upgrade.

Conceptually:

```
Linux::Event::HTTP::Server
        |
        v
HTTP server connection
        |
        | successful Upgrade
        v
transition_to(Linux::Event::WebSocket::Server::Connection,
              input => leftover_bytes)
        |
        v
established WebSocket Stream
```

The transition preserves the socket, transport state, TLS state, queued output,
application data, and already-read bytes following the end of the HTTP headers.
Linux::Event core already provides and tests this behavior.

## HTTP boundary

`Linux::Event::HTTP` is a normal runtime dependency for the high-level
WebSocket client/server API.

This is deliberate. WebSocket opening negotiation is security-sensitive HTTP/1.1
protocol work. Linux::Event::HTTP already provides:

- incremental HTTP parsing and serialization;
- client and server Upgrade validation;
- TLS integration;
- output ordering;
- same-read post-Upgrade byte preservation;
- in-place `transition_to()` handoff.

Linux::Event::WebSocket should use that machinery instead of carrying a second
miniature HTTP parser.

`Uniform::HTTP` remains an important semantic contract. The prototype proved
that `Uniform::HTTP::Request` can drive a WebSocket handshake engine through a
clean public message boundary. It is not currently required as a separate
runtime dependency because Linux::Event::HTTP request/response objects already
expose the needed message semantics.

## WebSocket protocol engine decision

No external WebSocket protocol engine is currently approved as a production
runtime dependency.

`Net::WebSocket` remains a technically strong candidate. The prototype proved
that its documented public interfaces fit Linux::Event very well:

- no access to private object hashes or undocumented methods is necessary;
- `IO::Framed` is not required;
- a small compatible input/output adapter is sufficient for
  `Net::WebSocket::Parser` and Endpoint;
- its HTTP::Request/HTTP::Response convenience layer is not required.

However, `Net::WebSocket` 0.24 fails a normal test-driven installation on the
primary development machine. Earlier prototype CI used `cpanm --notest`, which
proved API compatibility but hid this installability problem.

Production policy is therefore:

- do not force-install `Net::WebSocket`;
- do not use `--notest` as an installation requirement or workaround;
- do not declare it as a runtime prerequisite until normal installs are proven
  on the supported Perl range;
- determine whether the failure is a stale test assumption or a real runtime
  incompatibility before choosing the protocol engine;
- compare any alternative on API fit, dependency footprint, correctness,
  maintenance, and installability rather than switching merely to avoid one
  failing test suite.

The prototype remains valuable evidence about the desired protocol-engine
boundary even if a different engine is ultimately selected.

## Transition-state rule

Linux::Event constructor callbacks deliberately survive `transition_to()`.
Linux::Event::HTTP can also deliver already-read post-101 bytes to the target
class during the transition itself.

Therefore all WebSocket state needed to parse target-protocol input must already
be attached to the live Stream before handoff.

For the server, the state travels in the HTTP connection's preserved application
data. For the client, the implementation should use the public low-level
`Linux::Event::HTTP::Client::Connection` API so WebSocket state is seeded before
requesting an Upgrade target.

Installing WebSocket state only from the client's `on_upgrade` callback is too
late for same-read post-101 data.

## Native-code policy

The first implementation should remain Perl at the WebSocket protocol layer
unless measurement demonstrates a material reason otherwise.

WebSocket-specific framing is not currently planned as a built-in
`Linux::Event::Framer`. Core framers are generic ordered-byte wire policies,
whereas WebSocket framing includes endpoint-specific masking, fragmented logical
messages, interleaved control frames, and additional protocol state.

If benchmarks later justify native work:

- WebSocket-specific parsing/masking code belongs in this distribution.
- Linux::Event core should change only if the work reveals a reusable extension
  facility needed by multiple protocol distributions.
- A likely reusable core direction would be an external incremental native
  byte-consumer/protocol-parser boundary, not a WebSocket-specific core framer.

## Vertical prototype result

The first vertical prototype is complete and passing when its candidate protocol
engine is present.

It proves:

1. a clean HTTP-message-to-WebSocket-handshake boundary;
2. no IO::Framed dependency is necessary for the tested engine;
3. client masking and server unmasked output work over Linux::Event Streams;
4. text messages, ping/pong, and close control flow work through a narrow adapter;
5. Linux::Event::HTTP can Upgrade the same live Stream into the WebSocket
   connection class;
6. a first masked WebSocket frame sent in the same socket write as the HTTP
   Upgrade request survives the HTTP parser and `transition_to()` intact;
7. queued HTTP 101 output and subsequent WebSocket output remain correctly
   ordered.

GitHub Actions run 34802469241 passed 43 prototype tests, but that run installed
`Net::WebSocket` with tests disabled. New CI explicitly tests normal installation
on the supported Perl range before the candidate can be promoted.

## Benchmark decision gate

Only after the production API is correct should performance work begin.
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
