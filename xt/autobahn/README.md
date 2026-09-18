# Autobahn author test

This directory is repository-only release validation for
Linux::Event::WebSocket. It is not a runtime dependency and is not part of the
normal Perl test suite.

The Perl echo server in `echo-server.pl` is the implementation under test.
The external `crossbario/autobahn-testsuite` Docker image acts only as a
black-box WebSocket peer. No Autobahn/Python code is linked into or shipped
with this distribution.

The server conformance run executes the RFC 6455 cases and excludes section 13,
which covers the optional permessage-deflate extension that this distribution
does not currently implement.

GitHub Actions runs the external suite and uploads the generated HTML/JSON
report as an artifact. `check-report.pl` treats `OK`, `NON-STRICT`, and
`INFORMATIONAL` outcomes as conformant and fails the job for other outcomes.
