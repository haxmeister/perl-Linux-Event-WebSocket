# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`, branch `main`.

Development version: `0.001_001`. No CPAN release has been made.


### bq Perl C API UTF-8 measurement

Branch: `experiment/bq-perlapi-utf8`. Draft PR: #5.

This experiment keeps the direct XS delivery path but replaces Perl-level
inbound text decoding with Perl's C UTF-8 API. ASCII is detected with
`is_utf8_invariant_string_loc()`; non-ASCII is validated with
`is_utf8_string_flags(..., UTF8_DISALLOW_ILLEGAL_C9_INTERCHANGE)`. This
matches RFC 3629 while continuing to allow Unicode noncharacters.

Normal tests are green on Perl 5.36 and 5.44 and both Autobahn directions are
green.

A two-round one-way benchmark on an AMD EPYC 9V74 compared Perl-level
validation, the hand-written C validator, and the Perl C API validator.
Average text-message rates:

- client -> server, 64 B: Perl 88.3k/s, hand C 99.9k/s, Perl C API 99.6k/s;
- client -> server, 1 KiB: Perl 80.9k/s, hand C 82.2k/s, Perl C API 89.5k/s;
- client -> server, 16 KiB: Perl 33.7k/s, hand C 22.0k/s, Perl C API 37.0k/s;
- server -> client, 64 B: Perl 96.0k/s, hand C 109.2k/s, Perl C API 109.2k/s;
- server -> client, 1 KiB: Perl 87.6k/s, hand C 88.8k/s, Perl C API 98.1k/s;
- server -> client, 16 KiB: Perl 35.4k/s, hand C 22.4k/s, Perl C API 38.5k/s.

The Perl C API path improves over Perl-level validation by about 8.6-13.8%
across every tested text size and direction while leaving binary throughput
essentially unchanged. It also avoids the hand-written validator's severe
large-message regression. This is the preferred inbound UTF-8 implementation
from the experiments so far.

The next isolated target is outbound `send_text` validation/encoding. Do not
special-case echo traffic; measure outbound work independently on the one-way
benchmark.

### bq integration hot-path measurement

Branch: `experiment/bq-integration-hotpath`. Draft PR: #3. This branch is
based on the corrected bq experiment and exists only to measure integration
overhead.

The prototype removes per-message Perl AV event construction. XS now calls the
private Engine directly with connection, opcode, and payload. Default behavior
retains all UTF-8 validation and is green on normal CI (Perl 5.36 and 5.44) and
Autobahn client/server conformance.

A benchmark-only switch, `LEWS_BQ_BENCH_SKIP_UTF8=1`, temporarily bypasses
text-message UTF-8 validation on receive and send. It is not intended as a
shipping option; it exists only to isolate the validation cost.

Same-run two-round averages on AMD EPYC 7763:

- binary 64 B: baseline 90.3k/s, direct 88.9k/s;
- binary 1 KiB: baseline 82.1k/s, direct 82.0k/s;
- binary 16 KiB: baseline 16.1k/s, direct 18.8k/s;
- text 64 B: baseline 64.8k/s, direct 63.0k/s, no-UTF8 88.0k/s;
- text 1 KiB: baseline 58.3k/s, direct 58.3k/s, no-UTF8 81.3k/s;
- text 16 KiB: baseline 15.3k/s, direct 17.3k/s, no-UTF8 26.2k/s;
- binary 64 B / 100 clients: baseline 68.7k/s, direct 67.0k/s;
- text 64 B / 100 clients: baseline 49.3k/s, direct 50.1k/s,
  no-UTF8 65.9k/s.

Conclusion: AV event construction is not the dominant remaining cost. Direct
delivery is essentially neutral for small/medium messages, with a measurable
large-message gain. Perl-side UTF-8 validation is the major text-path cost:
removing it for measurement improves the direct path by about 40% at 64 B and
1 KiB, 52% at 16 KiB, and 32% at 100 clients.

The next performance question is therefore how to preserve the project's RFC
3629 behavior while moving UTF-8 validation/decoding out of the Perl hot path,
preferably into the native adapter without duplicating validation on echo send.

### Active bq_websocket experiment

Branch: `experiment/bq-websocket-engine`. Draft PR: #2.

This branch starts from main commit `cb3b2fc5` and does not modify main.
It vendors the MIT/public-domain bq_websocket protocol core under
`vendor/bq_websocket/`. The upstream platform/socket implementation is not
used. Linux::Event continues to own the Stream, epoll, TLS, HTTP Upgrade,
connection lifecycle, and the public Perl API.

The private Engine routes framing through a thin XS adapter using
`bqws_read_from()` / `bqws_write_to()`. The vendored core is compiled
single-threaded because each WebSocket connection remains owned by the
Linux::Event loop.

Local experiment corrections currently include:

- Linux::Event-compatible buffer I/O rather than bq's platform layer;
- unlimited partial-message part count subject to the existing message-size limit;
- incremental consumption when bq consumes only part of a Stream input chunk;
- RFC 6455 rejection of control frames larger than 125 octets before processing;
- retaining a Pong response for every Ping instead of upstream's latest-Pong-only policy;
- existing Linux::Event::WebSocket close-code and UTF-8 behavior at the Perl-facing boundary.

Normal CI is green on Perl 5.36 and 5.44. Autobahn client and server are both
green across the 301 selected non-compression cases with zero conformance
failures: 287 OK, 11 NON-STRICT, 3 INFORMATIONAL; close behavior is 298 OK
and 3 INFORMATIONAL.

The post-fix three-way same-run benchmark confirms the performance result.
On an AMD EPYC 7763 runner, two rounds produced approximately:

- binary 64 B: bq 90.4-90.8k/s, wslay 76.3-77.4k/s, main 35.1-35.3k/s;
- binary 1 KiB: bq 81.6-83.5k/s, wslay 61.8-62.6k/s, main 31.0k/s;
- binary 16 KiB: bq 15.3-15.4k/s, wslay 9.3-12.3k/s, main 11.5k/s;
- text 64 B: bq 64.4-64.7k/s, wslay 68.2-69.7k/s, main 27.0-30.4k/s;
- text 1 KiB: bq 59.0k/s, wslay 43.3-43.8k/s, main 26.0-27.3k/s;
- text 16 KiB: bq 18.0-18.8k/s, wslay 5.3-5.4k/s, main 9.8-10.0k/s;
- binary 64 B / 100 clients: bq 63.2-63.3k/s, wslay 55.8-57.3k/s,
  main 24.5-26.3k/s;
- text 64 B / 100 clients: bq 48.7-51.3k/s, wslay 47.4-54.5k/s,
  main 21.6-22.5k/s.

bq is therefore the strongest measured engine overall so far. wslay retains a
small advantage for tiny text in some runs, but bq avoids wslay's severe
large-text regression and is substantially faster than current main throughout
the measured matrix.

Do not merge this experiment solely from performance. Review the maintenance
cost of carrying the small vendored C library, the higher Autobahn NON-STRICT
count versus main/wslay, and the local RFC corrections before making an adoption
decision.

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
the remaining performance work is focused on full per-message dispatch overhead,
not speculative XS.

A first full client-path NYTProf run (GitHub Actions run 35407218947) confirmed
that this overhead is distributed rather than concentrated in masking alone.
For roughly 8k binary messages, validated WebSocket state lookup ran about 33k
times, the weakened Engine connection was dereferenced about 25k times, and
frame opcode-to-type lookup ran about 16k times. The 1 KiB text profile also
showed the parser's local copy of its accumulated input becoming materially more
expensive under coalesced traffic, and ASCII text was being validated/copied
again on the echo send path.

The first optimization pass collapsed repeated established-state lookups,
cached the hot message callback at open time, cached the Engine connection while
feeding a batch, kept the parser on its owned input buffer instead of a
copy-on-write local alias, reused the parser's resolved frame type, added a
common short-length size-check fast path, and avoided redundant outbound ASCII
validation.

That pass is green in normal CI and Autobahn. Under the identical NYTProf
workflow, binary 64-byte client throughput rose from about 4.1k to 7.4k msg/s
and text 1 KiB from about 3.5k to 6.5k msg/s. Validated state lookup dropped
from about four calls per message to one, Engine connection dereference from
about three to one, opcode/type lookup from two to one, and the text byte-copy
path from two to one.

Comparison run 35407582470 landed on an AMD EPYC 7763 runner, while the prior
35406148646 baseline used an Intel Xeon Platinum 8573C, so their absolute
throughput must not be compared directly. Within that AMD run Linux::Event still trailed Mojolicious, so a second
pure-Perl pass added a fixed 4-byte mask-key path, specialized text/binary data
frame encoding, a trusted established-state fast lookup, cached direct message
delivery, and an inlined common unfragmented Engine path. Normal tests and
Autobahn are green after the accompanying test placement correction.

Comparison run 35408108321 then landed on an AMD EPYC 9V74 runner. In that
same-run matrix Linux::Event now decisively beats Mojolicious on server binary
64 B / 1 KiB (56.2k / 51.3k vs 34.8k / 32.3k), client binary 64 B / 1 KiB
(46.1k / 41.5k vs 37.4k / 34.0k), server text 64 B / 1 KiB
(44.7k / 36.7k vs 31.8k / 27.9k), and client text 64 B
(41.6k vs 34.4k). The remaining common-path miss is client text 1 KiB
(27.8k vs 32.4k), with large text also still behind.

Profiling and a focused Perl microbenchmark identify duplicate ASCII UTF-8
validation as the next target. C-backed utf8::decode validates 1 KiB ASCII
several times faster than the current byte-range regex. The next pass therefore
uses utf8::decode plus a decoded-length ASCII test, retaining the explicit
surrogate/out-of-range scalar check for non-ASCII input so RFC 3629 behavior is
unchanged.

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

## Current decision and remaining release work

Do **not** proceed to release-readiness yet. The user considers Mojolicious a
low-performance Perl baseline and requires Linux::Event::WebSocket to
**decisively outperform it** on the common small/medium-message paths before
the first release.

Next task:

1. Profile the complete per-message hot path, especially the client path:
   Stream -> on_data -> state lookup -> engine -> parser -> engine dispatch ->
   connection dispatch -> application callback -> send.
2. Remove avoidable Perl-layer dispatch/state/call overhead and rerun the
   same cross-implementation benchmark after each meaningful change.
3. Prefer pure-Perl structural wins first. Add WebSocket-specific XS only when
   profiling identifies a measured bottleneck that cannot be removed cleanly
   in Perl.
4. Preserve the current Autobahn-green behavior while optimizing.
5. Only after Linux::Event::WebSocket clearly passes Mojolicious on the target
   benchmark matrix should the release-readiness review begin.

Important baseline: server performance is already close to or ahead of
Mojolicious in some cases, but the client path remains the clearest deficit
(roughly 64-91% of Mojolicious depending on payload).

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
