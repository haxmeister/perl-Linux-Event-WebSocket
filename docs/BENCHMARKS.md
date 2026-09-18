# Linux::Event::WebSocket Benchmarks

These measurements guide implementation decisions. They are not published as
hardware-independent performance claims.

## Method

Repository author benchmarks live under `bench/`.

- `protocol.pl` isolates framing, masking, parsing, and UTF-8 validation.
- `echo.pl` measures steady-state round trips through the public WebSocket
  client and server APIs.
- HTTP Upgrade time is excluded from steady-state measurements.
- GitHub-hosted runners are useful for regression samples, but their absolute
  throughput varies between runs.

The first baseline was taken on Perl 5.44 on an Ubuntu GitHub runner using an
AMD EPYC 7763-class host.

## Bottleneck 1: client mask randomness

The original implementation opened, read, and closed `/dev/urandom` for every
client frame.

A same-run microbenchmark measured approximately:

| operation | original | persistent fd |
| --- | ---: | ---: |
| four random bytes | 129k/s | 896k/s |
| 64-byte masked frame encode | 90k/s | 256k/s |
| 1 KiB masked frame encode | 86k/s | 239k/s |
| 16 KiB masked frame encode | 43k/s | 70k/s |

The production implementation now keeps one lazy, close-on-exec
`/dev/urandom` descriptor and reuses it. No native code was required.

## Bottleneck 2: UTF-8 validation

The first RFC 3629 validator walked every byte in Perl. That was correct but
became the dominant cost for text messages.

Representative original validation rates were approximately:

| ASCII payload | original Perl byte loop |
| --- | ---: |
| 64 bytes | 151k/s |
| 1 KiB | 10k/s |
| 16 KiB | 655/s |

A full RFC regular expression did not scale well enough. The chosen production
path instead:

1. uses a cheap C-regex ASCII fast path;
2. uses Perl's C-backed `utf8::decode` for non-ASCII input;
3. explicitly rejects surrogate values and values above U+10FFFF so Perl's
   wider internal code-point range cannot loosen RFC 3629.

After that change, a representative run measured production validation at about
1.09M/s for 64-byte ASCII, 643k/s for 1 KiB, and 67k/s for 16 KiB.

The normal test suite and both Autobahn client/server conformance runs remained
green after the change.

## End-to-end effect

Hosted-runner results vary, so these are directional samples rather than a
strict hardware comparison.

| public echo case | initial baseline | after Perl optimizations |
| --- | ---: | ---: |
| binary, 64 B, 1 client | 16.0k msg/s | 21.0k msg/s |
| binary, 1 KiB, 1 client | 13.8k msg/s | 17.5k msg/s |
| binary, 16 KiB, 1 client | 7.4k msg/s | 8.0k msg/s |
| text, 64 B, 1 client | 9.4k msg/s | 16.9k msg/s |
| text, 1 KiB, 1 client | 1.4k msg/s | 14.7k msg/s |
| text, 16 KiB, 1 client | 97 msg/s | 5.7k msg/s |
| binary, 64 B, 10 clients | 12.8k msg/s | 17.2k msg/s |
| binary, 64 B, 100 clients | 13.0k msg/s | 16.3k msg/s |

The random-source optimization also produced a separate hosted-runner sample of
roughly 31k msg/s for 64-byte binary round trips, illustrating why absolute
GitHub-runner values should not be compared too literally across runs.

## Native-code conclusion

The benchmark pass found real bottlenecks, but both had strong Perl-level
solutions. Current evidence does **not** justify WebSocket-specific XS.

Native code should be reconsidered only after a future stable benchmark shows a
remaining protocol-layer bottleneck that is material in end-to-end workloads.
Masking or parsing are plausible future candidates, but neither is currently a
reason to add C/XS maintenance burden.

## Cross-implementation comparison

A repository-only comparison harness under `bench/compare/` runs minimal echo
servers and clients for:

- Linux::Event::WebSocket;
- Mojolicious 9.49;
- Node.js `ws` 8.21.3 with `bufferutil` 4.1.0;
- Go `gorilla/websocket` 1.5.3.

The server comparison uses one common Node `ws` load generator. The client
comparison uses one common Node `ws` echo server. Compression is disabled.
On runners with at least two CPUs, the implementation under test is pinned to
CPU 0 and the driver/peer to CPU 1. Go is constrained to `GOMAXPROCS=1`.
Each case warms up for 0.5 seconds and measures for 1.5 seconds after the
WebSocket handshake.

A representative same-run server comparison on an AMD EPYC runner measured:

| case | Linux::Event | Mojolicious | Node ws | Gorilla |
| --- | ---: | ---: | ---: | ---: |
| binary 64 B, 1 conn | 32.9k | 38.4k | 146.6k | 166.1k |
| binary 1 KiB, 1 conn | 30.7k | 35.3k | 132.6k | 142.3k |
| binary 16 KiB, 1 conn | 21.1k | 17.1k | 61.3k | 39.3k |
| binary 64 B, 100 conn | 32.5k | 32.1k | 139.2k | 145.0k |
| text 64 B, 1 conn | 29.3k | 34.9k | 139.2k | 153.5k |
| text 1 KiB, 1 conn | 25.8k | 31.3k | 124.1k | 126.5k |
| text 16 KiB, 1 conn | 10.5k | 13.4k | 33.1k | 35.5k |
| text 64 B, 100 conn | 28.9k | 29.7k | 127.2k | 130.5k |

The mirror client comparison on the same runner measured:

| case | Linux::Event | Mojolicious | Node ws | Gorilla |
| --- | ---: | ---: | ---: | ---: |
| binary 64 B, 1 conn | 29.9k | 42.8k | 151.1k | 160.2k |
| binary 1 KiB, 1 conn | 28.1k | 39.7k | 137.2k | 135.6k |
| binary 16 KiB, 1 conn | 20.7k | 22.7k | 58.1k | 25.6k |
| binary 64 B, 100 conn | 29.3k | 38.3k | 138.6k | 144.1k |
| text 64 B, 1 conn | 27.1k | 40.0k | 138.8k | 156.2k |
| text 1 KiB, 1 conn | 24.3k | 36.7k | 124.9k | 136.4k |
| text 16 KiB, 1 conn | 12.7k | 19.8k | 33.4k | 21.9k |
| text 64 B, 100 conn | 26.6k | 36.0k | 127.9k | 140.8k |

The comparison shows that Linux::Event::WebSocket is close to Mojolicious for
server-side concurrency and exceeds it for the representative 16 KiB binary
server case, while Mojolicious retains a moderate advantage on most small and
medium messages. The native-heavy Node and Go implementations remain several
times faster on small-message workloads.

The client comparison shows a larger Perl-to-Perl gap: Linux::Event is commonly
about 64-91% of Mojolicious throughput depending on payload, with the closest
result again on larger binary messages.

These results do not point to masking or standalone parsing as the dominant
remaining cost. The private parser/masking microbenchmarks are much faster than
the public end-to-end rates. The next useful performance investigation is
therefore profiling the complete parser -> engine -> connection -> callback
dispatch path rather than adding WebSocket-specific XS speculatively.

## Timer-fairness observation

The first version of the external client comparison used Linux::Event timers to
end each measurement interval. Under sustained external echo traffic, nominal
1.5-second timers were delayed by tens of seconds. A wall-clock cutoff checked
from the message path produced stable 1.5-second measurements.

That behavior is not attributed to Linux::Event::WebSocket itself. It is a
separate Linux::Event core scheduling/fairness follow-up and should be
investigated in the core repository only with explicit authorization.
