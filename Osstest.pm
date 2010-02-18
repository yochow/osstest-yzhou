
package Osstest;

use strict;
use warnings;

use POSIX;
use IO::File;
use DBI;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      $tftptail
                      %c %r $dbh_state $dbh_tests $flight $job $stash
                      get_runvar get_runvar_maybe store_runvar get_stashed
                      built_stash
                      csreadconfig
                      readconfig opendb_state selecthost need_runvars
                      get_filecontents ensuredir postfork db_retry
                      poll_loop logm link_file_contents create_webfile
                      power_state power_cycle
                      setup_pxeboot setup_pxeboot_local
                      await_webspace_fetch_byleaf await_tcp
                      target_cmd_root target_cmd target_cmd_build
                      target_cmd_output_root target_cmd_output
                      target_getfile target_getfile_root
                      target_putfile target_putfile_root
                      target_editfile_root
                      target_install_packages target_install_packages_norec
                      target_reboot target_reboot_hard
                      target_choose_vg target_umount_lv
                      target_ping_check_down target_ping_check_up
                      target_kernkind_check target_kernkind_console_inittab
                      target_var target_var_prefix
                      selectguest prepareguest
                      guest_umount_lv guest_await guest_await_dhcp_tcp
                      guest_checkrunning guest_check_ip guest_find_ether
                      guest_find_domid
                      guest_vncsnapshot_begin guest_vncsnapshot_stash
                      hg_dir_revision git_dir_revision vcs_dir_revision
                      store_revision store_vcs_revision
                      toolstack
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $tftptail= '/spider/pxelinux.cfg';

our (%c,%r,$flight,$job,$stash);
our $dbh_state;
our $dbh_tests;

our %timeout= qw(RebootDown   100
                 RebootUp     200
                 HardRebootUp 300);

sub csreadconfig () {
    require 'config.pl';
    $dbh_tests= opendb('osstestdb');
}

sub readconfig () {
    csreadconfig();

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

    my $now= time;  defined $now or die $!;
    $dbh_tests->do(<<END);
        UPDATE flights SET started=$now WHERE flight=$flight AND started=0
END

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

sub db_retry ($$) {
    my ($dbh, $code) = @_;
    my $retries= 20;
    my $r;
    for (;;) {
        $dbh->begin_work();
        $r= &$code;
        last if eval { $dbh->commit(); 1; };
        die "$dbh $code $@ ?" unless $retries-- > 0;
        sleep(1);
    }
    return $r;
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
    my $whoami= `whoami`;  chomp $whoami;
    my $dbh= DBI->connect($src, $whoami,'', {
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
    my ($timeout,$stdout,@cmd) = @_;
    my $child= fork;  die $! unless defined $child;
    if (!$child) {
        if (defined $stdout) {
            open STDOUT, '>&', $stdout
                or die "STDOUT $stdout $cmd[0] $!";
        }
        exec @cmd;
        die "$cmd[0]: $!";
    }
    my $r;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n"; };
        alarm($timeout);
        $r= waitpid $child, 0;
        alarm(0);
    };
    if ($@) {
        die unless $@ eq "alarm\n";
        logm("command timed out [$timeout]: @cmd");
        return '(timed out)';
    }
    die "$r $child $!" unless $r == $child;
    logm("command nonzero waitstatus $?: @cmd") if $?;
    return $?;
}

sub sshuho ($$) { my ($user,$ho)= @_; return "$user\@$ho->{Ip}"; }

sub sshopts () {
    return [ qw(-o UserKnownHostsFile=known_hosts) ];
}

sub tcmdex {
    my ($timeout,$stdout,$cmd,$optsref,@args) = @_;
    logm("executing $cmd ... @args");
    my $r= cmd($timeout,$stdout, $cmd,@$optsref,@args);
    $r and die "status $r";
}

sub tgetfileex {
    my ($ruser, $ho,$timeout, $rsrc,$ldst) = @_;
    tcmdex($timeout,undef,
           'scp', sshopts(),
           sshuho($ruser,$ho).":$rsrc", $ldst);
} 
sub target_getfile ($$$$) {
    my ($ho,$timeout, $rsrc,$ldst) = @_;
    tgetfileex('osstest', @_);
}
sub target_getfile_root ($$$$) {
    my ($ho,$timeout, $rsrc,$ldst) = @_;
    tgetfileex('root', @_);
}

sub tputfileex {
    my ($ruser, $ho,$timeout, $lsrc,$rdst, $rsync) = @_;
    my @args= ($lsrc, sshuho($ruser,$ho).":$rdst");
    if (!defined $rsync) {
        tcmdex($timeout,undef,
               'scp', sshopts(),
               @args);
    } else {
        unshift @args, $rsync if length $rsync;
        tcmdex($timeout,undef,
               'rsync', [ '-e', 'ssh '.join(' ',@{ sshopts() }) ],
               @args);
    }
}    
sub target_putfile ($$$$;$) {
    tputfileex('osstest', @_);
}
sub target_putfile_root ($$$$;$) {
    tputfileex('root', @_);
}
sub target_install_packages {
    my ($ho, @packages) = @_;
    target_cmd_root($ho, "apt-get -y install @packages", 100 * @packages);
}
sub target_install_packages_norec {
    my ($ho, @packages) = @_;
    target_cmd_root($ho,
                    "apt-get --no-install-recommends -y install @packages",
                    100 * @packages);
}

sub target_editfile_root ($$$;$$) {
    my $code= pop @_;
    my ($ho,$rfile,$lleaf,$rdest) = @_;

    if (!defined $rdest) {
        $rdest= $rfile;
    }
    if (!defined $lleaf) {
        $lleaf= $rdest;
        $lleaf =~ s,.*/,,;
    }
    my $lfile;
    
    for (;;) {
        $lfile= "$stash/$lleaf";
        if (!lstat $lfile) {
            $! == &ENOENT or die "$lfile $!";
            last;
        }
        $lleaf .= '+';
    }
    if ($rdest eq $rfile) {
        logm("editing $rfile as $lfile".'{,.new}');
    } else {
        logm("editing $rfile to $rdest as $lfile".'{,.new}');
    }

    target_getfile($ho, 60, $rfile, $lfile);
    open '::EI', "$lfile" or die "$lfile: $!";
    open '::EO', "> $lfile.new" or die "$lfile.new: $!";

    &$code;

    '::EI'->error and die $!;
    close '::EI' or die $!;
    close '::EO' or die $!;
    target_putfile_root($ho, 60, "$lfile.new", $rdest);
}

sub target_cmd_build ($$$$) {
    my ($ho,$timeout,$builddir,$script) = @_;
    target_cmd($ho, <<END.$script, $timeout);
	set -xe
        LC_ALL=C; export LC_ALL
        PATH=/usr/lib/ccache:\$PATH
        cd $builddir
END
}

sub target_ping_check_core {
    my ($ho, $exp) = @_;
    my $out= `ping -c 5 $ho->{Ip} 2>&1`;
    $out =~ s/\b\d+(?:\.\d+)?ms\b/XXXms/g;
    report_once($ho, 'ping_checka',
		"ping $ho->{Ip} ".(!$? ? 'up' : $?==256 ? 'down' : "$? ?"));
    return undef if $?==$exp;
    $out =~ s/\n/ | /g;
    return "ping gave ($?): $out";
}
sub target_ping_check_down ($) { return target_ping_check_core(@_,256); }
sub target_ping_check_up ($) { return target_ping_check_core(@_,0); }

sub target_reboot ($) {
    my ($ho) = @_;
    target_cmd_root($ho, "init 6");
    poll_loop($timeout{RebootDown},5,'reboot-down', sub {
        return target_ping_check_down($ho);
    });
    await_tcp($timeout{RebootUp},5,$ho);
}

sub target_reboot_hard ($) {
    my ($ho) = @_;
    power_cycle($ho);
    await_tcp($timeout{HardRebootUp},5,$ho);
}

sub store_revision ($$$) {
    my ($ho,$which,$dir) = @_;
    my $vcs= target_cmd_output($ho, <<END);
        set -e; cd $dir
        (test -d .git && echo git) ||
        (test -d .hg && echo hg) ||
        (echo >&2 'unable to determine vcs'; fail)
END
    my $rev= vcs_dir_revision($ho,$dir,$vcs);
    store_vcs_revision($which,$rev,$vcs);
}

sub store_vcs_revision ($$$) {
    my ($which,$rev,$vcs) = @_;
    store_runvar("built_vcs_$which", $vcs);
    store_runvar("built_revision_$which", $rev);
}

sub store_runvar ($$) {
    my ($param,$value) = @_;
    logm("runvar store: $param=$value");
    $dbh_tests->do(<<END, undef, $flight, $job, $param);
	DELETE FROM runvars WHERE flight=? AND job=? AND name=? AND synth
END
    my $q= $dbh_tests->prepare(<<END);
        INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    $q->execute($flight,$job, $param,$value);
    $r{$param}= get_runvar($param, "$flight.$job");
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

sub tcmd { # $tcmd will be put between '' but not escaped
    my ($stdout,$user,$ho,$tcmd,$timeout) = @_;
    $timeout=10 if !defined $timeout;
    tcmdex($timeout,$stdout,
           'ssh', sshopts(),
           sshuho($user,$ho), $tcmd);
}
sub target_cmd ($$;$) { tcmd(undef,'osstest',@_); }
sub target_cmd_root ($$;$) { tcmd(undef,'root',@_); }

sub tcmdout {
    my $stdout= IO::File::new_tmpfile();
    tcmd($stdout,@_);
    $stdout->seek(0,0) or die "$stdout $!";
    my $r;
    { local ($/) = undef;
      $r= <$stdout>; }
    die "$stdout $!" if !defined $r or $stdout->error or !close $stdout;
    chomp($r);
    return $r;
}

sub target_cmd_output ($$;$) { tcmdout('osstest',@_); }
sub target_cmd_output_root ($$;$) { tcmdout('root',@_); }

sub target_choose_vg ($$) {
    my ($ho, $mbneeded) = @_;
    my $vgs= target_cmd_output_root($ho, 'vgdisplay --colon');
    my $bestkb= 1e9;
    my $bestvg;
    foreach my $l (split /\n/, $vgs) {
        $l =~ s/^\s+//; $l =~ s/\s+$//;
        my @l= split /\:/, $l;
        my $tvg= $l[0];
        my $tkb= $l[11];
        if ($tkb < $mbneeded*1024) {
            logm("vg $tvg ${tkb}kb free - too small");
            next;
        }
        if ($tkb < $bestkb) {
            $bestvg= $tvg;
            $bestkb= $tkb;
        }
    }
    die "no vg of sufficient size"
        unless defined $bestvg;
    logm("vg $bestvg ${bestkb}kb free - will use");
    return $bestvg;
}

sub opendb_state () {
    $dbh_state= opendb('statedb');
}
sub selecthost ($) {
    my ($name) = @_;
    my $ho= {
        Name => $name,
        TcpCheckPort => 22,
    };
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

sub guest_find_tcpcheckport ($) {
    my ($gho) = @_;
    $gho->{TcpCheckPort}= $r{"$gho->{Guest}_tcpcheckport"};
    $gho->{PingBroken}= $r{"$gho->{Guest}_pingbroken"};
}

sub selectguest ($) {
    my ($gn) = @_;
    my $gho= {
        Guest => $gn,
        Name => $r{"${gn}_hostname"}
    };
    guest_find_lv($gho);
    guest_find_ether($gho);
    guest_find_tcpcheckport($gho);
    return $gho;
}

sub guest_find_lv ($) {
    my ($gho) = @_;
    my $gn= $gho->{Guest};
    $gho->{Vg}= $r{"${gn}_vg"};
    $gho->{Lv}= $r{"${gn}_disk_lv"};
    $gho->{Lvdev}= (defined $gho->{Vg} && defined $gho->{Lv})
        ? '/dev/'.$gho->{Vg}.'/'.$gho->{Lv} : undef;
}

sub guest_find_ether ($) {
    my ($gho) = @_;
    $gho->{Ether}= $r{"$gho->{Guest}_ether"};
}

sub report_once ($$$) {
    my ($ho, $what, $msg) = @_;
    my $k= "Lastmsg_$what";
    return if defined($ho->{$k}) and $ho->{$k} eq $msg;
    logm($msg);
    $ho->{$k}= $msg;
}

sub guest_check_ip ($) {
    my ($gho) = @_;

    guest_find_ether($gho);
    
    my $q= $dbh_state->prepare('select * from ips where mac=?');
    $q->execute($gho->{Ether});
    my $row;
    my $worst= "no entry in statedb::ips";
    my @ips;
    while ($row= $q->fetchrow_hashref()) {
        if (!$row->{state}) {
            $worst= "statedb::ips.state=$row->{state}";
            next;
        }
        push @ips, $row->{ip};
    }
    if (!@ips) {
        return $worst;
    }
    if (@ips>1) {
        return "multiple addrs @ips";
    }
    $gho->{Ip}= $ips[0];
    $gho->{Ip} =~ m/^[0-9.]+$/ or
        die "$gho->{Name} $gho->{Ether} $gho->{Ip} ?";
    report_once($gho, 'guest_check_ip', 
		"guest $gho->{Name}: $gho->{Ether} $gho->{Ip}");

    return undef;
}

sub select_ether ($) {
    my ($vn) = @_;
    my $ether= $r{$vn};
    return $ether if defined $ether;
    my $prefix= sprintf "%s:%02x", $c{GenEtherPrefix}, $flight & 0xff;
    db_retry($dbh_tests, sub {
        my $previous= $dbh_tests->selectrow_array(<<END, {}, $flight,$job);
            SELECT max(val) FROM runvars WHERE flight=? AND job=?
                AND name LIKE '%_ether'
                AND val LIKE '$prefix:%'
END
        if (defined $previous) {
            $previous =~ m/^\w+:\w+:\w+:\w+:([0-9a-f]+):([0-9a-f]+)$/i
                or die "$previous ?";
            my $val= (hex($1)<<8) | hex($2);
            $val++;  $val &= 0xffff;
            $ether= sprintf "%s:%02x:%02x", $prefix, $val >> 8, $val & 0xff;
            logm("select_ether $prefix:... $ether (previous $previous)");
        } else {
            $ether= "$prefix:00:01";
            logm("select_ether $prefix:... $ether (first in flight)");
        }
        $dbh_tests->do(<<END, {}, $flight,$job,$vn,$ether);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    $r{$vn}= $ether;
    return $ether;
}

sub prepareguest ($$$$$) {
    my ($ho, $gn, $hostname, $tcpcheckport, $mb) = @_;

    select_ether("${gn}_ether");
    store_runvar("${gn}_hostname", $hostname);
    store_runvar("${gn}_disk_lv", $r{"${gn}_hostname"}.'-disk');
    store_runvar("${gn}_tcpcheckport", $tcpcheckport);
    
    my $gho= selectguest($gn);
    store_runvar("${gn}_domname", $gho->{Name});

    store_runvar("${gn}_vg", '');
    if (!length $r{"${gn}_vg"}) {
        store_runvar("${gn}_vg", target_choose_vg($ho, $mb));
    }

    guest_find_lv($gho);
    guest_find_ether($gho);
    guest_find_tcpcheckport($gho);
    return $gho;
}

sub guest_checkrunning ($$) {
    my ($ho,$gho) = @_;
    my $domains= target_cmd_output_root($ho, toolstack()->{Command}." list");
    $domains =~ s/^Name.*\n//;
    foreach my $l (split /\n/, $domains) {
        $l =~ m/^(\S+)\s/ or die "$l ?";
        return 1 if $1 eq $gho->{Name};
    }
    return 0;
}

sub guest_await_dhcp_tcp ($$) {
    my ($gho,$timeout) = @_;
    guest_find_tcpcheckport($gho);
    poll_loop($timeout,1,
              "guest $gho->{Name} $gho->{Ether} $gho->{TcpCheckPort}".
              " link/ip/tcp",
              sub {
        my $err= guest_check_ip($gho);
        return $err if defined $err;

        return
            ($gho->{PingBroken} ? undef : target_ping_check_up($gho))
            ||
            target_tcp_check($gho,5)
            ||
            undef;
    });
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
    my $reported= '';
    for (;;) {
        my $bad= $code->();
        my $now= time;  die $! unless defined $now;
        $waited= $now - $start;
        last if !defined $bad;
	if ($reported ne $bad) {
	    logm("$what: $bad (waiting) ...");
	    $reported= $bad;
	}
        $waited <= $maxwait or die "$what: wait timed out: $bad.\n";
        $wantwaited += $interval;
        my $needwait= $wantwaited - $waited;
        sleep($needwait) if $needwait > 0;
    }
    logm("$what: ok. (${waited}s)");
}

sub power_cycle ($) {
    my ($ho) = @_;
    power_state($ho, 0);
    sleep(1);
    power_state($ho, 1);
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
    my @t = localtime;
    printf "%04d-%02d-%02d %02d:%02d:%02d Z %s\n",
        $t[5]+1900,$t[4],$t[3], $t[2],$t[1],$t[0],
        $m
    or die $!;
    STDOUT->flush or die $!;
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

sub target_umount_lv ($$$) {
    my ($ho,$vg,$lv) = @_;
    my $dev= "/dev/$vg/$lv";
    for (;;) {
        $lv= target_cmd_output_root($ho, "lvdisplay --colon $dev");
        $lv =~ s/^\s+//;  $lv =~ s/\s+$//;
        my @lv = split /:/, $lv;
        die "@lv ?" unless $lv[0] eq $dev;
        return unless $lv[5]; # "open"
        target_cmd_root($ho, "umount $dev");
    }
}

sub guest_umount_lv ($$) {
    my ($ho,$gho) = @_;
    target_umount_lv($ho, $gho->{Vg}, $gho->{Lv});
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

sub target_tcp_check ($$) {
    my ($ho,$interval) = @_;
    my $ncout= `nc -n -v -z -w $interval $ho->{Ip} $ho->{TcpCheckPort} 2>&1`;
    return undef if !$?;
    $ncout =~ s/\n/ | /g;
    return "nc: $? $ncout";
}

sub await_tcp ($$$) {
    my ($maxwait,$interval,$ho) = @_;
    poll_loop($maxwait,$interval,
              "await tcp $ho->{Name} $ho->{TcpCheckPort}",
              sub {
        return target_tcp_check($ho,$interval);
    });
}

sub guest_await ($$) {
    my ($gho,$dhcpwait) = @_;
    guest_await_dhcp_tcp($gho,$dhcpwait);
    target_cmd_root($gho, "echo guest $gho->{Name}: ok");
    return $gho;
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

sub built_stash ($$$$) {
    my ($ho, $builddir, $distroot, $item) = @_;
    target_cmd($ho, <<END, 300);
	set -xe
	cd $builddir
        cd $distroot
        tar zcf $builddir/$item.tar.gz *
END
    my $build= "build";
    my $stashleaf= "$build/$item.tar.gz";
    ensuredir("$stash/$build");
    target_getfile($ho, 300,
                   "$builddir/$item.tar.gz",
                   "$stash/$stashleaf");
    store_runvar("path_$item", $stashleaf);
}

sub vcs_dir_revision ($$$) {
    my ($ho,$builddir,$vcs) = @_;
    no strict qw(refs);
    return &{"${vcs}_dir_revision"}($ho,$builddir);
}

sub hg_dir_revision ($$) {
    my ($ho,$builddir) = @_;
    my $rev= target_cmd_output($ho, "cd $builddir && hg identify -ni", 100);
    $rev =~ m/^([0-9a-f]{10,}\+?) (\d+\+?)$/ or die "$builddir $rev ?";
    return "$2:$1";
}

sub git_dir_revision ($$) {
    my ($ho,$builddir) = @_;
    my $rev= target_cmd_output($ho, "cd $builddir && git-rev-parse HEAD");
    $rev =~ m/^([0-9a-f]{10,})$/ or die "$builddir $rev ?";
    return "$1";
}

sub guest_kernkind_check ($) {
    my ($gho) = @_;
    target_process_kernkind("$gho->{Guest}_");
}    

sub target_var_prefix ($) {
    my ($ho) = @_;
    if (exists $ho->{Guest}) { return $ho->{Guest}.'_'; }
    return '';
}

sub target_var ($$) {
    my ($ho,$vn) = @_;
    return $r{ target_var_prefix($ho). $vn };
}

sub target_kernkind_check ($) {
    my ($gho) = @_;
    my $pfx= target_var_prefix($gho);
    my $kernkind= $r{$pfx."kernkind"};
    if (exists $gho->{Guest}) {
	if ($kernkind eq 'pvops') {
	    store_runvar($pfx."rootdev", 'xvda');
	    store_runvar($pfx."console", 'hvc0');
	} elsif ($kernkind !~ m/2618/) {
	    store_runvar($pfx."console", 'xvc0');
	}
    }
}

sub target_kernkind_console_inittab ($$$) {
    my ($ho, $gho, $root) = @_;

    my $inittabpath= "$root/etc/inittab";
    my $console= target_var($gho,'console');

    if (length $console) {
        target_cmd_root($ho, <<END);
            set -ex
            perl -i~ -ne "
                next if m/^xc:/;
                print \\\$_ or die \\\$!;
                next unless s/^1:/xc:/;
                s/tty1/$console/;
                print \\\$_ or die \\\$!;
            " $inittabpath
END
    }
    return $console;
}

sub guest_find_domid ($$) {
    my ($ho,$gho) = @_;
    return if defined $gho->{Domid};
    my $list= target_cmd_output_root($ho, "xm list $gho->{Name}");
    $list =~ m/^(?!Name\s)(\S+)\s+(\d+).*$/m
        or die "domain list: $list";
    $1 eq $gho->{Name} or die "domain list name $1 expected $gho->{Name}";
    $gho->{Domid}= $2;
}

sub guest_vncsnapshot_begin ($$) {
    my ($ho,$gho) = @_;
    my $domid= $gho->{Domid};

    my $backend= target_cmd_output_root($ho,
        "xenstore-read /local/domain/$domid/device/vfb/0/backend");
    $backend =~ m,^/local/domain/\d+/backend/vfb/\d+/\d+$,
        or die "$backend ?";

    my $v = {};
    foreach my $k (qw(vnclisten vncdisplay)) {
        $v->{$k}= target_cmd_output_root($ho,
                "xenstore-read $backend/$k");
    }
    return $v;
}
sub guest_vncsnapshot_stash ($$$$) {
    my ($ho,$gho,$v,$leaf) = @_;
    my $rfile= "/root/$leaf";
    target_cmd_root($ho,
        "vncsnapshot -passwd $gho->{Guest}.vncpw".
                   " -nojpeg".
                   " $v->{vnclisten}:$v->{vncdisplay}".
                   " $rfile", 100);
    target_getfile_root($ho,100, "$rfile", "$stash/$leaf");
}

our %toolstacks=
    ('xend' => {
        DaemonInitd => 'xend',
        Command => 'xm',
        CfgPathVar => 'cfgpath',
        },
     'xl' => {
        DaemonInitd => 'xenlightdaemons',
        SeparateBridgeInitd => 1,
        Dom0MemFixed => 1,
        Command => 'xl',
        CfgPathVar => 'xlpath',
	RestoreNeedsConfig => 1,
        }
     );

sub toolstack () {
    my $tsname= $r{toolstack};
    $tsname= 'xend' if !defined $tsname;
    my $ts= $toolstacks{$tsname};
    die "$tsname ?" unless defined $ts;
    if (!exists $ts->{Name}) {
        logm("toolstack $tsname");
        $ts->{Name}= $tsname;
    }
    return $ts;
}

package Osstest::Logtailer;
use Fcntl qw(:seek);
use POSIX;

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
