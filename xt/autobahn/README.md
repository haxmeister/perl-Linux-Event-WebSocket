# Autobahn author test

This directory is repository-only release validation for
Linux::Event::WebSocket. It is not a runtime dependency and is not part of the
normal Perl test suite.

The Perl echo server in `echo-server.pl` is used for server conformance.
`client-driver.pl` drives the public Linux::Event::WebSocket client through
the fuzzing-server case sequence. The external
`crossbario/autobahn-testsuite` Docker image acts only as a black-box
WebSocket peer. No Autobahn/Python code is linked into or shipped with this
distribution.

The server and client conformance runs execute the RFC 6455 correctness cases.
They exclude sections 12 and 13, which cover WebSocket compression and the
optional permessage-deflate extension that this distribution does not currently
implement.

GitHub Actions runs the external suite and uploads the generated HTML/JSON
report as an artifact. `check-report.pl` treats `OK`, `NON-STRICT`, and
`INFORMATIONAL` outcomes as conformant and fails the job for other outcomes.
