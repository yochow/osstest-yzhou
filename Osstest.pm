
package Osstest;

use strict;
use warnings;

use POSIX;
use IO::File;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      $tftptail
                      %c %r $dbh_state
                      readconfig opendb_state selecthost postfork
                      get_filecontents
                      poll_loop logm link_file_contents create_webfile
                      power_state
                      setup_pxeboot setup_pxeboot_local
                      await_webspace_fetch_byleaf await_sshd
                      target_cmd_root
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $tftptail= '/spider/pxelinux.cfg';

our (%c,%r);
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

sub postfork () {
    $dbh_state->{InactiveDestroy}= 1;
}

sub target_cmd_root ($$;$) {
    my ($ho, $tcmd, $timeout) = @_;
    # $tcmd will be put between '' but not escaped
    
    $timeout=10 if !defined $timeout;

    my $cmd= "ssh";
    my $opts= "-o UserKnownHostsFile=known_hosts";
    my $args= "root\@$ho->{Ip} '$tcmd'";
    logm("executing $cmd ... $args");
    alarm($timeout);
    system "$cmd $opts $args";
    $? and die $?;
    alarm(0);
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
    logm("host: selected $ho->{Name} $ho->{Asset} $ho->{Ether} $ho->{Ip}");
    return $ho;
    $dbh->disconnect();
}

sub poll_loop ($$$&) {
    my ($maxwait, $interval, $what, $code) = @_;
    # $code should return undef when all is well
    
    logm("$what: waiting ${maxwait}s...");
    my $start= time;  die $! unless defined $start;
    my $wantwaited= 0;
    my $waited= 0;
    for (;;) {
        my $bad= $code->();
        my $now= time;  die $! unless defined $now;
        $waited= $now - $start;
        last if !defined $bad;
        $waited <= $maxwait or die "$what: wait timed out: $bad.\n";
        $wantwaited += $interval;
        my $needwait= $wantwaited - $waited;
        sleep($needwait) if $needwait > 0;
    }
    logm("$what: ok. (${waited}s)");
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
    
    poll_loop(30,1, "power: checking $want", sub {
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
sub file_link_contents ($$) {
    my ($fn, $contents) = @_;
    # $contents may be a coderef in which case we call it with the
    #  filehandle to allow caller to fill in the file
    my ($dir, $base, $ext) =
        $fn =~ m,^( (?: .*/ )? )( [^/]+? )( (?: \.[^./]+ )? )$,x
        or die "$fn ?";
    my $real= "$dir$base--osstest$ext";
    my $linktarg= "$base--osstest$ext";

    unlink $real or $!==&ENOENT or die "$real $!";
    my $flc= new IO::File "$real",'w' or die "$real $!";
    if (ref $contents eq 'CODE') {
        $contents->($flc);
    } else {
        print $flc $contents or die "$real $!";
    }
    close $flc or die "$real $!";

    my $newlink= "$dir$base--newlink$ext";

    if (!lstat "$fn") {
        $!==&ENOENT or die "$fn $!";
    } elsif (!-l _) {
        die "$fn not a symlink";
        unlink $fn or die "$fn $!";
    }
    symlink $linktarg, $newlink or die "$newlink $!";
    rename $newlink, $fn or die "$newlink $fn $!";
    logm("wrote $fn");
}

sub setup_pxeboot ($$) {
    my ($ho, $bootfile) = @_;
    my $dir= $ho->{Ether};
    $dir =~ y/A-Z/a-z/;
    $dir =~ y/0-9a-f//cd;
    length($dir)==12 or die "$dir";
    $dir =~ s/../$&-/g;
    $dir =~ s/\-$//;
    file_link_contents($c{Tftp}."/$dir/pxelinux.cfg", $bootfile);
}

sub setup_pxeboot_local ($) {
    my ($ho) = @_;
    setup_pxeboot($ho, <<END);
serial 0 $c{Baud}
timeout 5
label local
	LOCALBOOT 0
default local
END
}

sub await_webspace_fetch_byleaf ($$$$$) {
    my ($maxwait,$interval,$logtailer, $ho, $url) = @_;
    my $leaf= $url;
    $leaf =~ s,.*/,,;
    poll_loop($maxwait,$interval, "fetch $leaf", sub {
        my ($line, $last);
        $last= '(none)';
        while (defined($line= $logtailer->getline())) {
            my ($ip, $got) = $line =~
                m,^([0-9.]+) \S+ \S+ \[[^][]+\] \"GET \S*/(\S+) ,
                or next;
            next unless $ip eq $ho->{Ip};
            $last= $got;
            next unless $got eq $leaf;
            return undef;
        }
        return $last;
    });
}

sub await_sshd ($$$) {
    my ($maxwait,$interval,$ho) = @_;
    poll_loop($maxwait,$interval, "await sshd", sub {
        my $ncout= `nc -n -v -z -w $interval $ho->{Ip} 22 2>&1`;
        return undef if !$?;
        $ncout =~ s/\n/ | /g;
        return "nc: $? $ncout";
    });
}

sub create_webfile ($$$) {
    my ($ho, $tail, $contents) = @_; # $contents as for file_link_contents
    my $wf_common= $c{WebspaceCommon}.$ho->{Name}."_".$tail;
    my $wf_url= $c{WebspaceUrl}.$wf_common;
    my $wf_file= $c{WebspaceFile}.$wf_common;
    file_link_contents($wf_file, $contents);
    return $wf_url;
}

sub get_filecontents ($;$) {
    my ($path, $ifnoent) = @_;  # $ifnoent=undef => is error
    if (!open GFC, '<', $path) {
        $!==&ENOENT or die "$path $!";
        die "$path does not exist" unless defined $ifnoent;
        logm("read $path absent.");
        return $ifnoent;
    }
    local ($/);
    undef $/;
    my $data= <GFC>;
    defined $data or die "$path $!";
    close GFC or die "$path $!";
    logm("read $path ok.");
    return $data;
}

package Osstest::Logtailer;
use Fcntl qw(:seek);

sub new ($$) {
    my ($class, $fn) = @_;
    my $fh= new IO::File $fn,'r';
    my $ino= -1;
    if (!$fh) {
        $!==&ENOENT or die "$fn $!";
    } else {
        seek $fh, 0, SEEK_END or die "$fn $!";
        stat $fh or die "$fn $!";
        $ino= (stat _)[1];
    }
    my $lt= { Path => $fn, Handle => $fh, Ino => $ino, Buf => '' };
    bless $lt, $class;
    return $lt;
}

sub getline ($) {
    my ($lt) = @_;

    for (;;) {
        if ($lt->{Buf} =~ s/^(.*)\n//) {
            return $1;
        }

        if ($lt->{Handle}) {
            seek $lt->{Handle}, 0, SEEK_CUR or die "$lt->{Path} $!";

            my $more;
            my $got= read $lt->{Handle}, $more, 4096;
            die "$lt->{Path} $!" unless defined $got;
            if ($got) {
                $lt->{Buf} .= $more;
                next;
            }
        }

        if (!stat $lt->{Path}) {
            $!==&ENOENT or die "$lt->{Path} $!";
            return undef;
        }
        my $nino= (stat _)[1];
        return undef
            unless $nino != $lt->{Ino};

        my $nfh= new IO::File $lt->{Path},'r';
        if (!$nfh) {
            $!==&ENOENT or die "$lt->{Path} $!";
            warn "newly-created $lt->{Path} vanished again";
            return undef;
        }
        stat $nfh or die $!;
        $nino= (stat _)[1];

        $lt->_close();
        $lt->{Handle}= $nfh;
        $lt->{Ino}= $nino;
    }
}        

sub _close ($) {
    my ($lt) = @_;
    if ($lt->{Handle}) {
        close $lt->{Handle} or die "$lt->{Path} $!";
        $lt->{Handle}= undef;
        $lt->{Ino}= -1;
    }
}

sub close ($) {
    my ($lt) = @_;
    $lt->_close();
    $lt->{Buf}= '';
}

sub DESTROY ($) {
    my ($lt) = @_;
    local $!;
    $lt->_close();
}

1;
