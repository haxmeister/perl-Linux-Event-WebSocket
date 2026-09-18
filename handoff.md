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
Linux::Event::WebSocket::_UTF8
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
t/04-utf8.t
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

Repository-only Autobahn server and client conformance are green. Both RFC
6455 runs execute 301 selected cases and exclude sections 12 and 13, which
cover optional WebSocket compression/permessage-deflate. Each side currently
reports 294 strict OK, 4 NON-STRICT, and 3 INFORMATIONAL outcomes; close
behavior reports 298 OK and 3 INFORMATIONAL outcomes. There are no conformance
failures.

The first Autobahn run exposed one real issue: Perl Encode's strict UTF-8 policy
rejects Unicode noncharacters that RFC 3629 permits. The private `_UTF8`
validator now implements the RFC 3629 byte boundary directly and is covered by
`t/04-utf8.t`.

## Performance baseline

Repository author benchmarks now cover protocol primitives and steady-state
public client/server echo workloads. The first pass found two concrete
bottlenecks:

- opening and closing `/dev/urandom` for every client mask;
- byte-by-byte Perl UTF-8 validation.

Both were resolved without XS. `_Random` now reuses a lazy close-on-exec random
descriptor. `_UTF8` uses an ASCII fast path plus C-backed `utf8::decode` with
explicit RFC 3629 scalar-range checks.

Representative hosted-runner results improved 1 KiB text echo from roughly
1.4k to 14.7k msg/s and 16 KiB text echo from roughly 97 to 5.7k msg/s.
Normal CI and Autobahn client/server conformance remain green.

See `docs/BENCHMARKS.md`.

Cross-implementation server and client benchmarks are now complete against
Mojolicious 9.49, Node `ws` 8.21.3 + `bufferutil`, and Go
`gorilla/websocket` 1.5.3 using common peers and same-run CPU isolation.

Representative server results put Linux::Event close to Mojolicious under
64-byte 100-connection load (32.5k vs 32.1k binary; 28.9k vs 29.7k text) and
ahead of Mojolicious for 16 KiB binary (21.1k vs 17.1k). Mojolicious is still
moderately faster on most small/medium single-connection cases. Node and Go are
several times faster on small-message workloads.

The mirror client comparison shows Linux::Event around 64-91% of Mojolicious
depending on payload, with the smallest gap on larger binary messages.

Standalone parser/masking rates are much higher than the public-stack rates, so
the next performance target is profiling full per-message dispatch overhead,
not speculative XS.

The first timer-driven client benchmark also exposed a separate Linux::Event
core fairness concern: under sustained external echo traffic, nominal
1.5-second timers were delayed by tens of seconds. The benchmark now uses a
wall-clock cutoff so results are valid. Do not modify core for this without
explicit user authorization.

Current measurements still do not justify WebSocket-specific XS by themselves.

## Resolved core close boundary

The inherited Stream `close()` collision has been resolved in Linux::Event
0.115. Core involuntary teardown now bypasses protocol-subclass public
`close()` semantics, while explicit semantic close requests remain virtual.

This distribution now requires Linux::Event 0.115 or newer.
`t/13-core-close-boundary.t` verifies the WebSocket side of that contract.

## Remaining release work

1. Decide whether to profile and reduce the remaining full-stack per-message
   overhead before release, especially the client path.
2. Perform a release-readiness review before the first CPAN upload.

Separate core follow-up, not authorized in this project: investigate timer
fairness under continuously ready external I/O.

## Files to read first

```text
docs/ARCHITECTURE.md
docs/BENCHMARKS.md
lib/Linux/Event/WebSocket/Connection.pm
lib/Linux/Event/WebSocket/_Handshake.pm
lib/Linux/Event/WebSocket/_Parser.pm
lib/Linux/Event/WebSocket/_Engine.pm
lib/Linux/Event/WebSocket/_UTF8.pm
t/04-utf8.t
t/10-client-server.t
t/12-upgrade-tail.t
t/13-core-close-boundary.t
t/14-close-lifecycle.t
t/20-tls-client-server.t
```
