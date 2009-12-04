
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
                      %c %r $dbh_state $dbh_tests $flight $job $stash
                      get_runvar get_runvar_maybe store_runvar get_stashed
                      readconfig opendb_state selecthost need_runvars
                      get_filecontents ensuredir postfork
                      poll_loop logm link_file_contents create_webfile
                      power_state
                      setup_pxeboot setup_pxeboot_local
                      await_webspace_fetch_byleaf await_sshd
                      target_cmd_root target_cmd
                      target_getfile target_putfile target_putfile_root
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $tftptail= '/spider/pxelinux.cfg';

our (%c,%r,$flight,$job,$stash);
our $dbh_state;
our $dbh_tests;

sub readconfig () {
    require 'config.pl';
    $dbh_tests= opendb('osstestdb');
    $flight= $ENV{'OSSTEST_FLIGHT'};
    $job=    $ENV{'OSSTEST_JOB'};
    die unless defined $flight and defined $job;
    my $q= $dbh_tests->prepare(<<END);
        SELECT count(*) FROM jobs WHERE flight=? AND job=?
END
    $q->execute($flight, $job);
    my ($count) = $q->fetchrow_array();
    die "$flight.$job $count" unless $count==1;
    $q->finish;
    logm("starting $flight.$job");

    $q= $dbh_tests->prepare(<<END);
        SELECT name, val FROM runvars WHERE flight=? AND job=?
END
    $q->execute($flight, $job);
    my $row;
    while ($row= $q->fetchrow_hashref()) {
        $r{ $row->{name} }= $row->{val};
        logm("setting $row->{name}=$row->{val}");
    }
    $q->finish();

    $stash= "$c{Stash}/$flight.$job";
    ensuredir($stash);
}

sub otherflightjob ($) {
    my ($otherflightjob) = @_;    
    return $otherflightjob =~ m/^([^.]+)\.([^.]+)$/ ? ($1,$2) :
           $otherflightjob =~ m/^\.?([^.]+)$/ ? ($flight,$1) :
           die "$otherflightjob ?";
}

sub get_stashed ($$) {
    my ($param, $otherflightjob) = @_; 
    my ($oflight, $ojob) = otherflightjob($otherflightjob);
    my $path= get_runvar($param, $otherflightjob);
    die "$path $& " if
        $path =~ m,[^-+._0-9a-zA-Z/], or
        $path =~ m/\.\./;
    return "$c{Stash}/$oflight.$ojob/$path";
}

sub ensuredir ($) {
    my ($dir)= @_;
    mkdir($dir) or $!==&EEXIST or die "$dir $!";
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

sub cmd {
    my ($timeout,@cmd) = @_;
    my $child= fork;  die $! unless defined $child;
    if (!$child) { exec @cmd; die "$cmd[0]: $!"; }
    my $r;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n"; };
        alarm($timeout);
        $r= waitpid $child, 0;
        alarm(0);
    };
    if ($@) {
        die unless $@ eq "alarm\n";
        return '(timed out)';
    }
    die "$r $child $!" unless $r == $child;
    return $?;
}

sub sshuho ($$) { my ($user,$ho)= @_; return "$user\@$ho->{Ip}"; }

sub tcmdex {
    my ($timeout,$cmd,@args) = @_;
    my @opts= qw(-o UserKnownHostsFile=known_hosts);
    logm("executing $cmd ... @args");
    my $r= cmd($timeout, $cmd,@opts,@args);
    $r and die "status $r";
}

sub tcmd { # $tcmd will be put between '' but not escaped
    my ($user,$ho,$tcmd,$timeout) = @_;
    $timeout=10 if !defined $timeout;
    tcmdex($timeout,
           'ssh',
           sshuho($user,$ho), $tcmd);
}

sub target_getfile ($$$$) {
    my ($ho,$timeout, $rsrc,$ldst) = @_;
    tcmdex($timeout,
           'scp',
           sshuho('osstest',$ho).":$rsrc", $ldst);
}
sub target_putfile ($$$$) {
    my ($ho,$timeout, $lsrc,$rdst) = @_;
    tcmdex($timeout,
           'scp',
           $lsrc, sshuho('osstest',$ho).":$rdst");
}
sub target_putfile_root ($$$$) {
    my ($ho,$timeout, $lsrc,$rdst) = @_;
    tcmdex($timeout,
           'scp',
           $lsrc, sshuho('root',$ho).":$rdst");
}

sub store_runvar ($$) {
    my ($param,$value) = @_;
    logm("runvar store: $param=$value");
    $r{$param}= $value;
    my $q= $dbh_tests->prepare(<<END);
        INSERT INTO runvars VALUES (?,?,?,?)
END
    $q->execute($flight,$job, $param,$value);
}

sub get_runvar ($$$) {
    my ($param, $otherflightjob) = @_;
    my $r= get_runvar_maybe($param,$otherflightjob);
    die "need $param in $otherflightjob" unless defined $r;
    return $r;
}    
sub get_runvar_maybe ($$$) {
    my ($param, $otherflightjob) = @_;
    my ($oflight, $ojob) = otherflightjob($otherflightjob);
    my $q= $dbh_tests->prepare(<<END);
        SELECT val FROM runvars WHERE flight=? AND job=? AND name=?
END
    $q->execute($oflight,$ojob,$param);
    my $row= $q->fetchrow_arrayref();
    if (!$row) { $q->finish(); return undef; }
    my ($val)= @$row;
    die "$oflight.$ojob $param" if $q->fetchrow_arrayref();
    $q->finish();
    return $val;
}

sub target_cmd ($$;$) { tcmd('osstest',@_); }
sub target_cmd_root ($$;$) { tcmd('root',@_); }

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

sub need_runvars {
    my @missing= grep { !defined $r{$_} } @_;
    return unless @missing;
    die "missing runvars @missing ";
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
