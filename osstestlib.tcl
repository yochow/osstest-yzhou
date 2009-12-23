# -*- Tcl -*-

package require Pgtcl 1.5

proc readconfig {} {
    uplevel #0 source config.tcl
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
    set details [list $flight $jobinfo(job) $detstr]
    puts "starting $detstr"
    
    set logdir $c(logs)/$flight.$jobinfo(job)
    file mkdir $logdir
    set log $logdir/$ts.log

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

proc reap-ts {reap} {
    upvar #0 reap_details($reap) details
    set detstr [lindex $details 2]
    puts "awaiting $detstr"
    if {[catch { close $reap } emsg]} {
        set result fail
    } else {
        set result pass
    }

    eval job-set-status [lrange $details 0 1] $result
    puts "finished $detstr $result $emsg"
    return [string compare $result fail]
}
