# WebSocket benchmarks

These are author/development benchmarks. They are not installed and do not run
under `make test`.

`protocol.pl` isolates private RFC 6455 operations: frame encoding, masking,
frame parsing, and UTF-8 validation. It deliberately measures both a fixed-mask
client frame and the real random-mask path so random-number overhead is visible
instead of hidden.

`echo.pl` measures steady-state round trips through the public
Linux::Event::WebSocket client and server APIs. HTTP Upgrade time is excluded:
measurement starts only after every requested client has reached `on_open`.
The `window` option controls how many messages remain in flight per
connection.

Examples:

    perl -Iblib/lib bench/protocol.pl
    perl -Iblib/lib bench/echo.pl --type binary --bytes 64 --clients 1 --window 32
    perl -Iblib/lib bench/echo.pl --type text --bytes 1024 --clients 10 --window 8

GitHub Actions provides repeatable regression samples, but hosted-runner numbers
should not be treated as absolute hardware-independent performance claims.
Local measurements on a stable machine are preferred before making native-code
decisions.
