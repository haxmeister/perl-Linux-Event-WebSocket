package Linux::Event::WebSocket::_BQ;
use v5.36;
use strict;
use warnings;

use Linux::Event::WebSocket ();
use XSLoader ();

XSLoader::load(
    'Linux::Event::WebSocket',
    $Linux::Event::WebSocket::VERSION,
);

1;
