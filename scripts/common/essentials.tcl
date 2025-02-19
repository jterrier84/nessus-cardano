
# Essential utility procs ######################################################
#

set LEVEL_DEBUG 1
set LEVEL_INFO  2
set LEVEL_WARN  3
set LEVEL_ERROR 4

proc argsInit {spec argv} {
  if {[llength $argv] == 0} { error "Must provide required args: $spec"}
  for {set i 0} {$i < [llength $argv]} {incr i} {
    set key [lindex $argv $i]
    set val [lindex $argv [expr {$i + 1}]]
    set isNextKey [string match "--*" $val]
    if { $isNextKey } { set val true } else { incr i }
    dict set spec $key value $val
  }
  set errorCount 0
  foreach key [dict keys $spec] {
    set subdct [dict get $spec $key]
    set isRequired [expr {[dict exists $subdct required] && [dict get $subdct required]}]
    if {$isRequired && ![dict exists $subdct value]} {
      logError "No value for required arg: $key"
      incr errorCount
    }
  }
  if {$errorCount > 0} { error "Invalid args: $argv" }
  logDebug "Process $spec"
  return $spec
}

proc argsValue {args key {default ""}} {
  set result $default
  if [dict exists $args $key value] {
    set result [dict get $args $key value]
    if {$result == ""} { set result $default }
  }
  return $result
}

proc argsValueExists {args key} {
  dict exists $args $key value
}

proc envvar {vname {default ""}} {
  set result $default
  catch { set result "$::env($vname)" }
  return $result
}

proc fileRead {fpath} {
  set infile [open $fpath "r"]
  set result [read $infile]
  close $infile
  return $result
}

proc fileWrite {fpath content} {
  set outfile [open $fpath "w"]
  puts $outfile $content
  close $outfile
}

proc getSectionHeader {title} {
  set padding ""
  while {[string length "$title $padding"] < 120} {
    set padding "$padding="
  }
  return "$title $padding"
}

proc isNetwork {network} {
  global BLOCKFROST_NETWORK
  expr {$BLOCKFROST_NETWORK == $network}
}

proc logDebug {message} {
  global LEVEL_DEBUG
  logMessage $LEVEL_DEBUG $message
}

proc logInfo {message} {
  global LEVEL_INFO
  logMessage $LEVEL_INFO $message
}

proc logWarn {message} {
  global LEVEL_WARN
  logMessage $LEVEL_WARN $message
}

proc logError {message} {
  global LEVEL_ERROR
  logMessage $LEVEL_ERROR $message
}

proc logMessage {level message} {
  global LOG_LEVEL
  switch $level {
      1   {set lname "DEBUG"}
      2   {set lname "INFO"}
      3   {set lname "WARN"}
      4   {set lname "ERROR"}
  }
  if {$LOG_LEVEL <= $level} {
    set now [clock seconds]
    set tstamp [clock format $now -format {%d-%m-%Y %H:%M:%S}]
    puts "\[$tstamp\] $lname $message"
  }
}

# Split and trim
proc splitTrim {instr {ch " "}} {
  set result [list]
  foreach tok [split $instr $ch] {
    set tok [string trim $tok]
    if {$tok != ""} {
      lappend result $tok
    }
  }
  return $result
}
