# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`

Default branch: `main`

## Current status

The architecture prototype is successful. No CPAN release has been made yet.

The original prototype proved API compatibility with released
`Net::WebSocket` 0.24, but initially used `--notest`. A normal installation was
then tested on Perl 5.36 and Perl 5.44.0:

- Perl 5.36: Net::WebSocket 0.24 installs normally.
- Perl 5.44.0: Net::WebSocket 0.24 fails only because
  `t/Net-WebSocket-HTTP.t` triggers the new warning
  `Possible attempt to escape whitespace in qw() list`.
- The warning is promoted to a failure by `Test::FailWarnings`.
- The remaining Net::WebSocket test programs pass on Perl 5.44.0.
- This is therefore a test-suite compatibility bug, not a demonstrated runtime
  WebSocket failure.

A minimal patch is stored at:

`contrib/Net-WebSocket-0.24-perl-5.44.patch`

An upstream issue draft is stored at:

`contrib/Net-WebSocket-0.24-perl-5.44-issue.md`

The patch has been applied to the current Felipe Gasper upstream source and the
full Net::WebSocket test suite passes with it on both Perl 5.36 and Perl 5.44.0
in GitHub Actions. The Linux::Event::WebSocket prototype tests also pass in both
matrix jobs.

The GitHub connector cannot create an issue in `FGasper/p5-Net-WebSocket`
(permission denied), so the issue draft must be posted upstream manually or
submitted from a normal fork/PR workflow.

## Proven boundaries

- `Uniform::HTTP::Request` can feed `Net::WebSocket::Handshake::Server` entirely
  through documented public methods.
- A tiny reader/writer adapter satisfies `Net::WebSocket::Parser` and Endpoint
  without depending on `IO::Framed`.
- Net::WebSocket client/server endpoints work over a real
  `Linux::Event::IO::Sock::Stream` socketpair, including endpoint-specific
  masking.
- Ping/pong and close control frames work through the adapter.
- Linux::Event::HTTP server Upgrade transitions the same live connection into a
  WebSocket Stream subclass correctly.
- A client can send the complete HTTP Upgrade request and its first masked
  WebSocket frame in one socket write; Linux::Event::HTTP preserves the
  post-HTTP frame bytes across `transition_to()` and the WebSocket target parses
  them correctly.
- The transitioned server can queue a WebSocket reply after the queued HTTP 101
  without violating output ordering.
- Client-side in-place transition after a validated 101 is also proven.

## Inheritance policy

This distribution uses ordinary single inheritance only.

There are no Perl roles, mixins, multiple inheritance, or method injection in
the WebSocket connection design.

The intended chains are exactly:

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

Use `endpoint_type` for the client/server distinction. Avoid the term "role" in
this project because it can imply a Perl role/mixin design that is explicitly
not being used.

## Dependency decisions

`Linux::Event::HTTP` is planned as a normal runtime dependency for the
high-level WebSocket client/server API. It owns the opening HTTP/1.1 Upgrade
exchange, TLS integration, output ordering, and same-read handoff.

Do not add a second miniature HTTP parser to Linux::Event::WebSocket merely to
avoid that dependency.

`Uniform::HTTP` remains an important semantic contract and the prototype proves
compatibility, but it is not currently needed as a direct runtime dependency.

`Net::WebSocket` remains the technically preferred RFC 6455 candidate at this
point because its public API fits the Linux::Event architecture cleanly. Its
Perl 5.44 installation failure has now been reduced to one verified test-only
compatibility bug with a one-line fix. Whether to make Net::WebSocket a formal
runtime dependency should be decided after the upstream report/patch is sent
and after considering release/maintenance implications.

Do not use `--notest` as a production workaround.

## Agreed architecture

- Established connections ultimately inherit from
  `Linux::Event::IO::Sock::Stream` through the single-inheritance chain above.
- Common established behavior belongs in
  `Linux::Event::WebSocket::Connection`.
- Endpoint-specific established classes are
  `Linux::Event::WebSocket::Client::Connection` and
  `Linux::Event::WebSocket::Server::Connection`.
- High-level coordinators are planned as `Linux::Event::WebSocket::Client` and
  `Linux::Event::WebSocket::Server`.
- `Linux::Event::HTTP` owns the HTTP Upgrade exchange.
- Linux::Event owns transport, TLS, buffering, backpressure, lifecycle, and
  `transition_to()`.
- The WebSocket engine stays behind a narrow internal boundary so it can be
  replaced without changing the public API.

## Transition-state rule

Linux::Event constructor callbacks deliberately survive `transition_to()`.
Linux::Event::HTTP may deliver already-read post-101 bytes to the target class
during the transition before the client `on_upgrade` callback fires.

Therefore WebSocket protocol/application state needed to parse target-protocol
input must already be attached to the live connection before handoff.

Server state can travel in the HTTP connection data. Client implementation
should use the public low-level `Linux::Event::HTTP::Client::Connection` API so
WebSocket state is seeded before requesting `upgrade_to`.

## Native-code policy

Do not add a WebSocket framer to Linux::Event core.

The first production implementation should remain Perl at the WebSocket layer.
If benchmarks later justify native parsing/masking, WebSocket-specific XS
belongs in this distribution. Core should change only for a reusable facility
useful to multiple protocol distributions, such as a generic external
incremental native byte-consumer boundary.

## Current prototype files

- `prototype/lib/LEWS/Prototype/Handshake.pm`
- `prototype/lib/LEWS/Prototype/IO.pm`
- `prototype/lib/LEWS/Prototype/Connection.pm`
- `prototype/t/01-handshake.t`
- `prototype/t/02-net-websocket-adapter.t`
- `prototype/t/03-linux-event-stream.t`
- `prototype/t/04-http-upgrade.t`
- `.github/workflows/prototype.yml`
- `contrib/Net-WebSocket-0.24-perl-5.44.patch`
- `contrib/Net-WebSocket-0.24-perl-5.44-issue.md`

## Next implementation work

1. Post the prepared compatibility report/patch upstream to Felipe.
2. Decide whether the verified test-only Perl 5.44 issue is acceptable while an
   upstream release is pending, or whether production should avoid the
   dependency until a fixed Net::WebSocket release exists.
3. Promote the established connection into the real namespace once that
   dependency decision is made.
4. Implement high-level Server using Linux::Event::HTTP::Server Upgrade.
5. Implement Client using Linux::Event::HTTP::Client::Connection with state
   attached before handoff.
6. Add plain ws:// integration tests, then wss:// tests.
7. Only after correctness/API stabilization, benchmark raw Stream versus
   WebSocket traffic across small through large payloads in both directions.
