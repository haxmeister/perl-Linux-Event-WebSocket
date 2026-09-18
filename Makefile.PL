use v5.36;
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'Linux::Event::WebSocket',
    VERSION_FROM  => 'lib/Linux/Event/WebSocket.pm',
    ABSTRACT_FROM => 'lib/Linux/Event/WebSocket.pm',
    AUTHOR        => 'Joshua S. Day <haxmeister@hotmail.com>',
    LICENSE       => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/haxmeister/perl-Linux-Event-WebSocket.git',
                web  => 'https://github.com/haxmeister/perl-Linux-Event-WebSocket',
            },
            bugtracker => {
                web => 'https://github.com/haxmeister/perl-Linux-Event-WebSocket/issues',
            },
        },
    },
    PREREQ_PM => {
        'Digest::SHA'         => 0,
        'Encode'              => 0,
        'Linux::Event'        => '0.114',
        'Linux::Event::HTTP'  => '0.001',
        'MIME::Base64'        => 0,
        'URI'                 => 0,
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
);
