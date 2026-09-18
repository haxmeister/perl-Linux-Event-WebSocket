use v5.36;
use strict;
use warnings;

use Mojolicious::Lite -signatures;

my $port = $ENV{PORT} // 9102;

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

app->start('daemon', '-l', "http://127.0.0.1:$port");
