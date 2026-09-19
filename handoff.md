# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`, branch `main`.

Development version: `0.001_001`. No CPAN release has been made.


### Broadcast / fan-out benchmark

Branch: `experiment/bq-broadcast-fanout`. Draft PR: #8.

This benchmark exercises a common pub/sub pattern rather than echo behavior.
One producer WebSocket sends a mixed JSON/emoji event to the server. The
server broadcasts that event to every subscriber. A broadcast is counted
complete only after every subscriber has received it; only then does the
producer send the next event.

The benchmark compares current main, the wslay experiment, and the optimized
bq path on the same runner. It reports broadcasts/sec and aggregate
deliveries/sec.

Two-round averages on an AMD EPYC 9V45:

256-byte mixed JSON/emoji:

- fan-out 10: main 3.27k broadcasts/s (32.7k deliveries/s),
  wslay 4.34k (43.4k/s), bq 5.75k (57.5k/s);
- fan-out 100: main 356 broadcasts/s (35.6k deliveries/s),
  wslay 469 (46.9k/s), bq 615 (61.5k/s);
- fan-out 1000: main 23.8 broadcasts/s (23.8k deliveries/s),
  wslay 26.1 (26.1k/s), bq 31.6 (31.6k/s).

1 KiB mixed JSON/emoji:

- fan-out 10: main 1.62k broadcasts/s (16.2k deliveries/s),
  wslay 2.50k (25.0k/s), bq 5.40k (54.0k/s);
- fan-out 100: main 169 broadcasts/s (16.9k deliveries/s),
  wslay 270 (27.0k/s), bq 566 (56.6k/s);
- fan-out 1000: main 13.3 broadcasts/s (13.3k deliveries/s),
  wslay 18.5 (18.5k/s), bq 29.5 (29.5k/s).

16 KiB mixed JSON/emoji:

- fan-out 10: main 139 broadcasts/s (1.39k deliveries/s),
  wslay 263 (2.63k/s), bq 2.19k (21.9k/s);
- fan-out 100: main 14.9 broadcasts/s (1.49k deliveries/s),
  wslay 27.0 (2.70k/s), bq 206 (20.6k/s).

The 16 KiB / 1000-peer case is intentionally omitted so the test remains a
WebSocket fan-out benchmark rather than primarily a memory-pressure benchmark.

Key conclusions:

- bq remains the strongest engine under realistic server fan-out.
- At fan-out 10-100, bq aggregate delivery throughput is nearly flat as fan-out
  increases, especially at 1 KiB and 16 KiB.
- At 1000 subscribers, all three engines lose aggregate delivery throughput,
  indicating that broader event-loop/socket scheduling and connection-count
  costs are becoming significant. bq still leads, but the relative gap narrows.
- For 1 KiB fan-out 10-100, bq delivers roughly 2.1x wslay and 3.3x main.
- For 16 KiB fan-out 10-100, bq delivers roughly 7.6-8.3x wslay and
  13.9-15.8x main.
- The result is end-to-end: producer receive, server broadcast writes, client
  receive parsing/validation, and loop scheduling are all included. No
  echo-specific or payload-reuse optimization is present.

### Realistic modern Unicode benchmark

Branch: `experiment/bq-realistic-unicode`. Draft PR: #7.

This benchmark was added because the earlier hot-path measurements were mostly
ASCII. It uses one-way traffic rather than echo behavior and compares current
main, the wslay experiment, and the optimized bq path on the same runner.

ASCII-only source files are preserved. Unicode payloads are constructed at
runtime. Profiles cover:

- ASCII control traffic;
- JSON-like mostly-ASCII application messages containing emoji;
- European text with 2- and 3-byte UTF-8;
- CJK-heavy 3-byte UTF-8;
- emoji-heavy 4-byte UTF-8.

Each profile is measured client->server and server->client around 64 B, 1 KiB,
and 16 KiB wire sizes. Mixed JSON, CJK, and emoji also have 100-client small
message cases.

The initial full matrix showed the optimized bq path ahead across all Unicode
profiles and sizes. Representative two-round client->server averages:

- European 64 B: main 56.8k/s, wslay 82.3k/s, bq 105.8k/s;
- European 1 KiB: main 13.9k/s, wslay 23.9k/s, bq 71.7k/s;
- European 16 KiB: main 1.07k/s, wslay 1.92k/s, bq 15.7k/s;
- CJK 64 B: main 64.0k/s, wslay 92.0k/s, bq 107.0k/s;
- CJK 1 KiB: main 26.6k/s, wslay 39.1k/s, bq 86.4k/s;
- CJK 16 KiB: main 2.58k/s, wslay 4.06k/s, bq 20.4k/s;
- emoji 64 B: main 67.3k/s, wslay 93.0k/s, bq 107.5k/s;
- emoji 1 KiB: main 30.7k/s, wslay 44.1k/s, bq 85.9k/s;
- emoji 16 KiB: main 3.23k/s, wslay 4.74k/s, bq 21.3k/s.

At 100 clients / about 256 B, CJK averaged main 45.1k/s, wslay 64.1k/s,
bq 85.7k/s; emoji averaged main 47.8k/s, wslay 66.7k/s, bq 85.5k/s.

The first 64-byte mixed-JSON template could terminate before reaching its emoji,
so that case was corrected and rerun separately. The corrected template puts the
emoji near the beginning and therefore guarantees genuinely mixed UTF-8 even at
64 bytes. Corrected two-round averages:

client -> server:

- 64 B: main 34.7k/s, wslay 63.8k/s, bq 82.5k/s;
- 256 B: main 22.7k/s, wslay 41.8k/s, bq 76.2k/s;
- 1 KiB: main 9.95k/s, wslay 18.0k/s, bq 60.1k/s;
- 16 KiB: main 809/s, wslay 1.46k/s, bq 11.85k/s.

server -> client:

- 64 B: main 48.0k/s, wslay 66.7k/s, bq 90.5k/s;
- 256 B: main 27.3k/s, wslay 45.5k/s, bq 82.9k/s;
- 1 KiB: main 10.7k/s, wslay 19.1k/s, bq 64.4k/s;
- 16 KiB: main 815/s, wslay 1.53k/s, bq 11.8k/s.

For corrected mixed JSON at 100 clients / 256 B, main averaged 20.4k/s,
wslay 37.8k/s, and bq 65.4k/s.

Conclusion: the optimized bq design is not an ASCII-specialized win. Its
advantage survives realistic mixed Unicode and becomes larger as Unicode text
messages grow. Dense CJK/emoji traffic is also strong. The benchmark therefore
supports bq for modern chat, JSON/event, international text, and emoji-bearing
applications rather than only synthetic ASCII or echo workloads.

### bq native send_text measurement

Branch: `experiment/bq-native-send-text`. Draft PR: #6.

This branch layers the winning inbound Perl-C-API validator on top of the
direct-delivery bq path and moves outbound `send_text` validation/encoding
into XS. The public API is unchanged and there is no echo-specific shortcut.

For byte scalars, XS uses the bytes directly and validates them with
`is_utf8_string_flags(..., UTF8_DISALLOW_ILLEGAL_C9_INTERCHANGE)`. For
Perl UTF-8 scalars, XS uses the scalar's existing UTF-8 representation,
validates the same RFC 3629 boundary, and passes those bytes to bq. Surrogates,
Perl-extended UTF-8, malformed sequences, and values above U+10FFFF remain
rejected; Unicode noncharacters remain allowed.

Normal tests are green on Perl 5.36 and 5.44 and both Autobahn directions are
green.

The one-way benchmark isolates the send-side change because both variants use
the same native receive validator. Two-round averages:

- client -> server text 64 B: Perl send 152.7k/s, native send 171.5k/s (+12.3%);
- client -> server text 1 KiB: 140.4k/s -> 154.5k/s (+10.1%);
- client -> server text 16 KiB: 53.6k/s -> 59.1k/s (+10.2%);
- server -> client text 64 B: 162.4k/s -> 184.7k/s (+13.7%);
- server -> client text 1 KiB: 143.8k/s -> 165.2k/s (+14.9%);
- server -> client text 16 KiB: 55.0k/s -> 60.3k/s (+9.7%).

Binary results were essentially unchanged, confirming that the gain is from
removing the Perl text encode/validation path rather than an unrelated
transport change.

The full same-run engine benchmark on an AMD EPYC 7763 shows the combined
optimized bq path at approximately:

- binary 64 B: 87.9-90.1k/s;
- binary 1 KiB: 81.8-82.2k/s;
- binary 16 KiB: 15.0-19.6k/s;
- text 64 B: 94.6-95.8k/s;
- text 1 KiB: 83.4-83.7k/s;
- text 16 KiB: 25.0-25.7k/s;
- binary 64 B / 100 clients: 66.3-66.4k/s;
- text 64 B / 100 clients: 68.5-70.4k/s.

In that same run wslay measured about 67-69k/s text 64 B, 43-44k/s text
1 KiB, 5.2k/s text 16 KiB, and 52-54k/s text 64 B / 100 clients. Current main
was about 27-29k/s, 25-27k/s, 9.8-9.9k/s, and 22k/s respectively.

This branch currently contains the strongest bq integration measured so far:
direct XS message delivery, Perl-C-API inbound RFC 3629 validation, and native
outbound send_text validation/encoding.

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
