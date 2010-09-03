# -*- Tcl -*-

package require Pgtcl 1.5

proc readconfig {} {
    global c
    set pl {
        use Osstest;
        csreadconfig();
        foreach my $k (sort keys %c) {
            my $v= $c{$k};
            printf "%s\n%d\n%s\n", $k, length($v), $v;
        }
    }
    set ch [open |[list perl -e $pl] r]
    while {[gets $ch k] >= 0} {
        gets $ch vl
        set v [read $ch $vl]
        if {[eof $ch]} { error "premature eof in $k" }
        set c($k) $v
        gets $ch blank
        if {[string length $blank]} { error "$blank ?" }
    }
    close $ch
}

proc logputs {f m} {
    global argv
    set time [clock format [clock seconds] -gmt true \
                  -format "%Y-%m-%d %H:%M:%S Z"]
    puts $f "$time \[$argv] $m"
}

proc db-open {} {
    pg_connect -conninfo "dbname=osstestdb" -connhandle dbh
}

proc db-update-1 {stmt} {
    set nrows [pg_execute dbh $stmt]
    if {$nrows != 1} { error "$nrows != 1 in < $stmt >" }
}

proc set-flight {} {
    global flight argv env

    set flight [lindex $argv 0]
    set argv [lrange $argv 1 end]
    set env(OSSTEST_FLIGHT) $flight
}

proc prepare-job {job} {
    global flight argv c
    set desc "$flight.$job"

    foreach constraint $argv {
        if {[regexp {^--jobs=(.*)$} $constraint dummy jobs]} {
            if {[lsearch -exact [split $jobs ,] $job] < 0} {
                logputs stdout "suppress $desc (jobs)"
                return 0
            }
        } elseif {[regexp {^--hostlist=(.*)$} $constraint dummy wanthosts]} {
            set actualhosts {}
            pg_execute -array hostinfo dbh "
                SELECT val FROM runvars
                    WHERE  flight=$flight
                    AND    job='$job'
                    AND   (name='host' OR name LIKE E'%\\_host')
                  ORDER BY val
            " {
                lappend actualhosts $hostinfo(val)
            }
            if {[string compare $wanthosts [join $actualhosts ,]]} {
                logputs stdout "suppress $desc (hosts $actualhosts)"
                return 0
            }
        } else {
            error "unknown constraint $constraint"
        }
    }

    logputs stdout "prepping $desc"
    return 1
}

proc run-ts {args} {
    set reap [eval spawn-ts $args]
    if {![reap-ts $reap]} { error "test script failed" }
}

proc spawn-ts {iffail testid ts args} {
    global flight c jobinfo reap_details env

    if {[file exists abort]} {
        logputs stdout \
            "aborting - not executing $flight.$jobinfo(job) $ts $args"
        job-set-status $flight $jobinfo(job) aborted
        return {}
    }

    if {![string compare . $iffail]} { set iffail fail }

    pg_execute dbh BEGIN
    pg_execute dbh "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
    if {[catch {
        pg_execute dbh "LOCK TABLE steps IN SHARE ROW EXCLUSIVE MODE"
	pg_execute -array stepinfo dbh "
            SELECT max(stepno) AS maxstep FROM steps
                WHERE flight=$flight AND job='$jobinfo(job)'
        "
        set stepno $stepinfo(maxstep)
	if {[string length $stepno]} {
	    incr stepno
	} else {
	    set stepno 1
	}
	pg_execute dbh "
            INSERT INTO steps
                VALUES ($flight, '$jobinfo(job)', $stepno, '$ts', 'running',
                        'TBD')
        "
	pg_execute dbh COMMIT
    } emsg]} {
	global errorInfo errorCode
	set ei $errorInfo
	set ec $errorCode
	catch { pg_execute dbh ROLLBACK }
	error $emsg $ei $ec
    }

    set real_args {}
    set adding 1
    set host_testid_suffix {}
    foreach arg $args {
        if {![string compare + $arg]} {
            set adding 0
            continue
        }
        lappend real_args $arg
        if {$adding} { append host_testid_suffix "/$arg" }
    }

    regsub {^ts-} $ts {} deftestid
    append deftestid /@

    if {[string match =* $testid]} {
        set testid "$deftestid[string range $testid 1 end]"
    } elseif {![string compare $testid *]} {
        set testid $deftestid
        append testid (*)
    }
    regsub {/\@} $testid $host_testid_suffix testid
    regsub {\(\*\)$} $testid ($stepno) testid

    set detstr "$flight.$jobinfo(job) $ts $real_args"
    set details [list $flight $jobinfo(job) $stepno $detstr $iffail]
    logputs stdout "starting $detstr $testid"
    
    db-update-1 "
        UPDATE steps SET testid=[pg_quote $testid]
            WHERE flight=$flight
              AND job=[pg_quote $jobinfo(job)]
              AND stepno=$stepno
    "

    set logdir $c(Logs)/$flight/$jobinfo(job)
    file mkdir $c(Logs)/$flight
    file mkdir $logdir

    set log $logdir/$stepno.$ts.log

    set xprefix {}
    if {[info exists env(OSSTEST_SIMULATE)]} { set xprefix echo }

    set cmd [concat \
                 [list sh -xc "
                     OSSTEST_JOB=$jobinfo(job)
                     export OSSTEST_JOB
                     $xprefix \"$@\" >&2
                     rc=\$?
                     date -u +\"%Y-%m-%d %H:%M:%S Z exit status \$rc\" >&2
                     exit \$rc
                 " x ./$ts] \
                 $real_args \
                 [list 2> $log < /dev/null]]
    set fh [open |$cmd r]
    set reap_details($fh) $details

    return $fh
}

proc setstatus {st} {
    global flight jobinfo
    job-set-status $flight $jobinfo(job) $st
}

proc job-set-status {flight job st} {
    db-update-1 "
        UPDATE jobs SET status='$st'
            WHERE flight=$flight AND job='$job'
              AND status<>'aborted' AND status<>'broken'
    "
}

proc step-set-status {flight job stepno st} {
    db-update-1 "
        UPDATE steps SET status='$st'
            WHERE flight=$flight AND job='$job' AND stepno=$stepno
    "
}

proc reap-ts {reap} {
    if {![string length $reap]} { return 0 }

    upvar #0 reap_details($reap) details
    set detstr [lindex $details 3]
    set iffail [lindex $details 4]
    logputs stdout "awaiting $detstr"
    if {[catch { close $reap } emsg]} {
        set result $iffail
    } else {
        set result pass
    }

    eval step-set-status [lrange $details 0 2] $result
    logputs stdout "finished $detstr $result $emsg"
    return [expr {![string compare $result pass]}]
}
