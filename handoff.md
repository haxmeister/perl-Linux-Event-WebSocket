# Linux::Event::WebSocket handoff

Repository: `haxmeister/perl-Linux-Event-WebSocket`
Integration target: `main`
Current work branch: `fix/cpantesters-close-copy-leak`
Current CPAN release: `0.001`
Prepared follow-up release: `0.002`

## Current state - CPAN Testers 0.001 follow-up

Linux::Event::WebSocket 0.001 was published to CPAN on 2026-09-20.

CPAN Testers then exposed a native cleanup bug in the locally patched
`bq_websocket` Close handling. The failing reports completed all assertions in
`t/03-engine.t` and then aborted during object destruction with:

```text
bqws_free_socket: Assertion 'ws->alloc.memory_used == 0' failed.
```

The failing reports were on ANDK Debian 14 DEBUGGING/multiplicity Perl builds,
including Perl 5.40.5, 5.44.0, and 5.45.1. Many ordinary and threaded Linux
smokers passed, so this was not a general threaded-Perl or dependency failure.

Root cause: the local safe-Close-echo patch allocated an application-visible
copy of every received Close before validating its payload. Rejected one-byte,
invalid-code, or invalid-UTF8 Close frames freed the original message and
returned while leaving the copy owned by the bq socket with no retained
pointer. Destruction therefore found nonzero native allocation accounting.

The 0.002 fix:

- validates the received Close before allocating the application-visible copy;
- releases the original Close if copy allocation itself fails;
- exposes the private bq allocation count to internal regression tests;
- verifies rejected one-byte and invalid-UTF8 Close frames leave zero tracked
  native heap allocation.

Diagnostic reproduction also established that the published dependency stack
is sound: Linux::Event 0.116 and Linux::Event::HTTP 0.002 passed the WebSocket
suite on Perl 5.36, 5.38, 5.40, 5.42, and 5.44 in hosted CI.

Fix validation on PR #21 includes the production suite and generated
distribution archive. Autobahn client/server conformance must remain green
before merging to main.

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
- [x] Merge the validated raw-ABI integration into `main`.

## Core reentrant-close validation

Linux::Event 0.116 current `main` commit
`007db40e22374c6d7bf8e056b2d354681d20c852` includes the raw-consumer
provider-replacement and reentrant-close fixes required by this distribution.

Validation is complete against that core commit:

- Perl 5.36 production tests pass;
- Perl 5.44 production tests pass;
- the generated distribution archive rebuilds and passes its tests;
- same-read HTTP -> WebSocket provider replacement preserves post-101 input;
- server and client deliver `open` before a same-read first message;
- application `abort()` and close callbacks may close reentrantly from raw
  consumer delivery without corrupting core input accounting.

## Raw-buffer ABI production integration

Linux::Event 0.116 exposes a protocol-neutral raw native-consumer ABI and now
supports safe provider replacement across `transition_to()`.

The server opening handshake now uses Linux::Event::HTTP 0.002's native HTTP
consumer directly. After the 101 handoff, Linux::Event replaces that HTTP
consumer with the bq WebSocket raw consumer.

The client opening handshake still uses a small WebSocket-owned bridge into the
HTTP client response parser. After a valid 101 response, Linux::Event replaces
that bridge with the bq WebSocket raw consumer.

In both directions preserved post-101 bytes are re-driven through bq after the
live Stream has been reblessed to the WebSocket connection class.

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

The full production suite is green on Perl 5.36 and 5.44 against Linux::Event 0.116 current main commit `007db40e22374c6d7bf8e056b2d354681d20c852`, and the generated
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


## Current performance agenda

The high-concurrency small-text comparison is complete against Linux::Event
0.116/main.

With one outstanding application request per connection, five-sample medians
for Linux::Event::WebSocket were approximately:

- 64 B: 26.7k/s at 20 clients, 27.4k/s at 100, 23.0k/s at 500, and
  23.8k/s at 1000;
- 256 B: 26.2k/s at 20 clients, 25.6k/s at 100, 21.3k/s at 500, and
  22.8k/s at 1000.

At 1000 clients the same-run 64-byte medians were about 6.1k/s for
Mojolicious, 36.0k/s for Node ws, and 26.9k/s for Gorilla. The corresponding
256-byte medians were about 6.3k/s, 35.1k/s, and 25.6k/s.

A Linux::Event-only window-depth diagnostic then measured 64-byte application
traffic with windows of 1, 4, and 16. At 1000 clients the medians were about
23.3k/s, 50.3k/s, and 56.6k/s respectively. Window 16 stayed around 56-59k/s
from 20 through 1000 clients.

Conclusion: the remaining small-text request/ack gap is primarily exposed by
per-roundtrip scheduling/dispatch latency. The native RFC6455 parser is not the
first optimization target. The next useful investigation should trace the
message-callback -> send_text -> Stream write/flush path and event-loop
turnaround cost before considering more protocol-parser optimization.

The diagnostic tooling is retained under `bench/compare/` and is run manually
through the `WebSocket high-concurrency comparison` workflow so normal CI is
not lengthened.

## Send-path turnaround conclusion

The follow-up send-path isolation is complete against Linux::Event 0.116/main.

At 1000 clients with 64-byte application requests, window-1 medians were about
23.1k/s through public `send_text`, 23.3k/s through direct Engine send, 24.4k/s
through direct native bq queueing with the normal deferred flush, and 24.2k/s
with a preframed direct Stream write. The public WebSocket send layers therefore
account for only a small fraction of the one-at-a-time gap.

Forcing bq to flush and write immediately inside every message callback did not
improve window 1 and reduced window-4 throughput to about 38.0k/s versus
47.5-49.6k/s for the deferred paths. Preserve the current end-of-consumer
deferred flush: it usefully coalesces responses when several messages are
available in one input delivery.

Read-only inspection of Linux::Event 0.116 confirms that public
`Stream->write()` calls native `_write()` immediately. Existing diagnostic
counters also showed no write EAGAINs and no retained pending output in this
workload.

PR #17's private raw-write bypass provides the remaining architectural clue:
at 1000 clients it improved the window-1 median from about 24.3k/s to 27.4k/s
while preserving a small window-4 gain. It does so by reaching into private
Linux::Event Stream native state and therefore must not become the production
WebSocket implementation.

Next core-facing recommendation: evaluate an append-only native-consumer host
ABI output operation that lets a consumer submit an already-built wire buffer
directly to its owning Stream's native output path. It must retain normal
buffering, backpressure, writable-interest, TLS, error, and lifecycle semantics.
Do not implement that change from this repository without explicit core
authorization.

## Core boundary

Do not modify Linux::Event core from this WebSocket project without explicit
authorization. The generic raw-consumer, provider-replacement, and reentrant
terminal-accounting facilities required by this integration now exist in
Linux::Event 0.116/main and are consumed here without WebSocket-specific core
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
