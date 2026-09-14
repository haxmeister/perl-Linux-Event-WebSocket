# Linux::Event::WebSocket Handoff

## Repository

`haxmeister/perl-Linux-Event-WebSocket`

Default branch: `main`

Current development version: `0.001_001`

No CPAN release has been made yet.

## Current status

The project has moved beyond the architecture prototype. There is now a working
production implementation in `lib/` with real client/server integration tests.

The latest code-bearing CI run before this documentation refresh was GitHub
Actions run `34805543586` for commit
`f71c7ab2e9fcac7a3ed59f4d5c9fed62da2caf62`.

That run passed completely on both Perl 5.36 and Perl 5.44.0:

- dependency setup;
- production build;
- production test suite;
- original architecture prototype suite.

The production implementation currently supports:

- `ws://` client and server;
- `wss://` client and server;
- text messages;
- binary messages;
- UTF-8 validation/decoding for text;
- explicit ping and automatic pong handling;
- graceful close handshake;
- hard transport abort;
- subprotocol negotiation;
- HTTP handshake request/response access;
- same-read HTTP-to-WebSocket byte handoff;
- object identity across `transition_to()`;
- configurable message-size protection, default 16 MiB;
- Linux::Event buffering/backpressure and TLS preservation.

## Public implementation layout

High-level coordinators:

```text
Linux::Event::WebSocket::Server
Linux::Event::WebSocket::Client
```

Established connections:

```text
Linux::Event::WebSocket::Connection
Linux::Event::WebSocket::Client::Connection
Linux::Event::WebSocket::Server::Connection
```

Private implementation boundary:

```text
Linux::Event::WebSocket::_Handshake
Linux::Event::WebSocket::_IO
Linux::Event::WebSocket::_Parser
Linux::Event::WebSocket::_State
Linux::Event::WebSocket::Client::_HTTPConnection
Linux::Event::WebSocket::Server::_HTTPConnection
```

The private boundary is intentional. Net::WebSocket must not leak into the
normal public connection API so the protocol engine can be replaced later if
needed.

## Inheritance policy

This distribution uses ordinary single inheritance only.

There are no Perl roles, mixins, multiple inheritance, or method injection in
the WebSocket connection design.

The exact connection chains are:

```text
Linux::Event::WebSocket::Client::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

and separately:

```text
Linux::Event::WebSocket::Server::Connection
    -> Linux::Event::WebSocket::Connection
    -> Linux::Event::IO::Sock::Stream
```

Use `endpoint_type` for the client/server distinction. Avoid the term `role` in
this project because it can imply a Perl role/mixin mechanism that is explicitly
not being used.

## Dependency decisions

### Linux::Event

Normal runtime dependency. Owns socket transport, TLS transport, ordered byte
delivery, buffering, backpressure, lifecycle, timers, and `transition_to()`.

Current minimum in `Makefile.PL`: `Linux::Event 0.114`.

### Linux::Event::HTTP

Normal runtime dependency for the high-level WebSocket client/server API.

It owns the opening HTTP/1.1 Upgrade exchange, incremental HTTP parsing,
serialization, TLS integration, output ordering, and same-read post-HTTP handoff.

Do not add a second miniature HTTP parser to Linux::Event::WebSocket merely to
avoid this dependency.

Current minimum in `Makefile.PL`: `Linux::Event::HTTP 0.001`.

### Uniform::HTTP

Remains an important ecosystem semantic contract. The prototype proved that a
`Uniform::HTTP::Request` can drive the WebSocket handshake cleanly.

It is not currently needed as a separate direct runtime prerequisite because
Linux::Event::HTTP supplies the request/response objects used in the live path.

### Net::WebSocket

Current RFC 6455 engine and declared runtime dependency in the development tree.
Current minimum in `Makefile.PL`: `Net::WebSocket 0.24`.

Its public API fits Linux::Event cleanly:

- no access to private Net::WebSocket object hashes is required;
- no `IO::Framed` dependency is required;
- no HTTP::Request/HTTP::Response convenience wrapper is required;
- a small reader/writer adapter is sufficient;
- frame/message/control machinery remains replaceable behind private modules.

## Net::WebSocket Perl 5.44 issue

Released Net::WebSocket 0.24 fails a normal test-driven installation on Perl
5.44 because `t/Net-WebSocket-HTTP.t` contains a literal backslash inside a
`qw()` list. Perl 5.44 emits:

```text
Possible attempt to escape whitespace in qw() list
```

`Test::FailWarnings` promotes that warning to a test failure.

This has been verified as a test-suite compatibility bug rather than a
demonstrated runtime WebSocket failure.

A minimal patch is stored at:

```text
contrib/Net-WebSocket-0.24-perl-5.44.patch
```

The full patched upstream Net::WebSocket suite passes on Perl 5.36 and Perl
5.44.0.

The user has filed an upstream issue with Felipe Gasper and intends to give him
a few days to respond/fix it.

Development is proceeding as if that small upstream bug is patched. If Felipe
does not respond or no fixed release appears, reconsider the dependency before
the first CPAN release.

Do not make `--notest` or force-install a production/user requirement.

## HTTP and transition architecture

The high-level server composes `Linux::Event::HTTP::Server`, not a raw Listener.
The high-level client uses Linux::Event::HTTP's low-level client connection for
the opening exchange.

A successful Upgrade transitions the same live object into the configured
WebSocket connection class.

The transition preserves:

- socket identity;
- TLS transport;
- output queue/order;
- Linux::Event backpressure state;
- application data/state;
- already-read WebSocket bytes following the HTTP headers.

The production tests prove the same-read case: the first masked WebSocket frame
can arrive immediately after the HTTP Upgrade request and survives the HTTP
parser plus `transition_to()` intact.

Client state is attached before issuing the HTTP Upgrade because Linux::Event::HTTP
may deliver post-101 bytes to the target class during transition before the
public client `on_upgrade` callback runs.

## Public connection behavior

Current common methods include:

```text
send_text
send_binary
ping
close
abort
is_open
is_closing
subprotocol
secure
url
handshake_request
handshake_response
data
```

`close()` starts the WebSocket close handshake. `abort()` immediately closes the
underlying transport.

Callback options currently include:

```text
on_open
on_message
on_close
on_error
on_drain
```

Server also has `on_handshake` for accepting/rejecting the opening request.

Subclass hooks use the `websocket_*` naming convention when no constructor
callback overrides them.

## Protocol-policy enforcement

Do not assume Net::WebSocket's generic parser enforces all endpoint peer rules.
Linux::Event::WebSocket::_Parser currently adds checks for:

- required client masking;
- forbidden server masking;
- RSV bits while extensions are disabled;
- fragmented control frames;
- control payloads larger than 125 bytes;
- invalid one-byte close payloads;
- invalid/reserved close status codes;
- invalid UTF-8 close reasons;
- oversized advertised frame reads.

The connection layer also tracks fragmented logical-message size against the
configured `max_message_size`.

Text payloads are UTF-8 validated and delivered as Perl character strings.
Binary payloads remain bytes.

## Current production tests

```text
t/00-load.t
t/02-parser-policy.t
t/10-client-server.t
t/11-message-types.t
t/20-tls-client-server.t
```

These cover:

- module loading;
- malformed framing policy;
- plain client/server Upgrade;
- subprotocol negotiation;
- object identity across transition;
- text echo;
- Unicode text;
- arbitrary binary bytes;
- explicit ping processing;
- graceful close;
- TLS client/server WebSocket exchange.

The original executable prototype remains under `prototype/` and is still run by
CI as architecture regression coverage.

## Native-code policy

Do not add a WebSocket framer to Linux::Event core.

The current implementation remains Perl at the WebSocket layer. If benchmarks
later justify native parsing/masking, WebSocket-specific XS belongs in this
distribution.

Linux::Event core should change only for a reusable facility useful to multiple
protocol distributions, such as a generic external incremental native
byte-consumer/protocol-parser boundary.

## Important unresolved audit item

`Linux::Event::WebSocket::Connection` overrides inherited `close()` so the public
method means a graceful WebSocket close handshake.

Linux::Event core has a small number of internal dynamic `$self->close` calls in
Stream infrastructure, including configuration-failure and native-consumer
paths.

Before API freeze/release, audit those paths carefully. A hard internal transport
failure must never accidentally dispatch into the WebSocket graceful-close
method. If needed, change the public naming or add guarded dispatch before the
first release.

This is currently the highest-priority correctness/API audit item.

## Deferred work

Not currently implemented/planned for the first correctness pass:

- `permessage-deflate`;
- WebSocket-specific XS;
- a WebSocket framer in Linux::Event core;
- async/await-first API;
- a second HTTP implementation inside this distribution.

## Next work

Recommended order when development resumes:

1. Audit the inherited Stream `close()` collision described above and fix it
   before public API freeze.
2. Add more adverse protocol tests around fragmented messages, close races,
   abrupt EOF, invalid UTF-8 text, and message-size boundaries.
3. Add interoperability tests against at least one independent WebSocket peer,
   not only Net::WebSocket on both ends.
4. Review public POD/examples for consistency and simplicity.
5. Observe Felipe's response to the Net::WebSocket Perl 5.44 issue and update the
   dependency/release plan accordingly.
6. When correctness/API work is stable, benchmark raw Linux::Event Stream versus
   WebSocket traffic across small through large payloads in both directions.
7. Add native code only for a measured bottleneck.
8. Perform a release-readiness review before assigning a stable first-release
   version and uploading to CPAN.

## Files to read first in a fresh chat

```text
handoff.md
docs/ARCHITECTURE.md
README.md
lib/Linux/Event/WebSocket/Connection.pm
lib/Linux/Event/WebSocket/Client.pm
lib/Linux/Event/WebSocket/Server.pm
t/10-client-server.t
t/20-tls-client-server.t
```

Do not modify Linux::Event core, Linux::Event::HTTP, Uniform::HTTP, or any other
repository unless the user explicitly authorizes work in that repository.
