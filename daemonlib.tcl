# -*- Tcl -*-

source osstestlib.tcl

proc chan-error {chan emsg} {
    regsub -all {\n} $emsg { / } emsg
    puts-chan $chan "ERROR $emsg"
}

proc chan-destroy {chan} {
    chan-destroy-stuff $chan
    foreach v {chandesc chan-data-len chan-data-data chan-data-then} {
	upvar #0 "${v}($chan)" $v
	catch { unset $v }
    }
    catch { close $chan }
}

proc for-chan {chan script} {
    uplevel 1 [list upvar \#0 chandesc($chan) desc]
    upvar #0 chandesc($chan) desc
    set rc [catch { uplevel 1 $script } emsg]
    global errorInfo errorCode
    if {$rc==1} {
        set d "?$chan"
        if {[info exists desc]} { set d $desc }
        log "error: $d: $errorCode: $emsg"
        foreach l [split $errorInfo "\n"] { log "EI $l" }
        catch { chan-error $chan $emsg }
        chan-destroy $chan
    } else {
        return -code $rc $emsg
    }
}

proc chan-read {chan} {
    upvar #0 chandesc($chan) desc
    for-chan $chan {
        while {[gets $chan l] > 0} {
            log "$desc << $l"
            if {![regexp {^([-0-9a-z]+)(?:\s+(.*))?$} $l dummy cmd rhs]} {
                chan-error $chan "bad cli cmd syntax"
                continue
            }
            if {[catch { set al [info args cmd/$cmd] } emsg]} {
                chan-error $chan "unknown command $emsg"
                continue
            }
            set basel [list cmd/$cmd $chan $desc]
            if {[llength $al]==2} {
                if {[string length $rhs]} { error "no arguments allowed" }
                eval $basel
            } elseif {[llength $al]==3 &&
                      ![string compare [lindex $al end] rhs]} {
                eval $basel [list $rhs]
            } else {
                if {[catch { set all [llength $rhs] } emsg]} {
                    chan-error $chan "bad list syntax $emsg"
                    continue
                }
                set alexp [lrange $al 2 end]
                if {![string compare [lindex $al end] args]} {
                    if {$all+2 < [llength $al]-1} {
                        chan-error $chan "too few args ($alexp)"
                        continue
                    }
                } else {
                    if {$all+2 != [llength $al]} {
                        chan-error $chan "wrong number of args ($alexp)"
                        continue
                    }
                }
                eval $basel [lreplace $rhs -1 -1]
            }
            if {![info exists desc]} return
        }
        if {[eof $chan]} {
            puts-chan-desc $chan {$$}
            chan-destroy $chan
        }
    }
}

proc puts-chan-desc {chan m} {
    upvar \#0 chandesc($chan) desc
    log "$desc $m"
}

proc must-gets-chan {chan re} {
    if {[gets $chan l] <= 0} { error "NOT $chan $re ?" }
    puts-chan-desc $chan "<< $l"
    if {![regexp $re $l]} { error "NOT $chan $re $l ?" }
    return $l
}

proc puts-chan {chan m} {
    upvar \#0 chandesc($chan) desc
    puts-chan-desc $chan ">> $m"
    puts $chan $m
}

#---------- data ----------

proc puts-chan-data {chan m data} {
    puts-chan $chan "$m [string length $data]"
    puts -nonewline $chan $data
    flush $chan
    puts-chan-desc $chan ">\[data]"
}

proc read-chan-data {chan bytes args} {
    upvar #0 chan-data-len($chan) len
    set len [expr {$bytes + 0}]

    if {$len < 0 && $len > 65536} {
	chan-error "bytes out of range"
	return
    }
    upvar #0 chan-data-data($chan) data
    set data {}

    upvar #0 chan-data-then($chan) then
    set then $args

    puts-chan $chan SEND
    fileevent $chan readable [list chan-read-data $chan]
    chan-read-data $chan
}

proc chan-read-data {chan} {
    upvar #0 chandesc($chan) desc
    upvar #0 chan-data-len($chan) len
    upvar #0 chan-data-data($chan) data
    upvar #0 chan-data-then($chan) then

    for-chan $chan {
	while {$len>0} {
	    set got [read $chan $len]
	    if {[eof $chan]} {
		puts-chan-desc $chan {$$(data)}
		chan-destroy $chan
		return
	    }
	    append data $got
	    incr len -[string length $got]
	}
	fileevent $chan readable [list chan-read $chan]
	puts-chan-desc $chan "<\[data]"
	eval $then [list $chan $desc $data]
    }
}

#---------- main ----------

proc newconn {chan addr port} {
    global chandesc
    set chandesc($chan) "\[$addr\]:$port"
    for-chan $chan {
        log "$desc connected $chan"
        fcntl $chan KEEPALIVE 1
        fconfigure $chan -blocking false -buffering line -translation lf
        fileevent $chan readable [list chan-read $chan]
        puts-chan $chan [banner $chan]
    }
}

proc main-daemon {port setup} {
    global c argv

    set host $c(ControlDaemonHost)

    foreach arg $argv {
        switch -glob -- $arg {
            --commandloop { commandloop -async }
            --host=* { regsub {^.*=} $arg {} host }
            --port=* { regsub {^.*=} $arg {} port }
            * { error "unknown arg $arg" }
        }
    }

    fconfigure stdout -buffering line
    fconfigure stderr -buffering none

    log "starting"

    uplevel 1 $setup

    socket -server newconn -myaddr $host $port
    log "listening $host:$port"

    vwait forever
}
