# Linux::Event::WebSocket handoff

Repository: `haxmeister/perl-Linux-Event-WebSocket`
Integration branch: `experiment/raw-buffer-abi`
Based on validated native-engine branch: `feature/bq-native-engine`
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

Established receive path:

```text
Linux::Event native input
    -> WebSocket raw consumer / bq
    -> _Engine
    -> application callback
```

The HTTP opening exchange uses a WebSocket-owned temporary native byte bridge
into the existing Linux::Event::HTTP parser. Linux::Event then replaces that
provider with the bq WebSocket consumer at the 101 transition while preserving
post-Upgrade input.

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
- [x] Activate the raw native-consumer path through the real HTTP Upgrade.
- [x] Validate provider replacement and same-read post-101 delivery.
- [x] Validate reentrant abort/close on Perl 5.36 and 5.44.
- [x] Benchmark the public application path against the pre-raw baseline.
- [ ] Decide whether to merge into `main`.

## Core reentrant-close validation

Linux::Event main commit `1c3de59e395e05e79c735f5d5ef35cd5021e8c55`
fixes the raw-consumer reentrant-close accounting bug exposed by the WebSocket
integration.

Validation is complete against that core commit:

- Perl 5.36 production tests pass;
- Perl 5.44 production tests pass;
- the generated distribution archive rebuilds and passes its tests;
- same-read HTTP -> WebSocket provider replacement preserves post-101 input;
- server and client deliver `open` before a same-read first message;
- application `abort()` and close callbacks may close reentrantly from raw
  consumer delivery without corrupting core input accounting.

## Raw-buffer ABI production integration

Linux::Event 0.115 exposes a protocol-neutral raw native-consumer ABI and now
supports safe provider replacement across `transition_to()`.

The WebSocket distribution uses two consumers:

1. The private HTTP handshake connection uses a small WebSocket-owned bridge
   consumer. It materializes the borrowed native window and passes it to the
   existing Linux::Event::HTTP `on_data` parser. It does not parse HTTP.
2. After the 101 handoff, Linux::Event replaces that bridge with the bq
   WebSocket raw consumer. Preserved post-101 bytes are re-driven through bq
   after the live Stream has been reblessed to the WebSocket connection class.

The established provider:

- is declared through `_BQ->raw_consumer_definition`;
- does no Perl work during provider `create()`;
- lazily creates/adopts bq state on first WebSocket input;
- retains the actual `_Engine` object for direct XS event delivery;
- creates payload SVs only for completed application messages;
- preserves the Engine `in_feed` guard while bq drains input;
- flushes native Ping/Close output through the existing Stream write path;
- retains/releases the Linux::Event host around callback-capable input work.

Regression coverage includes split masked input, text/binary delivery,
automatic Pong output, normal and simultaneous Close lifecycle, same-read
HTTP->WebSocket handoff in both directions, open-before-message ordering, and
reentrant application abort/close.

The full production suite is green on Perl 5.36 and 5.44 against Linux::Event
core commit `1c3de59e395e05e79c735f5d5ef35cd5021e8c55`, and the generated
distribution archive rebuilds and passes its tests.

The focused raw boundary benchmark showed gains ranging from about +1.5% at
64-byte text to +63.8% at 16 KiB binary when compared with the old
`on_data -> Engine::feed` boundary.

More importantly, a same-run public application benchmark compared
`feature/bq-native-engine` with the integrated raw path using 20 public
clients, four in-flight requests per connection, JSON-like text requests, a
small server-side application check, and fixed acknowledgements. Five-sample
medians were:

| payload | pre-raw baseline | raw ABI | delta |
| --- | ---: | ---: | ---: |
| 256 B | 52,719 txn/s | 59,279 txn/s | +12.4% |
| 1 KiB | 49,200 txn/s | 55,760 txn/s | +13.3% |
| 16 KiB | 24,739 txn/s | 28,380 txn/s | +14.7% |

These are hosted-runner measurements and should be treated as architectural
evidence rather than portable absolute throughput claims.


## Core boundary

Do not modify Linux::Event core from this WebSocket project without explicit
authorization. The generic raw-consumer, provider-replacement, and reentrant
terminal-accounting facilities required by this integration now exist in
Linux::Event 0.115/main and are consumed here without WebSocket-specific core
code.

A separate timer-fairness issue was observed under sustained ready I/O, but it
is also outside this repository unless explicitly authorized.

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
