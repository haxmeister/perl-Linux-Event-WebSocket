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
