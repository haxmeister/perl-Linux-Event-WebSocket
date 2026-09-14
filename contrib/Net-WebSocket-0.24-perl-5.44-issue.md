# Net::WebSocket 0.24 test failure on Perl 5.44 from backslash in qw() list

Hi Felipe,

`Net::WebSocket 0.24` fails its test suite on Perl 5.44 because `t/Net-WebSocket-HTTP.t` includes a literal backslash inside a `qw()` list:

```perl
my @invalid = (
    ( map { "ha${_}he" } qw~ ( ) < > @ ; : \ " / [ ] ? = { } ~ ),
);
```

On Perl 5.44 this emits:

```text
Possible attempt to escape whitespace in qw() list at t/Net-WebSocket-HTTP.t line 9.
```

Because the test uses `Test::FailWarnings`, that warning becomes an extra failed test and prevents a normal install:

```text
# Failed test 'Test::FailWarnings should catch no warnings'
# Warning was 'Possible attempt to escape whitespace in qw() list at t/Net-WebSocket-HTTP.t line 9.'
# Looks like you planned 21 tests but ran 22.
```

I reproduced this on a threaded perlbrew Perl 5.44.0 and independently on a non-threaded Perl 5.44.0 GitHub Actions runner. A normal install passes on Perl 5.36, and all of the other Net::WebSocket test programs pass on 5.44.

A minimal fix is to take the backslash out of `qw()` and add it explicitly:

```diff
-    ( map { "ha${_}he" } qw~ ( ) < > @ ; : \ " / [ ] ? = { } ~ ),
+    ( map { "ha${_}he" } (qw~ ( ) < > @ ; : ~, '\\', qw~ " / [ ] ? = { } ~) ),
```

I applied that patch to the current upstream source and ran the full Net::WebSocket test suite in GitHub Actions. It passes on both Perl 5.36 and Perl 5.44.0.

This appears to be test-only; I have not found a runtime WebSocket failure associated with it.

I ran into this while evaluating Net::WebSocket as the RFC 6455 engine for `Linux::Event::WebSocket`. The API has been a very good fit, so I wanted to send the compatibility fix upstream regardless of which direction that project ultimately takes.

A ready-to-apply patch is also available as `contrib/Net-WebSocket-0.24-perl-5.44.patch` in `haxmeister/perl-Linux-Event-WebSocket`.
