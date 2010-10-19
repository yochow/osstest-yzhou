# -*- Tcl -*-

source osstestlib.tcl

proc chan-error {chan emsg} {
    puts-chan $chan "ERROR $emsg"
}

proc for-chan {chan script} {
    uplevel 1 [list upvar \#0 chandesc($chan) desc]
    upvar #0 chandesc($chan) desc
    if {[catch {
        uplevel 1 $script
    } emsg]} {
        catch { chan-error $chan $emsg }
        log "error: $desc: $emsg"
        chan-destroy-stuff $chan
        catch { close $chan }
    }
}

proc chan-read {chan} {
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
                eval $basel $rhs
            }
        }
        if {[eof $chan]} {
            puts-chan-desc $chan {$$}
            chan-destroy-stuff $chan
            close $chan
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
}

proc puts-chan {chan m} {
    upvar \#0 chandesc($chan) desc
    puts-chan-desc $chan ">> $m"
    puts $chan $m
}

proc newconn {chan addr port} {
    global chandesc
    set chandesc($chan) "\[$addr\]:$port"
    for-chan $chan {
        puts "$desc connected $chan"
        fcntl $chan KEEPALIVE 1
        fconfigure $chan -blocking false -buffering line -translation lf
        fileevent $chan readable [list chan-read $chan]
        puts-chan $chan [banner $chan]
    }
}

proc main-daemon {port setup} {
    global c argv

    foreach arg $argv {
        switch -glob -- $arg {
            --commandloop { commandloop -async }
            * { error "unknown arg $arg" }
        }
    }

    fconfigure stdout -buffering line
    fconfigure stderr -buffering none

    uplevel 1 $setup

    socket -server newconn -myaddr $c(ControlDaemonHost) $port
    log "listening $c(ControlDaemonHost):$port"

    vwait forever
}
