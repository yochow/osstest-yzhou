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
    reap-ts $reap
}

proc spawn-ts {ts args} {
    global flight c jobinfo reap_details

    set details "$flight.$jobinfo(job) $ts $args"
    puts "starting $details"
    
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

proc reap-ts {reap} {
    upvar #0 reap_details($reap) details
    puts "awaiting $details"
    close $reap
    puts "finished $details ok"
}
