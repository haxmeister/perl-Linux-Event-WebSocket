# Linux::Event::WebSocket handoff

Repository: `haxmeister/perl-Linux-Event-WebSocket`
Integration branch: `feature/bq-native-engine`
Development version: `0.001_002`
No CPAN release has been made.

## Project boundary

Work in this repository only unless the user explicitly authorizes another
repository in the current chat. Do not modify Linux::Event core,
Linux::Event::HTTP, Uniform::HTTP, or another distribution from this project.

## Current integration direction

The performance investigation has moved from experimentation to productization.

The selected production direction is a small vendored `bq_websocket` protocol
core behind a private XS adapter. Linux::Event still owns epoll, sockets, TLS,
ordered bytes, buffering, backpressure, timers, and lifecycle.
Linux::Event::HTTP still owns the HTTP/1.1 Upgrade. bq is used only after the
connection has transitioned to WebSocket.

The public API remains unchanged:

```text
send_text  send_binary  ping  close  abort
is_open    is_closing   subprotocol  secure  url
handshake_request  handshake_response  data
```

## Native engine

Production path:

```text
Stream -> Connection -> _Engine -> _BQ/XS -> vendored bq_websocket
```

Inbound text is validated in XS with Perl's C UTF-8 API using the RFC 3629
boundary. Outbound `send_text` validation/encoding is also done in XS. Binary
messages remain byte strings.

Client frame masks use Linux `getrandom(2)`.

The older private `_Parser` and frame-encoding portions of `_Frame` are no
longer the production parser/encoder. They remain valuable as independent test
and benchmark references. `_Frame` still provides close-code policy used by
the production Engine.

## Vendored bq ownership

Upstream commit:
`6c188d3f0edca38d7a8926e0d30f4c145414ba4c`

License used for the vendored source: MIT.

The vendored source is intentionally patched. See
`vendor/bq_websocket/README.md` before updating it. Maintained differences
include secure Linux mask generation, RFC close validation, oversized-control
rejection before side effects, one-Pong-per-Ping behavior, and safe Close echo
ownership.

Do not replace the vendored files with a fresh upstream copy without
re-applying those policies and rerunning normal tests plus both Autobahn
directions.

## Why this engine was selected

The decision is based on repeated same-run measurements, not an echo-only
microbenchmark.

The optimized bq path materially beat the previous Perl engine and the wslay
prototype across:

- small and medium text/binary messages;
- large 16 KiB messages;
- one-way client/server traffic;
- realistic mixed JSON/emoji text;
- European, CJK, and emoji-heavy UTF-8;
- 100-client traffic;
- broadcast fan-out at 10, 100, and 1000 subscribers.

The clean integration branch's external server comparison measured about
156k/s for 64-byte text, 139k/s for 1 KiB text, 38.7k/s for 16 KiB text, and
125k/s for 64-byte text at 100 connections. The corresponding client rates were
about 138k/s, 126k/s, 46.1k/s, and 115k/s.

The 100-subscriber fan-out test measured about 61.5k deliveries/s at 256 B,
56.6k/s at 1 KiB, and 20.6k/s at 16 KiB.

See `docs/BENCHMARKS.md` for context. Hosted-runner values are architectural
evidence, not hardware-independent performance claims.

## Integration validation

The clean integration branch independently passed normal tests on Perl 5.36 and
5.44. Its generated 0.001_002 distribution archive includes WebSocket.xs and
the vendored bq source/license, rebuilds after extraction, and passes make test.

Autobahn client and server both complete all 301 selected RFC 6455 cases with
zero conformance failures:

- 287 OK;
- 11 NON-STRICT;
- 3 INFORMATIONAL;
- close behavior: 298 OK, 3 INFORMATIONAL.

The 11 NON-STRICT cases are understood. Seven are coalesced-read ordering cases
where bq closes with 1002 on a later malformed frame without first exposing a
completed preceding message. Four are fragmented-invalid-UTF-8 cases where bq
waits for logical-message completion before closing with 1007. Autobahn accepts
both behaviors. A trial change to force the first seven to strict-OK exposed
reentrancy/batching consequences and was reverted rather than compromising the
validated hot path.

The Autobahn report checker now requires exactly 301 cases per agent so a
truncated run cannot pass CI.

Sections 12 and 13 remain intentionally excluded because permessage-deflate is
not implemented.

## Integration checklist

- [x] Start clean integration branch from `main`.
- [x] Carry over only production bq/XS code and RFC regression tests.
- [x] Vendor upstream source and license inside this distribution.
- [x] Remove dependence on a system bq library.
- [x] Document local vendored-source patches.
- [x] Move inbound/outbound text validation into the measured native path.
- [x] Update architecture and benchmark documentation.
- [x] Make Autobahn/comparison/benchmark workflows load `blib/arch`.
- [x] Add a distribution-archive CI check for vendored source/license.
- [x] Normal CI green on Perl 5.36 and 5.44 on this integration branch.
- [x] Distribution archive builds and its extracted copy passes `make test`.
- [x] Autobahn client green on this integration branch.
- [x] Autobahn server green on this integration branch.
- [x] Full cross-implementation comparison completes on this integration branch.
- [x] Review the resulting branch diff for experiment-only files or behavior.
- [ ] Decide whether to merge into `main`.

## Core boundary

Do not modify Linux::Event core for this work. A separate timer-fairness issue
was observed under sustained ready I/O, but it is outside this repository and
requires explicit authorization.

## Files to read first

```text
docs/ARCHITECTURE.md
docs/BENCHMARKS.md
vendor/bq_websocket/README.md
WebSocket.xs
lib/Linux/Event/WebSocket/_BQ.pm
lib/Linux/Event/WebSocket/_Engine.pm
lib/Linux/Event/WebSocket/Connection.pm
t/03-engine.t
t/10-client-server.t
t/12-upgrade-tail.t
t/13-core-close-boundary.t
t/14-close-lifecycle.t
t/20-tls-client-server.t
```
