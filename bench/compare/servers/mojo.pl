use v5.36;
use strict;
use warnings;

use Mojolicious::Lite -signatures;

my $port = $ENV{PORT} // 9102;
my $ack = '{"ok":true}';

app->log->level('fatal');
app->secrets(['benchmark-only-secret']);

websocket '/benchmark' => sub ($c) {
    $c->inactivity_timeout(300);

    if (($c->param('type') // 'text') eq 'binary') {
        $c->on(message => sub ($c, $bytes) {
            $c->send({binary => $bytes});
        });
    } else {
        $c->on(message => sub ($c, $text) {
            $c->send({text => $text});
        });
    }
};

websocket '/application' => sub ($c) {
    $c->inactivity_timeout(300);

    $c->on(message => sub ($c, $text) {
        die "application benchmark received malformed request\n"
            if substr($text, 0, 6) ne '{"op":';
        $c->send({text => $ack});
    });
};

app->start('daemon', '-l', "http://127.0.0.1:$port");
