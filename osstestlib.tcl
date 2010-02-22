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
                    AND   (name='host' OR name LIKE '%_host')
                  ORDER BY name
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
    if {![job-set-host $flight $job $c(Host)]} {
        return 0
    }
    return 1
}

proc run-ts {args} {
    set reap [eval spawn-ts $args]
    if {![reap-ts $reap]} { error "test script failed" }
}

proc spawn-ts {testid ts args} {
    global flight c jobinfo reap_details

    pg_execute dbh BEGIN
    if {[catch {
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

    regsub {^ts-} [join "$ts $args" /] {} deftestid
    if {![string compare $testid =]} {
        set testid deftestid
    } elseif {![string compare $testid *]} {
        set testid $deftestid//*
    }
    regsub {//\*$} $testid //$stepno testid

    pg_execute dbh "
        UPDATE steps SET testid=[pg_quote $testid]
            WHERE flight=$flight and stepno=$stepno
    "

    set detstr "$flight.$jobinfo(job) $ts $args"
    set details [list $flight $jobinfo(job) $ts $detstr]
    logputs stdout "starting $detstr"
    
    set logdir $c(Logs)/$flight.$jobinfo(job)
    file mkdir $logdir

    set log $logdir/$stepno.$ts.log

    set cmd [concat \
                 [list sh -xc "
                     OSSTEST_JOB=$jobinfo(job)
                     export OSSTEST_JOB
                     \"$@\" >&2
                     rc=\$?
                     date -u +\"%Y-%m-%d %H:%M:%S Z exit status \$rc\" >&2
                     exit \$rc
                 " x ./$ts] \
                 $args \
                 [list 2> $log < /dev/null]]
    set fh [open |$cmd r]
    set reap_details($fh) $details

    return $fh
}

proc setstatus {st} {
    global flight jobinfo
    job-set-status $flight $jobinfo(job) $st
}

proc job-set-host {flight job host} {
    pg_execute dbh BEGIN
    pg_execute -array hostinfo dbh "
        SELECT * FROM runvars WHERE
            flight=$flight AND job='$job' AND name='host'
    "
    if {[info exists hostinfo(val)]} {
        pg_execute dbh ROLLBACK
        if {[string length $host] && [string compare $hostinfo(val) $host]} {
            logputs stdout "wronghost $flight.$job $hostinfo(val)"
            return 0
        }
        return 1
    }
    pg_execute dbh "
        INSERT INTO runvars VALUES
             ($flight, '$job', 'host', '$host', 'f')
    "
    pg_execute dbh COMMIT
    return 1
}

proc job-set-status {flight job st} {
    pg_execute dbh "
        UPDATE jobs SET status='$st'
            WHERE flight=$flight AND job='$job'
    "
}

proc step-set-status {flight job ts st} {
    pg_execute dbh "
        UPDATE steps SET status='$st'
            WHERE flight=$flight AND job='$job' AND step='$ts'
    "
}

proc reap-ts {reap} {
    upvar #0 reap_details($reap) details
    set detstr [lindex $details 3]
    logputs stdout "awaiting $detstr"
    if {[catch { close $reap } emsg]} {
        set result fail
    } else {
        set result pass
    }

    eval step-set-status [lrange $details 0 2] $result
    logputs stdout "finished $detstr $result $emsg"
    return [string compare $result fail]
}
