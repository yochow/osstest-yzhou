
package Osstest;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      $tftptail
                      %c $dbh_state
                      readconfig opendb_state selecthost
                      poll_loop log
                      power_state
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $tftptail= '/spider/pxelinux.cfg';

our %c;
our $dbh_state;

sub readconfig () {
    require 'config.pl';
}
sub opendb ($) {
    my ($dbname) = @_;
    my $src= "dbi:Pg:dbname=$dbname";
    my $dbh= DBI->connect($src, 'osstest','', {
        AutoCommit => 1,
        RaiseError => 1,
        ShowErrorStatement => 1,
        })
        or die "could not open state db $src";
    return $dbh;
}

sub opendb_state () {
    $dbh_state= opendb('statedb');
}
sub selecthost ($) {
    my ($name) = @_;
    my $ho= { Name => $name };
    my $dbh= opendb('configdb');
    my $selname= "$name.$c{TestHostDomain}";
    my $sth= $dbh->prepare('SELECT * FROM ips WHERE reverse_dns = ?');
    $sth->execute($selname);
    my $row= $sth->fetchrow_hashref();  die "$selname ?" unless $row;
    die if $sth->fetchrow_hashref();
    $ho->{Ip}=    $row->{ip};
    $ho->{Ether}= $row->{hardware};
    $ho->{Asset}= $row->{asset};
    logm("host: selected $ho->{Name} $ho->{Asset} $ho->{Ether}");
    return $ho;
    $dbh->disconnect();
}

sub poll_loop ($$$&) {
    my ($interval, $maxwait, $what, $code) = @_;
    # $code should return undef when all is well
    
    logm("$what: waiting ${maxwait}s...");
    my $waited= 0;
    for (;;) {
        my $bad= $code->();
        last if !defined $bad;
        $waited <= $maxwait or die "$what: wait timed out: $bad.\n";
        sleep($interval);
        $waited += $interval;
    }
    logm("$what: ok.");
}

sub power_state ($$) {
    my ($ho, $on) = @_;
    my $want= (qw(s6 s1))[!!$on];
    my $asset= $ho->{Asset};
    logm("power: setting $want for $ho->{Name} $asset");
    my $rows= $dbh_state->do
        ('UPDATE control SET desired_power=? WHERE asset=?',
         undef, $want, $asset);
    die "$rows ?" unless $rows==1;
    my $sth= $dbh_state->prepare
        ('SELECT current_power FROM control WHERE asset = ?');
    $sth->bind_param(1, $asset);
    
    poll_loop(1,30, "power: checking $want", sub {
        $sth->execute();
        my ($got) = $sth->fetchrow_array();
        return undef if $got eq $want;
        return "state=\"$got\"";
    });
}
sub logm ($) {
    my ($m) = @_;
    print "LOG $m\n";
}

1;
