use v5.36;
use strict;
use warnings;

use Mojolicious::Lite -signatures;

my $port = $ENV{PORT} // 9102;

app->log->level('fatal');
app->secrets(['benchmark-only-secret']);

websocket '/benchmark' => sub ($c) {
    $c->inactivity_timeout(300);

    $c->on(message => sub ($c, $text) {
        $c->send({text => $text});
    });

    $c->on(binary => sub ($c, $bytes) {
        $c->send({binary => $bytes});
    });
};

app->start('daemon', '-l', "http://127.0.0.1:$port");
