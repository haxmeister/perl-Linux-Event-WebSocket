# Linux::Event::WebSocket 0.003

This is a compatibility release coordinated with Linux::Event::HTTP 0.004.
It keeps the existing callback-first WebSocket client/server API but removes
the dependency on the deleted legacy HTTP connection internals.

## Changes

- WebSocket opening HTTP/1.1 handshakes now use published Unblock::HTTP1
  0.13 directly, with canonical Uniform::HTTP 0.06 messages.
- The connection remains the same Linux::Event stream through the 101
  Upgrade. TLS, output ordering, native provider replacement and
  WebSocket frames sharing the handshake read are preserved.
- The existing native bq WebSocket framing engine, connection subclasses,
  callbacks, masking, UTF-8 validation, subprotocols, message limits,
  close handling and error semantics remain.
- A WebSocket-only application does not require Linux::Event::HTTP at
  runtime. Version 0.003 can be installed alongside either HTTP 0.003
  or HTTP 0.004.
- Server->http_server is retained as a legacy convenience accessor, but
  it now returns the Linux::Event listener, not an HTTP::Server object.
  Use Server->listener for new code.

## Which WebSocket API should applications use?

Use Linux::Event::WebSocket::Server or ::Client when the application is
primarily WebSocket traffic. These classes are complete entry points.

Use the on_websocket and connect_websocket convenience in
Linux::Event::HTTP if the application already uses its HTTP server or
client for ordinary HTTP traffic. No application needs to choose
between native and portable protocol parsers.

No new public WebSocket configuration options are introduced.

## Dependencies

- Perl 5.36+
- Linux::Event 0.117+
- Unblock::HTTP1 0.13+
- Uniform::HTTP 0.06+

There is no hard dependency on Linux::Event::HTTP or on Unblock::HTTP.

## Verified

- Real ws:// and wss:// end-to-end exchanges with HTTP 0.004 installed.
- Same-read client and server Upgrade/message handoff.
- RFC close lifecycle, UTF-8, binary, subprotocols and native framing.
- Perl 5.36 and 5.44 CI; source archive rebuilt and tested.
- Autobahn client and server conformance workflows.

## Coordinated publication order

Publish Linux::Event::WebSocket 0.003 **first**, then publish
Linux::Event::HTTP 0.004. Since WebSocket 0.003 does not depend on the
old HTTP internals, it also works before HTTP is upgraded. This avoids
any period where an upgraded HTTP installation leaves a released
WebSocket package unable to load.
