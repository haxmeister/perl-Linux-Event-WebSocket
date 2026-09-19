# Vendored bq_websocket

Upstream: https://github.com/bqqbarbhg/bq_websocket
Commit: 6c188d3f0edca38d7a8926e0d30f4c145414ba4c
License used here: MIT

Only the protocol core is vendored. The upstream platform/socket layer is not
used; Linux::Event continues to own transport, TLS, HTTP Upgrade, timers,
backpressure, and lifecycle.

This directory is experimental. Linux::Event-specific correctness patches are
documented in the branch history and must be reviewed before production use.
