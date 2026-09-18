# Cross-implementation WebSocket benchmark

This benchmark compares WebSocket **servers** under one common external load
generator. It is author/development tooling only and is not part of the CPAN
distribution dependencies.

Competitors:

- Linux::Event::WebSocket
- Mojolicious
- Node.js `ws`
- Go `gorilla/websocket`

The Node `ws` load generator is the same for every server. It opens all
connections before measurement, runs a 0.5-second warmup, then measures
steady-state echo traffic for 1.5 seconds. HTTP Upgrade time is therefore
excluded.

Both text and binary messages are measured at 64 B, 1 KiB, and 16 KiB with one
connection. The 64-byte case is also measured with 10 and 100 connections.

Compression is disabled for every implementation. The Node load generator and
Node server have the optional `bufferutil` acceleration installed because
that is the documented high-performance `ws` configuration.

When at least two CPUs are available, the server is pinned to CPU 0 and the
load generator to CPU 1. The Go server also runs with `GOMAXPROCS=1`, making
the primary comparison single-server-core rather than allowing one competitor
to consume extra cores.

The GitHub workflow records exact runtime and library versions together with
the CSV result. Hosted-runner results are useful for relative comparison within
one run, not as universal hardware-independent throughput claims.
