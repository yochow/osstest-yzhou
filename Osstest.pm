
package Osstest;

use strict;
use warnings;

use POSIX;
use IO::File;
use DBI;
use Socket;
use IPC::Open2;
use IO::Handle;

# DATABASE TABLE LOCK HIERARCHY
#
#  Lock first
#
#   flights
#            must be locked for any query modifying
#                   flights_flight_seq
#                   flights_harness_touched
#                   jobs
#                   steps
#                   runvars
#
#   resources
#            must be locked for any query modifying
#                   tasks
#                   tasks_taskid_seq
#                   resource_sharing 
#                   hostflags
#
#   any other tables or databases
#
our (@all_lock_tables) = qw(flights resources);
#
#  Lock last
#
# READS:
#
#  Nontransactional reads are also permitted
#  Transactional reads must take out locks as if they were modifying


BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      $tftptail
                      %c %r $dbh_tests $flight $job $stash
                      dbfl_check
                      get_runvar get_runvar_maybe get_runvar_default
                      store_runvar get_stashed
                      unique_incrementing_runvar system_checked
                      tcpconnect findtask @all_lock_tables
                      alloc_resources alloc_resources_rollback_begin_work
                      resource_check_allocated resource_shared_mark_ready
                      built_stash flight_otherjob
                      csreadconfig ts_get_host_guest
                      readconfig opendb_state selecthost get_hostflags
                      need_runvars
                      get_filecontents ensuredir postfork
                      db_retry db_begin_work
                      poll_loop logm link_file_contents create_webfile
                      power_state power_cycle
                      setup_pxeboot setup_pxeboot_local
                      await_webspace_fetch_byleaf await_tcp
                      remote_perl_script_open remote_perl_script_done
                      target_cmd_root target_cmd target_cmd_build
                      target_cmd_output_root target_cmd_output
                      target_getfile target_getfile_root
                      target_putfile target_putfile_root
		      target_putfilecontents_root_stash
                      target_editfile_root target_file_exists
                      target_install_packages target_install_packages_norec
                      host_reboot host_pxedir target_reboot target_reboot_hard
                      target_choose_vg target_umount_lv target_await_down
                      target_ping_check_down target_ping_check_up
                      target_kernkind_check target_kernkind_console_inittab
                      target_var target_var_prefix
                      selectguest prepareguest more_prepareguest_hvm
                      guest_umount_lv guest_await guest_await_dhcp_tcp
                      guest_checkrunning guest_check_ip guest_find_ether
                      guest_find_domid guest_check_up
                      guest_vncsnapshot_begin guest_vncsnapshot_stash
		      guest_check_remus_ok
                      dir_identify_vcs build_clone
                      hg_dir_revision git_dir_revision vcs_dir_revision
                      store_revision store_vcs_revision
                      toolstack
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $tftptail= '/spider/pxelinux.cfg';

our (%c,%r,$flight,$job,$stash);
our $dbh_tests;

our %timeout= qw(RebootDown   100
                 RebootUp     400
                 HardRebootUp 600);

#---------- configuration reader etc. ----------

sub opendb_tests () {
    $dbh_tests ||= opendb('osstestdb');
}

sub csreadconfig () {
    require 'config.pl';
    foreach my $v (keys %c) {
	my $e= $ENV{"OSSTEST_C_$v"};
	next unless defined $e;
	$c{$v}= $e;
    }
    opendb_tests();
}

sub dbfl_check ($$) {
    my ($fl,$flok) = @_;
    # must be inside db_retry qw(flights)

    if (!ref $flok) {
        $flok= [ split /,/, $flok ];
    }
    die unless ref($flok) eq 'ARRAY';

    my ($bless) = $dbh_tests->selectrow_array(<<END, {}, $fl);
        SELECT blessing FROM flights WHERE flight=?
END

    die "modifying flight $fl but flight not found\n"
        unless defined $bless;
    return if $bless =~ m/\bplay\b/;
    die "modifying flight $fl blessing $bless expected @$flok\n"
        unless grep { $_ eq $bless } @$flok;

    $!=0; $?=0; my $rev= `git-rev-parse HEAD`; die "$? $!" unless defined $rev;
    $rev =~ s/\n$//;
    die "$rev ?" unless $rev =~ m/^[0-9a-f]+$/;
    my $diffr= system 'git-diff --exit-code HEAD >/dev/null';
    if ($diffr) {
        die "$diffr $! ?" if $diffr != 256;
        $rev .= '+';
    }

    my $already= $dbh_tests->selectrow_hashref(<<END, {}, $fl,$rev);
        SELECT * FROM flights_harness_touched WHERE flight=? AND harness=?
END

    if (!$already) {
        $dbh_tests->do(<<END, {}, $fl,$rev);
            INSERT INTO flights_harness_touched VALUES (?,?)
END
    }
}

#---------- test script startup ----------

sub readconfig () {
    # must be run outside transaction
    csreadconfig();

    $flight= $ENV{'OSSTEST_FLIGHT'};
    $job=    $ENV{'OSSTEST_JOB'};
    die unless defined $flight and defined $job;

    my $now= time;  defined $now or die $!;

    db_retry($flight,[qw(running constructing)],
             $dbh_tests,[qw(flights)], sub {
        my ($count) = $dbh_tests->selectrow_array(<<END,{}, $flight, $job);
            SELECT count(*) FROM jobs WHERE flight=? AND job=?
END
        die "$flight.$job $count" unless $count==1;

        $count= $dbh_tests->do(<<END);
           UPDATE flights SET blessing='running'
               WHERE flight=$flight AND blessing='constructing'
END
        logm("starting $flight") if $count>0;

        $count= $dbh_tests->do(<<END);
           UPDATE flights SET started=$now
               WHERE flight=$flight AND started=0
END
        logm("starting $flight started=$now") if $count>0;

        undef %r;

        logm("starting $flight.$job");

        my $q= $dbh_tests->prepare(<<END);
            SELECT name, val FROM runvars WHERE flight=? AND job=?
END
        $q->execute($flight, $job);
        my $row;
        while ($row= $q->fetchrow_hashref()) {
            $r{ $row->{name} }= $row->{val};
            logm("setting $row->{name}=$row->{val}");
        }
        $q->finish();
    });

    $stash= "$c{Stash}/$flight/$job";
    ensuredir("$c{Stash}/$flight");
    ensuredir($stash);
}

sub ts_get_host_guest { # pass this @ARGV
    my ($gn,$whhost) = reverse @_;
    $whhost ||= 'host';
    $gn ||= 'guest';

    my $ho= selecthost($whhost);
    my $gho= selectguest($gn);
    return ($ho,$gho);
}

#---------- database access ----------#

our $db_retry_stop;

sub db_retry_abort () { $db_retry_stop= 'abort'; undef; }
sub db_retry_retry () { $db_retry_stop= 'retry'; undef; }

sub db_begin_work ($;$) {
    my ($dbh,$tables) = @_;
    $dbh->begin_work();
    foreach my $tab (@$tables) {
        $dbh->do("LOCK TABLE $tab IN ACCESS EXCLUSIVE MODE");
    }
}

sub db_retry ($$$;$$) {
    # $code should return whatever it likes, and that will
    #     be returned by db_retry
    my ($fl,$flok, $dbh,$tables,$code) = (@_==5 ? @_ :
                                          @_==3 ? (undef,undef,@_) :
                                          die);
    my $retries= 20;
    my $r;
    local $db_retry_stop;
    for (;;) {
        db_begin_work($dbh, $tables);
        if (defined $fl) {
            die unless $dbh eq $dbh_tests;
            dbfl_check($fl,$flok);
        }
        $db_retry_stop= 0;
        $r= &$code;
        if ($db_retry_stop) {
            $dbh->rollback();
            last if $db_retry_stop eq 'abort';
        } else {
            last if eval { $dbh->commit(); 1; };
        }
        die "$dbh $code $@ ?" unless $retries-- > 0;
        sleep(1);
    }
    return $r;
}

sub opendb_state () {
    return opendb('statedb');
}

sub opendb ($) {
    my ($dbname) = @_;

    my $src= "dbi:Pg:dbname=$dbname";
    my $fromenv= sub {
        my ($envvar,$dbparam) = @_;
        my $thing= $ENV{$envvar};
        return unless defined $thing;
        $src .= ";$dbparam=$thing";
    };
    $fromenv->('DBI_HOST', 'host');
    $fromenv->('DBI_PASS', 'password');
    
    my $whoami= $ENV{'DBI_USER'};
    if (!defined $whoami) {
        $whoami= `whoami`;  chomp $whoami;
    }

    my $dbh= DBI->connect($src, $whoami,'', {
        AutoCommit => 1,
        RaiseError => 1,
        ShowErrorStatement => 1,
        })
        or die "could not open state db $src";
    return $dbh;
}

#---------- runvars ----------

sub flight_otherjob ($$) {
    my ($thisflight, $otherflightjob) = @_;    
    return $otherflightjob =~ m/^([^.]+)\.([^.]+)$/ ? ($1,$2) :
           $otherflightjob =~ m/^\.?([^.]+)$/ ? ($thisflight,$1) :
           die "$otherflightjob ?";
}

sub otherflightjob ($) {
    return flight_otherjob($flight,$_[0]);
}

sub get_stashed ($$) {
    my ($param, $otherflightjob) = @_; 
    # may be run outside transaction, or with flights locked
    my ($oflight, $ojob) = otherflightjob($otherflightjob);
    my $path= get_runvar($param, $otherflightjob);
    die "$path $& " if
        $path =~ m,[^-+._0-9a-zA-Z/], or
        $path =~ m/\.\./;
    return "$c{Stash}/$oflight/$ojob/$path";
}

sub unique_incrementing_runvar ($$) {
    my ($param,$start) = @_;
    # must be run outside transaction
    my $value;
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
	my $row= $dbh_tests->selectrow_arrayref(<<END,{}, $flight,$job,$param);
            SELECT val FROM runvars WHERE flight=? AND job=? AND name=?
END
	$value= $row ? $row->[0] : $start;
	$dbh_tests->do(<<END, undef, $flight, $job, $param);
            DELETE FROM runvars WHERE flight=? AND job=? AND name=? AND synth
END
	$dbh_tests->do(<<END, undef, $flight, $job, $param, $value+1);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    logm("runvar increment: $param=$value");
    return $value;
}

sub store_runvar ($$) {
    my ($param,$value) = @_;
    # must be run outside transaction
    logm("runvar store: $param=$value");
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        $dbh_tests->do(<<END, undef, $flight, $job, $param);
	    DELETE FROM runvars WHERE flight=? AND job=? AND name=? AND synth
END
        $dbh_tests->do(<<END,{}, $flight,$job, $param,$value);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    $r{$param}= get_runvar($param, "$flight.$job");
}

sub broken ($;$) {
    my ($m, $newst) = @_;
    # must be run outside transaction
    my $affected;
    $newst= 'broken' unless defined $newst;
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        $affected= $dbh_tests->do(<<END, {}, $newst, $flight, $job);
            UPDATE jobs SET status=?
             WHERE flight=? AND job=?
               AND (status='queued' OR status='running')
END
    });
    die "BROKEN: $m; ". ($affected>0 ? "marked $flight.$job $newst"
                         : "($flight.$job not marked $newst)");
}

sub get_runvar ($$) {
    my ($param, $otherflightjob) = @_;
    # may be run outside transaction, or with flights locked
    my $r= get_runvar_maybe($param,$otherflightjob);
    die "need $param in $otherflightjob" unless defined $r;
    return $r;
}

sub get_runvar_default ($$$) {
    my ($param, $otherflightjob, $default) = @_;
    # may be run outside transaction, or with flights locked
    my $r= get_runvar_maybe($param,$otherflightjob);
    return defined($r) ? $r : $default;
}

sub get_runvar_maybe ($$) {
    my ($param, $otherflightjob) = @_;
    # may be run outside transaction, or with flights locked
    my ($oflight, $ojob) = otherflightjob($otherflightjob);

    if ("$oflight.$ojob" ne "$flight.$job") {
        my $jstmt= <<END;
            SELECT * FROM jobs WHERE flight=? AND job=?
END
        my $jrow= $dbh_tests->selectrow_hashref($jstmt,{}, $oflight,$ojob);
        $jrow or broken("job $oflight.$ojob not found (looking for $param)");
        my $jstatus= $jrow->{'status'};
        defined $jstatus or broken("job $oflight.$ojob no status?!");
        if ($jstatus eq 'pass') {
            # fine
        } elsif ($jstatus eq 'queued') {
            $jrow= $dbh_tests->selectrow_hashref($jstmt,{}, $flight,$job);
            $jrow or broken("our job $flight.$job not found!");
            my $ourstatus= $jrow->{'status'};
            if ($ourstatus eq 'queued') {
                logm("not running under sg-execute-*:".
                     " $oflight.$ojob queued ok, for $param");
            } else {
                die "job $oflight.$ojob (for $param) queued (we are $ourstatus)";
            }
        } else {
            broken("job $oflight.$ojob (for $param) $jstatus", 'blocked');
        }
    }

    my $row= $dbh_tests->selectrow_arrayref(<<END,{}, $oflight,$ojob,$param);
        SELECT val FROM runvars WHERE flight=? AND job=? AND name=?
END
    if (!$row) { return undef; }
    return $row->[0];
}

sub need_runvars {
    my @missing= grep { !defined $r{$_} } @_;
    return unless @missing;
    die "missing runvars @missing ";
}

#---------- running commands eg on targets ----------

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
    my $start= time;
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
    } else {
	my $finish= time;
	my $took= $finish-$start;
	my $warn= $took > 0.5*$timeout;
	logm(sprintf "execution took %d seconds%s: %s",
	     $took, ($warn ? " [**>$timeout/2**]" : "[<=2x$timeout]"), "@cmd")
	    if $warn or $took > 60;
    }
    die "$r $child $!" unless $r == $child;
    logm("command nonzero waitstatus $?: @cmd") if $?;
    return $?;
}

sub remote_perl_script_open ($$$) {
    my ($userhost, $what, $script) = @_;
    my ($readh,$writeh);
    my ($sshopts) = sshopts();
    my $pid= open2($readh,$writeh, "ssh @$sshopts $userhost perl");
    print $writeh $script."\n__DATA__\n" or die "$what $!";
    my $thing= {
        Read => $readh,
        Write => $writeh,
        Pid => $pid,
        Wait => $what,
        };
    return $thing;
}
sub remote_perl_script_done ($) {
    my ($thing) = @_;
    $thing->{Write}->close() or die "$thing->{What} $!";
    $thing->{Read}->close() or die "$thing->{What} $!";
    $!=0; my $got= waitpid $thing->{Pid}, 0;
    $got==$thing->{Pid} or die "$thing->{What} $!";
    !$? or die "$thing->{What} $?";
}

sub sshuho ($$) { my ($user,$ho)= @_; return "$user\@$ho->{Ip}"; }

sub sshopts () {
    return [ qw(-o UserKnownHostsFile=/dev/null
                -o StrictHostKeyChecking=no
                -o BatchMode=yes
                -o PasswordAuthentication=no
                -o ChallengeResponseAuthentication=no) ];
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
    # $ho,$timeout,$lsrc,$rdst,[$rsync_opt]
    tputfileex('osstest', @_);
}
sub target_putfile_root ($$$$;$) {
    tputfileex('root', @_);
}
sub target_install_packages {
    my ($ho, @packages) = @_;
    target_cmd_root($ho, "apt-get -y install @packages",
                    300 + 100 * @packages);
}
sub target_install_packages_norec {
    my ($ho, @packages) = @_;
    target_cmd_root($ho,
                    "apt-get --no-install-recommends -y install @packages",
                    300 + 100 * @packages);
}

sub target_somefile_getleaf ($$$) {
    my ($lleaf_ref, $rdest, $ho) = @_;
    if (!defined $$lleaf_ref) {
        $$lleaf_ref= $rdest;
        $$lleaf_ref =~ s,.*/,,;
    }
    $$lleaf_ref= "$ho->{Name}--$$lleaf_ref";
}

sub target_putfilecontents_root_stash ($$$$;$) {
    my ($ho,$timeout,$filedata, $rdest,$lleaf) = @_;
    target_somefile_getleaf(\$lleaf,$rdest,$ho);

    my $h= new IO::File "$stash/$lleaf", 'w' or die "$lleaf $!";
    print $h $filedata or die $!;
    close $h or die $!;
    target_putfile_root($ho,$timeout, "$stash/$lleaf", $rdest);
}

sub target_file_exists ($$) {
    my ($ho,$rfile) = @_;
    my $out= target_cmd_output_root($ho, "if test -e $rfile; then echo y; fi");
    return 1 if $out =~ m/^y$/;
    return 0 if $out !~ m/\S/;
    die "$rfile $out ?";
}

sub target_editfile_root ($$$;$$) {
    my $code= pop @_;
    my ($ho,$rfile,$lleaf,$rdest) = @_;

    if (!defined $rdest) {
        $rdest= $rfile;
    }
    target_somefile_getleaf(\$lleaf,$rdest,$ho);
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
    $out =~ s/\b(?:\d+(?:\.\d+)?\/)*\d+(?:\.\d+)? ?ms\b/XXXms/g;
    report_once($ho, 'ping_check',
		"ping $ho->{Ip} ".(!$? ? 'up' : $?==256 ? 'down' : "$? ?"));
    return undef if $?==$exp;
    $out =~ s/\n/ | /g;
    return "ping gave ($?): $out";
}
sub target_ping_check_down ($) { return target_ping_check_core(@_,256); }
sub target_ping_check_up ($) { return target_ping_check_core(@_,0); }

sub target_await_down ($$) {
    my ($ho,$timeout) = @_;
    poll_loop($timeout,5,'reboot-down', sub {
        return target_ping_check_down($ho);
    });
}    

sub system_checked ($) {
    my ($cmd) = @_;
    $!=0; $?=0; system $cmd;
    die "$cmd $? $!" if $? or $!;
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

#---------- other stuff ----------

sub logm ($) {
    my ($m) = @_;
    my @t = gmtime;
    printf "%04d-%02d-%02d %02d:%02d:%02d Z %s\n",
        $t[5]+1900,$t[4]+1,$t[3], $t[2],$t[1],$t[0],
        $m
    or die $!;
    STDOUT->flush or die $!;
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

sub ensuredir ($) {
    my ($dir)= @_;
    mkdir($dir) or $!==&EEXIST or die "$dir $!";
}

sub postfork () {
    $dbh_tests->{InactiveDestroy}= 1;  undef $dbh_tests;
}

sub host_reboot ($) {
    my ($ho) = @_;
    target_reboot($ho);
    poll_loop(40,2, 'reboot-confirm-booted', sub {
        my $output;
        if (!eval {
            $output= target_cmd_output($ho,
                "stat /dev/shm/osstest-confirm-booted 2>&1 >/dev/null ||:",
                                       40);
            1;
        }) {
            return $@;
        }
        return length($output) ? $output : undef;
    });
}

sub target_reboot ($) {
    my ($ho) = @_;
    target_cmd_root($ho, "init 6");
    target_await_down($ho, $timeout{RebootDown});
    await_tcp($timeout{RebootUp},5,$ho);
}

sub target_reboot_hard ($) {
    my ($ho) = @_;
    power_cycle($ho);
    await_tcp($timeout{HardRebootUp},5,$ho);
}

sub tcpconnect ($$) {
    my ($host, $port) = @_;
    my $h= new IO::Handle;
    my $proto= getprotobyname('tcp');  die $! unless defined $proto;
    my $fixedaddr= inet_aton($host);
    my @addrs; my $atype;
    if (defined $fixedaddr) {
        @addrs= $fixedaddr;
        $atype= AF_INET;
    } else {
        $!=0; $?=0; my @hi= gethostbyname($host);
        @hi or die "host lookup failed for $host: $? $!";
        $atype= $hi[2];
        @addrs= @hi[4..$#hi];
        die "connect $host:$port: no addresses for $host" unless @addrs;
    }
    foreach my $addr (@addrs) {
        my $h= new IO::Handle;
        my $sin; my $pfam; my $str;
        if ($atype==AF_INET) {
            $sin= sockaddr_in $port, $addr;
            $pfam= PF_INET;
            $str= inet_ntoa($addr);
#        } elsif ($atype==AF_INET6) {
#            $sin= sockaddr_in6 $port, $addr;
#            $pfam= PF_INET6;
#            $str= inet_ntoa6($addr);
        } else {
            warn "connect $host:$port: unknown AF $atype";
            next;
        }
        if (!socket($h, $pfam, SOCK_STREAM, $proto)) {
            warn "connect $host:$port: unsupported PF $pfam";
            next;
        }
        if (!connect($h, $sin)) {
            warn "connect $host:$port: [$str]: $!";
            next;
        }
        return $h;

    }
    die "$host:$port all failed";
}

#---------- building, vcs's, etc. ----------

sub build_clone ($$$$) {
    my ($ho, $which, $builddir, $subdir) = @_;
    my $vcs= '';

    need_runvars("tree_$which", "revision_$which");

    my $tree= $r{"tree_$which"};

    if ($tree =~ m/\.hg$/) {
        $vcs= 'hg';
        
        target_cmd_build($ho, 2000, $builddir, <<END.
	    hg clone '$tree' $subdir
	    cd $subdir
END
                         (length($r{"revision_$which"}) ? <<END : ''));
	    hg update '$r{"revision_$which"}'
END
    } else {
        die "unknown vcs for $which $tree ";
    }

    my $rev= vcs_dir_revision($ho, "$builddir/$subdir", $vcs);
    store_vcs_revision($which, $rev, $vcs);
}

sub dir_identify_vcs ($$) {
    my ($ho,$dir) = @_;
    return target_cmd_output($ho, <<END);
        set -e; cd $dir
        (test -d .git && echo git) ||
        (test -d .hg && echo hg) ||
        (echo >&2 'unable to determine vcs'; fail)
END
}

sub store_revision ($$$) {
    my ($ho,$which,$dir) = @_;
    my $vcs= dir_identify_vcs($ho,$dir);
    my $rev= vcs_dir_revision($ho,$dir,$vcs);
    store_vcs_revision($which,$rev,$vcs);
}

sub store_vcs_revision ($$$) {
    my ($which,$rev,$vcs) = @_;
    store_runvar("built_vcs_$which", $vcs);
    store_runvar("built_revision_$which", $rev);
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

#---------- host (and other resource) allocation ----------

our $taskid;

sub findtask () {
    return $taskid if defined $taskid;
    
    my $spec= $ENV{'OSSTEST_TASK'};
    my $q;
    my $what;
    if (!defined $spec) {
        $!=0; $?=0; my $whoami= `whoami`;   defined $whoami or die "$? $!";
        $!=0; $?=0; my $node=   `uname -n`; defined $node   or die "$? $!";
        chomp($whoami); chomp($node); $node =~ s/\..*//;
        my $refkey= "$whoami\@$node";
        $what= "static $refkey";
        $q= $dbh_tests->prepare(<<END);
            SELECT * FROM tasks
                    WHERE type='static' AND refkey=?
END
        $q->execute($refkey);
    } else {
        my @l = split /\s+/, $spec;
        @l==3 or die "$spec ".scalar(@l)." ?";
        $what= $spec;
        $q= $dbh_tests->prepare(<<END);
            SELECT * FROM tasks
                    WHERE taskid=? AND type=? AND refkey=?
END
        $q->execute(@l);
    }
    my $row= $q->fetchrow_hashref();
    die "no task $what ?" unless defined $row;
    die "task $what dead" unless $row->{live};
    $q->finish();

    foreach my $k (qw(username comment)) {
        next if defined $row->{$k};
        $row->{$k}= "[no $k]";
    }

    my $newspec= "$row->{taskid} $row->{type} $row->{refkey}";
    logm("task $newspec: $row->{username} $row->{comment}");

    $taskid= $row->{taskid};
    $ENV{'OSSTEST_TASK'}= $newspec if !defined $spec;

    return $taskid;
}        

sub alloc_resources_rollback_begin_work () {
    $dbh_tests->rollback();
    db_begin_work($dbh_tests, \@all_lock_tables);
}

our $alloc_resources_waitstart;

sub alloc_resources {
    my ($resourcecall) = pop @_;
    my (%xparams) = @_;
    # $resourcecall should die (abort) or return
    #            0  rollback, wait and try again
    #            1  commit, completed ok
    #            2  commit, wait and try again
    # $resourcecall should not look at tasks.live
    #  instead it should look for resources.owntaskid == the allocatable task
    # $resourcecall runs with all tables locked (see above)

    my $qserv;
    my $retries=0;
    my $ok=0;

    logm("resource allocation: starting...");

    my $set_info= sub {
        print $qserv "set-info @_\n";
        $_= <$qserv>;  defined && m/^OK/ or die "$_ ?";
    };

    while ($ok==0 || $ok==2) {
        if (!eval {
            if (!defined $qserv) {
                $qserv= tcpconnect($c{ControlDaemonHost}, $c{QueueDaemonPort});
                $qserv->autoflush(1);

                $_= <$qserv>;  defined && m/^OK ms-queuedaemon\s/ or die "$_?";

                my $waitstart= $xparams{WaitStart};
                if (!$waitstart) {
                    if (!defined $alloc_resources_waitstart) {
                        print $qserv "time\n" or die $!;
                        $_= <$qserv>;
                        defined or die $!;
                        if (m/^OK time (\d+)$/) {
                            $waitstart= $alloc_resources_waitstart= $1;
                        }
                    }
                }

                if (defined $waitstart) {
                    print $qserv "set-info wait-start $waitstart\n";
                    $_= <$qserv>;  defined && m/^OK/ or die "$_ ?";
                }

                my $adjust= $xparams{WaitStartAdjust};
                if (defined $adjust) {
                    $set_info->('wait-start-adjust',$adjust);
                }

                $set_info->('job', "$flight.$job");

                print $qserv "wait\n" or die $!;
                $_= <$qserv>;  defined && m/^OK wait\s/ or die "$_ ?";
            }

            $dbh_tests->disconnect();
            undef $dbh_tests;

            logm("resource allocation: awaiting our slot...");

            $_= <$qserv>;  defined && m/^\!OK think\s$/ or die "$_ ?";

            opendb_tests();

            db_retry($flight,'running', $dbh_tests, \@all_lock_tables, sub {
                my $pending= $dbh_tests->selectrow_hashref(<<END);
                        SELECT * FROM resources
                                WHERE owntaskid !=
                     (SELECT taskid FROM tasks
                                   WHERE type='magic' AND refkey='allocatable')
                                 AND NOT (SELECT live FROM tasks
                                                     WHERE taskid=owntaskid)
                                LIMIT 1
END
                if ($pending) {
                    logm("resource(s) nearly free".
                         " ($pending->{restype} $pending->{resname}".
                         " $pending->{shareix}), deferring");
                    $ok= 0;
                } else {
                    if (!eval {
                        $ok= $resourcecall->();
                        1;
                    }) {
                        warn "resourcecall $@";
                        $ok=-1;
                    }
                }
                return db_retry_abort() unless $ok>0;
            });
            if ($ok==1) {
                print $qserv "thought-done\n" or die $!;
            } elsif ($ok<0) {
                return 1;
            } else { # 0 or 2
                logm("resource allocation: rolled back") if $ok==0;
                logm("resource allocation: deferring");
                print $qserv "thought-wait\n" or die $!;
            }
            $_= <$qserv>;  defined && m/^OK thought\s$/ or die "$_ ?";
            
            1;
        }) {
            $retries++;
            die "trouble $@" if $retries > 60;
            chomp $@;
            logm("resource allocation: queue-server trouble, sleeping ($@)");
            sleep $c{QueueDaemonRetry};
            undef $qserv;
            $ok= 0;
        }
    }
    die unless $ok==1;
    logm("resource allocation: successful.");
}

sub resource_check_allocated ($$) {
    my ($restype,$resname) = @_;
    return db_retry($dbh_tests, [qw(resources)], sub {
        return resource_check_allocated_core($restype,$resname);
    });
}

sub resource_check_allocated_core ($$) {
    # must run in db_retry with resources locked
    my ($restype,$resname) = @_;
    my $tid= findtask();
    my $shared;

    my $res= $dbh_tests->selectrow_hashref(<<END,{}, $restype, $resname);
        SELECT * FROM resources LEFT JOIN tasks
                   ON taskid=owntaskid
                WHERE restype=? AND resname=?
END
    die "resource $restype $resname not found" unless $res;
    die "resource $restype $resname no task" unless defined $res->{taskid};

    if ($res->{type} eq 'magic' && $res->{refkey} eq 'shared') {
        my $shr= $dbh_tests->selectrow_hashref(<<END,{}, $restype,$resname);
                SELECT * FROM resource_sharing
                        WHERE restype=? AND resname=?
END
        die "host $resname shared but no share?" unless $shr;

        my $shrestype= 'share-'.$restype;
        my $shrt= $dbh_tests->selectrow_hashref
            (<<END,{}, $shrestype,$resname,$tid);
                SELECT * FROM resources LEFT JOIN tasks ON taskid=owntaskid
                        WHERE restype=? AND resname=? AND owntaskid=?
END

        die "resource $restype $resname not shared by $tid" unless $shrt;
        die "resource $resname $resname share $shrt->{shareix} task $tid dead"
            unless $shrt->{live};

        my $others= $dbh_tests->selectrow_hashref
            (<<END,{}, $shrt->{restype}, $shrt->{resname}, $shrt->{shareix});
                SELECT count(*) AS ntasks
                         FROM resources LEFT JOIN tasks ON taskid=owntaskid
                        WHERE restype=? AND resname=? AND shareix!=?
                          AND live
                          AND owntaskid != (SELECT taskid FROM tasks
                                             WHERE type='magic'
                                               AND refkey='preparing')
END

        $shared= { Type => $shr->{sharetype},
                   State => $shr->{state},
                   ResType => $shrestype,
                   Others => $others->{ntasks} };
    } else {
        die "resource $restype $resname task $res->{owntaskid} not $tid"
            unless $res->{owntaskid} == $tid;
    }
    die "resource $restype $resname task $res->{taskid} dead"
        unless $res->{live};

    return $shared;
}

sub resource_shared_mark_ready ($$$) {
    my ($restype, $resname, $sharetype) = @_;
    # must run outside transaction

    my $what= "resource $restype $resname";

    db_retry($dbh_tests, [qw(resources)], sub {
        my $oldshr= resource_check_allocated_core($restype, $resname);
        if (defined $oldshr) {
            die "$what shared $oldshr->{Type} not $sharetype"
                unless $oldshr->{Type} eq $sharetype;
            die "$what shared state $oldshr->{State} not prep"
                unless $oldshr->{State} eq 'prep';
            my $nrows= $dbh_tests->do(<<END,{}, $restype,$resname,$sharetype);
                UPDATE resource_sharing
                   SET state='ready'
                 WHERE restype=? AND resname=? AND sharetype=?
END
            die "unexpected not updated state $what $sharetype $nrows"
                unless $nrows==1;

            $dbh_tests->do(<<END,{}, $oldshr->{ResType}, $resname);
                UPDATE resources
                   SET owntaskid=(SELECT taskid FROM tasks
                                   WHERE type='magic' AND refkey='idle')
                 WHERE owntaskid=(SELECT taskid FROM tasks
                                   WHERE type='magic' AND refkey='preparing')
                   AND restype=? AND resname=?
END
        }
    });
}

#---------- hosts and guests ----------

sub get_hostflags ($) {
    my ($ident) = @_;
    # may be run outside transaction, or with flights locked
    my $flags= get_runvar_default('all_hostflags',     $job, '').
               get_runvar_default("${ident}_hostflags", $job, '');
    return grep /./, split /\,/, $flags;
}

sub selecthost ($) {
    my ($ident) = @_;
    # must be run outside transaction
    my $name;
    if ($ident =~ m/=/) {
        $ident= $`;
        $name= $';
    } else {
        $name= $r{$ident};
        die "no specified $ident" unless defined $name;
    }
    my $ho= {
        Ident => $ident,
        Name => $name,
        TcpCheckPort => 22,
        Fqdn => "$name.$c{TestHostDomain}"
    };
    my $dbh= opendb('configdb');
    my $selname= $ho->{Fqdn};
    my $sth= $dbh->prepare('SELECT * FROM ips WHERE reverse_dns = ?');
    $sth->execute($selname);
    my $row= $sth->fetchrow_hashref();
    die "$ident $name $selname ?" unless $row;
    die if $sth->fetchrow_hashref();
    $sth->finish();
    my $get= sub {
	my ($k) = @_;
	my $v= $row->{$k};
	defined $v or warn "undefined $k in configdb::ips\n";
	return $v;
    };
    $ho->{Ip}=    $get->('ip');
    $ho->{Ether}= $get->('hardware');
    $ho->{Asset}= $get->('asset');
    $dbh->disconnect();

    $ho->{Flags}= { };
    my $flagsq= $dbh_tests->prepare(<<END);
        SELECT hostflag FROM hostflags WHERE hostname=?
END
    $flagsq->execute($name);
    while (my ($flag) = $flagsq->fetchrow_array()) {
        $ho->{Flags}{$flag}= 1;
    }
    $flagsq->finish();

    $ho->{Shared}= resource_check_allocated('host', $name);
    $ho->{SharedReady}=
        $ho->{Shared} &&
        $ho->{Shared}{State} eq 'ready' &&
        !! grep { $_ eq "share-".$ho->{Shared}{Type} } get_hostflags($ident);
    $ho->{SharedOthers}=
        $ho->{Shared} ? $ho->{Shared}{Others} : 0;

    logm("host: selected $ho->{Name} $ho->{Asset} $ho->{Ether} $ho->{Ip}".
         (!$ho->{Shared} ? '' :
          sprintf(" - shared %s %s %d", $ho->{Shared}{Type},
                  $ho->{Shared}{State}, $ho->{Shared}{Others}+1)));
    
    return $ho;
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

    my $dbh_state= opendb_state();
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
    $q->finish();
    $dbh_state->disconnect();

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

sub select_ether ($) {
    my ($vn) = @_;
    # must be run outside transaction
    my $ether= $r{$vn};
    return $ether if defined $ether;
    my $prefix= sprintf "%s:%02x", $c{GenEtherPrefix}, $flight & 0xff;

    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        my $previous= $dbh_tests->selectrow_array(<<END, {}, $flight);
            SELECT max(val) FROM runvars WHERE flight=?
                AND name LIKE E'%\\_ether'
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
        my $chkrow= $dbh_tests->selectrow_hashref(<<END,{}, $flight);
	    SELECT val, count(*) FROM runvars WHERE flight=?
                AND name LIKE E'%\\_ether'
                AND val LIKE '$prefix:%'
		GROUP BY val
		HAVING count(*) <> 1
		LIMIT 1
END
	die "$chkrow->{val} $chkrow->{count}" if $chkrow;
    });
    $r{$vn}= $ether;
    return $ether;
}

sub prepareguest ($$$$$) {
    my ($ho, $gn, $hostname, $tcpcheckport, $mb) = @_;
    # must be run outside transaction

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

sub more_prepareguest_hvm ($$$$;$) {
    my ($ho, $gho, $ram_mb, $disk_mb, $postimage_hook) = @_;
    
    my $passwd= 'xenvnc';

    target_cmd_root($ho, "lvremove -f $gho->{Lvdev} ||:");
    target_cmd_root($ho, "lvcreate -L ${disk_mb}M -n $gho->{Lv} $gho->{Vg}");
    target_cmd_root($ho, "dd if=/dev/zero of=$gho->{Lvdev} count=10");
    
    my $imageleaf= $r{"$gho->{Guest}_image"};
    die "$gho->{Guest} ?" unless $imageleaf;
    my $limage= "$c{Images}/$imageleaf";
    $gho->{Rimage}= "/root/$imageleaf";
    target_putfile_root($ho,300, $limage,$gho->{Rimage}, '-p');

    $postimage_hook->() if $postimage_hook;

    my $xencfg= <<END;
name        = '$gho->{Name}'
#
kernel      = 'hvmloader'
builder     = 'hvm'
#
disk        = [
            'phy:$gho->{Lvdev},hda,w',
            'file:$gho->{Rimage},hdc:cdrom,r'
            ]
#
memory = ${ram_mb}
#
usb=1
usbdevice='tablet'
#
#stdvga=1
keymap='en-gb';
#
sdl=0
opengl=0
vnc=1
vncunused=0
vncdisplay=0
vnclisten='$ho->{Ip}'
vncpasswd='$passwd'
#
boot = 'dc'
#
vif         = [ 'type=ioemu,mac=$gho->{Ether}' ]
#
on_poweroff = 'destroy'
on_reboot   = 'restart'
on_crash    = 'preserve'
vcpus = 2
END

    my $cfgpath= "/etc/xen/$gho->{Name}.cfg";
    store_runvar("$gho->{Guest}_cfgpath", "$cfgpath");
    $gho->{CfgPath}= $cfgpath;

    target_putfilecontents_root_stash($ho,10,$xencfg, $cfgpath);

    target_cmd_root($ho, <<END);
        (echo $passwd; echo $passwd) | vncpasswd $gho->{Guest}.vncpw
END

    return $cfgpath;
}

sub guest_check_up ($) {
    my ($gho) = @_;
    guest_await_dhcp_tcp($gho,20);
    target_ping_check_up($gho);
    target_cmd_root($gho, "echo guest $gho->{Name}: ok")
        if $r{"$gho->{Guest}_tcpcheckport"} == 22;
}

sub guest_get_state ($$) {
    my ($ho,$gho) = @_;
    my $domains= target_cmd_output_root($ho, toolstack()->{Command}." list");
    $domains =~ s/^Name.*\n//;
    foreach my $l (split /\n/, $domains) {
        $l =~ m/^(\S+) (?: \s+ \d+ ){3} \s+ ([-a-z]+) \s/x or die "$l ?";
        next unless $1 eq $gho->{Name};
        my $st= $2;
        $st =~ s/\-//g;
        $st='-' if !length $st;
        logm("guest $gho->{Name} state is $st");
        return $st;
    }
    logm("guest $gho->{Name} not present on this host");
    return '';
}

our $guest_state_running_re= '[-rb]+';

sub guest_checkrunning ($$) {
    my ($ho,$gho) = @_;
    my $s= guest_get_state($ho,$gho);
    return $s =~ m/^$guest_state_running_re$/o;
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

sub guest_check_remus_ok {
    my ($gho, @hos) = @_;
    my @sts;
    logm("remus check $gho->{Name}...");
    foreach my $ho (@hos) {
	my $st;
	if (!eval {
	    $st= guest_get_state($ho, $gho)
        }) {
	    $st= '_';
	    logm("could not get guest $gho->{Name} state on $ho->{Name}: $@");
	}
	push @sts, [ $ho, $st ];
    }
    my @ststrings= map { $_->[1] } @sts;
    my $compound= join ',', @ststrings;
    my $msg= "remus check $gho->{Name}: result \"$compound\":";
    $msg .= " $_->[0]{Name}=$_->[1]" foreach @sts;
    logm($msg);
    my $runnings= scalar grep { m/$guest_state_running_re/o } @ststrings;
    die "running on multiple hosts $compound" if $runnings > 1;
    die "not running anywhere $compound" unless $runnings;
    die "crashed somewhere $compound" if grep { m/c/ } @ststrings;
}

sub power_cycle ($) {
    my ($ho) = @_;
    my $dbh_state= opendb_state();
    power_state($ho, 0, $dbh_state);
    sleep(1);
    power_state($ho, 1, $dbh_state);
}

sub power_state_await ($$$) {
    my ($sth, $want, $msg) = @_;
    poll_loop(30,1, "power: $msg $want", sub {
        $sth->execute();
        my ($got) = $sth->fetchrow_array();
        $sth->finish();
        return undef if $got eq $want;
        return "state=\"$got\"";
    });
}

sub power_state ($$;$) {
    my ($ho, $on, $dbh_state) = @_;
    my $want= (qw(s6 s1))[!!$on];
    my $asset= $ho->{Asset};
    logm("power: setting $want for $ho->{Name} $asset");

    $dbh_state ||= opendb_state();

    my $sth= $dbh_state->prepare
        ('SELECT current_power FROM control WHERE asset = ?');

    my $current= $dbh_state->selectrow_array
        ('SELECT desired_power FROM control WHERE asset = ?',
         undef, $asset);
    die "not found $asset" unless defined $current;

    $sth->bind_param(1, $asset);
    power_state_await($sth, $current, 'checking');

    my $rows= $dbh_state->do
        ('UPDATE control SET desired_power=? WHERE asset=?',
         undef, $want, $asset);
    die "$rows updating desired_power for $asset in statedb::control\n"
        unless $rows==1;
    
    $sth->bind_param(1, $asset);
    power_state_await($sth, $want, 'awaiting');
    $sth->finish();
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

sub host_pxedir ($) {
    my ($ho) = @_;
    my $dir= $ho->{Ether};
    $dir =~ y/A-Z/a-z/;
    $dir =~ y/0-9a-f//cd;
    length($dir)==12 or die "$dir";
    $dir =~ s/../$&-/g;
    $dir =~ s/\-$//;
    return $dir;
}

sub setup_pxeboot ($$) {
    my ($ho, $bootfile) = @_;
    my $dir= host_pxedir($ho);
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
	my $link= target_cmd_output_root($ho, "readlink $dev");
	return if $link =~ m,^/dev/nbd,; # can't tell if it's open
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
    my $isguest= exists $gho->{Guest};
    if ($kernkind eq 'pvops') {
        store_runvar($pfx."rootdev", 'xvda') if $isguest;
        store_runvar($pfx."console", 'hvc0');
    } elsif ($kernkind !~ m/2618/) {
        store_runvar($pfx."console", 'xvc0') if $isguest;
    }
}

sub target_kernkind_console_inittab ($$$) {
    my ($ho, $gho, $root) = @_;

    my $inittabpath= "$root/etc/inittab";
    my $console= target_var($gho,'console');

    if (defined $console && length $console) {
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
    my $list= target_cmd_output_root($ho,
                toolstack()->{Command}." list $gho->{Name}");
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
        NewDaemons => [qw(xend)],
        OldDaemonInitd => 'xend',
        Command => 'xm',
        CfgPathVar => 'cfgpath',
        Dom0MemFixed => 1,
        },
     'xl' => {
        NewDaemons => [],
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

#---------- logtailer ----------

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
