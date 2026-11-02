# --------------------------------------------------------------------------
# polly2-rtl - Vivado testing project: place-and-route + time the polly2 render
# core as the DE10 build integrates it (simplex_pvr_top: peel_core + its DDR
# read master + the vo framebuffer write-out, RAS_LANES 8), through the
# polly2_rtl_test harness in this directory (register-fed inputs -> core ->
# raw output capture -> one XOR-folded `digest` pin; the pattern of caique-rtl's
# testing projects). The fileset is read from the DE10 project's
# quartus/polly2/polly2.qip, in its order, keeping every polly2-core file and
# simplex_pvr_top and dropping the board layer (sys_top, HPS bridges, spg,
# audio, clock mux, PLLs), so the core is the one the DE10 bitstream builds.
#
# Part: Kria K26 SOM, xck26-sfvc784-2LV-c, board kr260_som 2.0 (Vivado 2026.1
# defaults for synthesis and implementation), as caique-rtl's.
#
# This script creates polly2-rtl.xpr in its own directory (replacing an
# existing one, runs included); the generated project is git-ignored.
#   GUI:   Tools > Run Tcl Script... > create_project.tcl, then Run Synthesis /
#          Run Implementation
#   batch: vivado -mode batch -source create_project.tcl
#          vivado -mode batch -source create_project.tcl -tclargs build
#            (also synthesises and implements, to route_design, and writes
#             reports/: utilization, hierarchical utilization, RAM
#             utilization, timing summary, Fmax)
# --------------------------------------------------------------------------

set here  [file normalize [file dirname [info script]]]
set name  polly2-rtl
set root  [file normalize [file join $here .. .. ..]]
set qprj  [file join $root quartus polly2]
set core  [file join $root polly2-core]
# board-layer files the harness instantiates (the rest of polly2-de10nano is the board top)
set board_keep {simplex_pvr_top.sv}

create_project $name $here -part xck26-sfvc784-2LV-c -force
if {[catch {set_property board_part xilinx.com:kr260_som:part0:2.0 [current_project]} err]} {
    puts "WARNING: board part kr260_som 2.0 is not installed ($err); the project uses the part alone"
}
set_property target_language Verilog [current_project]

# ---- sources: the DE10 project's fileset, in its order ----
set srcs {}
set kept {}
set fh [open [file join $qprj polly2.qip]]
foreach line [split [read $fh] "\n"] {
    if {[regexp {^set_global_assignment -name SYSTEMVERILOG_FILE (\S+)} $line -> f]} {
        set p [file normalize [file join $qprj $f]]
        set in_core  [expr {[string first "$core/" $p] == 0}]
        set in_board [expr {[lsearch -exact $board_keep [file tail $p]] >= 0}]
        if {!$in_core && !$in_board} { continue }
        if {$in_board} { lappend kept [file tail $p] }
        if {![file exists $p]} { error "$name: $p (from polly2.qip) does not exist" }
        lappend srcs $p
    }
}
close $fh
foreach f $board_keep {
    if {[lsearch -exact $kept $f] < 0} { error "$name: $f is not in polly2.qip" }
}
lappend srcs [file join $here polly2_rtl_test.sv]
add_files -norecurse -fileset sources_1 $srcs
set_property file_type SystemVerilog [get_files $srcs]
# tsp_pkg's `include "pvr_regs_gen.svh" (polly2.qsf's SEARCH_PATH)
set_property include_dirs [list [file join $core rtl gen]] [get_filesets sources_1]
# simulation-only code ($display statistics, plusarg switches, debug probes) is under `ifndef SYNTHESIS
set_property verilog_define {SYNTHESIS=1} [get_filesets sources_1]
set_property top polly2_rtl_test [get_filesets sources_1]
update_compile_order -fileset sources_1

# ---- constraints ----
add_files -norecurse -fileset constrs_1 [file join $here $name.xdc]

# ---- optional: build and report ----
if {[lsearch -exact $argv build] >= 0} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "$name: synthesis failed" }
    launch_runs impl_1 -jobs 4
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "$name: implementation failed" }
    open_run impl_1
    set rep [file join $here reports]
    file mkdir $rep
    report_utilization -file [file join $rep utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 6 -file [file join $rep utilization_hier.rpt]
    if {[catch {report_ram_utilization -file [file join $rep ram_utilization.rpt]} err]} {
        puts "WARNING: report_ram_utilization failed ($err)"
    }
    report_timing_summary -max_paths 10 -file [file join $rep timing_summary.rpt]
    set wns  [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
    set per  [get_property PERIOD [get_clocks clk]]
    set line [format "%s: WNS %.3f ns at %.3f ns -> Fmax %.2f MHz" $name $wns $per [expr {1000.0 / ($per - $wns)}]]
    puts $line
    set fh [open [file join $rep fmax.txt] w]; puts $fh $line; close $fh
}
