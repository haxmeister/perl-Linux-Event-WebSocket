use v5.36;
use strict;
use warnings;

use JSON::PP qw(decode_json);

my $file = shift @ARGV // 'xt/autobahn/reports/servers/index.json';
open my $fh, '<', $file or die "cannot open Autobahn report $file: $!\n";
local $/;
my $report = decode_json(<$fh>);
close $fh;

my %allowed = map { $_ => 1 } qw(OK NON-STRICT INFORMATIONAL);
my @failure;
my %behavior;

for my $agent (sort keys %$report) {
    for my $case (sort keys %{$report->{$agent}}) {
        my $result = $report->{$agent}{$case};
        my $status = $result->{behavior} // 'UNKNOWN';
        ++$behavior{$status};
        push @failure, [ $agent, $case, $status, $result->{reportfile} ]
            if !$allowed{$status};
    }
}

say "Autobahn behavior summary:";
say "  $_: $behavior{$_}" for sort keys %behavior;

if (@failure) {
    say STDERR "Autobahn conformance failures:";
    for my $failure (@failure) {
        my ($agent, $case, $status, $reportfile) = @$failure;
        say STDERR "  $agent case $case: $status"
            . (defined($reportfile) ? " ($reportfile)" : '');
    }
    exit 1;
}

say "Autobahn RFC 6455 server conformance passed.";
