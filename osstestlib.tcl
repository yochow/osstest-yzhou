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

proc db-open {} {
    pg_connect -conninfo "dbname=osstestdb" -connhandle dbh
}

proc set-flight {} {
    global flight argv env

    set flight [lindex $argv 0]
    set env(OSSTEST_FLIGHT) $flight
}

proc run-ts {args} {
    set reap [eval spawn-ts $args]
    if {![reap-ts $reap]} { error "test script failed" }
}

proc spawn-ts {ts args} {
    global flight c jobinfo reap_details

    set detstr "$flight.$jobinfo(job) $ts $args"
    set details [list $flight $jobinfo(job) $ts $detstr]
    puts "starting $detstr"
    
    set logdir $c(Logs)/$flight.$jobinfo(job)
    file mkdir $logdir

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
                VALUES ($flight, '$jobinfo(job)', $stepno, '$ts', 'running')
        "
	pg_execute dbh COMMIT
    } emsg]} {
	global errorInfo errorCode
	set ei $errorInfo
	set ec $errorCode
	catch { pg_execute dbh ROLLBACK }
	error $emsg $ei $ec
    }

    set log $logdir/$stepno.$ts.log

    set cmd [concat \
                 [list sh -xec "
                     OSSTEST_JOB=$jobinfo(job)
                     export OSSTEST_JOB
                     exec \"$@\" >&2
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
    pg_execute dbh "
        INSERT INTO runvars VALUES
             ($flight, '$job', 'host', '$host', 'f')
    "
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
    puts "awaiting $detstr"
    if {[catch { close $reap } emsg]} {
        set result fail
    } else {
        set result pass
    }

    eval step-set-status [lrange $details 0 2] $result
    puts "finished $detstr $result $emsg"
    return [string compare $result fail]
}
