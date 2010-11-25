# -*- Tcl -*-

package require Tclx
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

proc log {m} {
    set now [clock seconds]
    set timestamp [clock format $now -format {%Y-%m-%d %H:%M:%S Z} -gmt 1]
    puts "$timestamp $m"
}

proc logputs {f m} {
    global argv
    set time [clock format [clock seconds] -gmt true \
                  -format "%Y-%m-%d %H:%M:%S Z"]
    puts $f "$time \[$argv] $m"
}

proc db-open {} {
    global env dbusers

    if {![info exists dbusers]} { set dbusers 0 }
    if {$dbusers > 0} { incr dbusers; return }

    set conninfo "dbname=osstestdb"
    foreach e {DBI_HOST DBI_PASS DBI_USER} \
	    p {host password user} {
		if {![info exists env($e)]} continue
		append conninfo " $p=$env($e)"
	    }
    pg_connect -conninfo $conninfo -connhandle dbh
    incr dbusers
}
proc db-close {} {
    global dbusers
    incr dbuser -1
    if {$dbusers > 0} return
    if {$dbusers} { error "$dbusers ?!" }
    pg_disconnect dbh
}

proc db-update-1 {stmt} {
    # must be in transaction
    set nrows [pg_execute dbh $stmt]
    if {$nrows != 1} { error "$nrows != 1 in < $stmt >" }
}

proc set-flight {} {
    global flight argv env

    if {[string equals [lindex $argv 0] --start-delay]} {
        after [lindex $argv 1]
        set argv [lrange $argv 2 end]
    }

    set flight [lindex $argv 0]
    set argv [lrange $argv 1 end]
    set env(OSSTEST_FLIGHT) $flight
}

proc prepare-job {job} {
    # must be outside any transaction, or with flights locked
    global flight argv c
    set desc "$flight.$job"

    db-open

    foreach constraint $argv {
        if {[regexp {^--jobs=(.*)$} $constraint dummy jobs]} {
            if {[lsearch -exact [split $jobs ,] $job] < 0} {
                logputs stdout "suppress $desc (jobs)"
                db-close
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
                db-close
                return 0
            }
        } else {
            error "unknown constraint $constraint"
        }
    }

    logputs stdout "prepping $desc"
    db-close
    return 1
}

proc specific-job-constraint {} {
    global argv
    foreach constraint $argv {
        if {[regexp {^--jobs=([^,]+)$} $constraint dummy job]} {
            return "AND job = [pg_quote $job]"
        }
    }
    return ""
}

proc run-ts {args} {
    set reap [eval spawn-ts $args]
    if {![reap-ts $reap]} { error "test script failed" }
}

proc lock-tables {tables} {
    # must be inside transaction
    foreach tab $tables {
        pg_execute dbh "
		LOCK TABLE $tab IN ACCESS EXCLUSIVE MODE
        "
    }
}

proc spawn-ts {iffail testid ts args} {
    # must be outside any transaction
    global flight c jobinfo reap_details env

    if {[file exists abort]} {
        logputs stdout \
            "aborting - not executing $flight.$jobinfo(job) $ts $args"
        job-set-status $flight $jobinfo(job) aborted
        return {}
    }

    if {![string compare . $iffail]} { set iffail fail }

    db-open

    pg_execute dbh BEGIN
    pg_execute dbh "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
    if {[catch {
        lock-tables flights
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
        db-close
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
    
    transaction flights {
        db-update-1 "
            UPDATE steps
                  SET testid=[pg_quote $testid],
                      started=[clock seconds]
                WHERE flight=$flight
                  AND job=[pg_quote $jobinfo(job)]
                  AND stepno=$stepno
        "
    }

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

    db-close
    return $fh
}

proc setstatus {st} {
    global flight jobinfo
    job-set-status $flight $jobinfo(job) $st
}

proc job-set-status-unlocked {flight job st} {
    db-open
    pg_execute dbh "
            UPDATE jobs SET status='$st'
                WHERE flight=$flight AND job='$job'
                  AND status<>'aborted' AND status<>'broken'
    "
    db-close
}

proc job-set-status {flight job st} {
    transaction flights {
        job-set-status-unlocked $flight $job $st
    }
}

proc step-set-status {flight job stepno st} {
    transaction flights {
        db-update-1 "
            UPDATE steps
               SET status='$st',
                   finished=[clock seconds]
             WHERE flight=$flight AND job='$job' AND stepno=$stepno
        "
        set pause 0
        pg_execute -array stopinfo dbh "
            SELECT val FROM runvars
             WHERE flight=$flight AND job='$job'
               AND name='pause_on_$st'
        " {
            pg_execute -array stepinfo dbh "
                SELECT * FROM steps
                 WHERE flight=$flight AND job='$job' AND stepno=$stepno
            " {
                foreach col {step testid} {
                    if {![info exists stepinfo($col)]} continue
                    foreach pat [split $stopinfo(val) ,] {
                        if {[string match $pat $stepinfo($col)]} {
                            set pause 1
                        }
                    }
                }
            }
        }
    }
    if {$pause} {
        logputs stdout "PAUSING as requested"
        catch { exec sleep 86400 }
    }
}

proc reap-ts {reap {dbopen 0}} {
    if {![string length $reap]} { if {$dbopen} db-open; return 0 }

    upvar #0 reap_details($reap) details
    set detstr [lindex $details 3]
    set iffail [lindex $details 4]
    logputs stdout "awaiting $detstr"
    if {[catch { close $reap } emsg]} {
        set result $iffail
    } else {
        set result pass
    }
    if {$dbopen} db-open

    eval step-set-status [lrange $details 0 2] $result
    logputs stdout "finished $detstr $result $emsg"
    return [expr {![string compare $result pass]}]
}

proc transaction {tables script} {
    db-open
    while 1 {
        set ol {}
        pg_execute dbh BEGIN
        pg_execute dbh "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
        lock-tables $tables
	set rc [catch { uplevel 1 $script } result]
	if {!$rc} {
	    if {[catch {
		pg_execute dbh COMMIT
	    } emsg]} {
		puts "commit failed: $emsg; retrying ..."
		pg_execute dbh ROLLBACK
		after 500
		continue
	    }
	} else {
	    pg_execute dbh ROLLBACK
	}
        db-close
	return -code $rc $result
    }
}

proc become-task {comment} {
    global env c
    if {[info exists env(OSSTEST_TASK)]} return

    set ownerqueue [socket $c(ControlDaemonHost) $c(OwnerDaemonPort)]
    fconfigure $ownerqueue -buffering line -translation lf
    must-gets $ownerqueue {^OK ms-ownerdaemon\M}
    puts $ownerqueue create-task
    must-gets $ownerqueue {^OK created-task (\d+) (\w+ [\[\]:.0-9a-f]+)$} \
        taskid refinfo
    fcntl $ownerqueue CLOEXEC 0
    set env(OSSTEST_TASK) "$taskid $refinfo"

    set hostname [info hostname]
    regsub {\..*} $hostname {} hostname
    set username "[id user]@$hostname"

    transaction resources {
        set nrows [pg_execute dbh "
            UPDATE tasks
               SET username = [pg_quote $username],
                   comment = [pg_quote $comment]
             WHERE taskid = $taskid
               AND type = [pg_quote [lindex $refinfo 0]]
               AND refkey = [pg_quote [lindex $refinfo 1]]
        "]
    }
    if {$nrows != 1} {
        error "$nrows $taskid $refinfo ?"
    }
}

proc must-gets {chan regexp args} {
    if {[gets $chan l] <= 0} { error "[eof $chan] $regexp" }
    if {![uplevel 1 [list regexp $regexp $l dummy] $args]} {
        error "$regexp $l ?"
    }
}

proc lremove {listvar item} {
    upvar 1 $listvar list
    set ix [lsearch -exact $list $item]
    if {$ix<0} return
    set list [lreplace $list $ix $ix]
}
