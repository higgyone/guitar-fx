# Rebuilds the guitar-fx Vivado project into build/vivado/ (gitignored).
#
# The project is not tracked in git: this script is the source of truth, so
# both PCs build the same project from the same files. Sources are added by
# reference (not copied), so edits in rtl/ and sim/ show up in Vivado as is.
#
# Run from the repo root, either:
#   vivado -mode batch -source scripts/create_project.tcl
# or in the Vivado Tcl console:
#   cd D:/Repos/guitar-fx
#   source scripts/create_project.tcl
# then open build/vivado/guitar-fx.xpr.
#
# Re-running it deletes and rebuilds the project (-force). Anything set only
# in the GUI is lost, so put lasting settings here.

set repo_dir  [file normalize [file join [file dirname [info script]] ..]]
set proj_name guitar-fx
set proj_dir  [file join $repo_dir build vivado]

# Arty A7-35T. No board part: Vivado 2025.2 has no Arty board files
# installed, and a VHDL-only project doesn't need them.
set part xc7a35ticsg324-1L

create_project $proj_name $proj_dir -part $part -force
set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# Adds every .vhd in a repo folder to a fileset as VHDL-2008.
# Globbed, so a new file is picked up by re-running this script.
proc add_vhdl_dir {fileset dir} {
    set files [lsort [glob -nocomplain -directory $dir *.vhd]]
    if {[llength $files] == 0} {
        puts "INFO: no .vhd files in $dir"
        return
    }
    add_files -norecurse -fileset $fileset $files
    set_property file_type {VHDL 2008} [get_files $files]
    if {$fileset eq "sim_1"} {
        set_property used_in_synthesis false [get_files $files]
    }
    puts "INFO: added [llength $files] file(s) from $dir to $fileset"
}

# Design sources (rtl/) and testbenches (sim/). Testbenches go only in
# sim_1, so synthesis never sees them.
add_vhdl_dir sources_1 [file join $repo_dir rtl]
add_vhdl_dir sim_1     [file join $repo_dir sim]

# Constraints: the Digilent master XDC, pins uncommented as they're used.
set xdc_files [lsort [glob -nocomplain -directory [file join $repo_dir constraints] *.xdc]]
if {[llength $xdc_files] > 0} {
    add_files -norecurse -fileset constrs_1 $xdc_files
}

# Clocking Wizard: 100 MHz board clock -> 98.304 MHz system clock (actual
# 98.305: MMCM x7.25 = 725 MHz VCO, /7.375). One clock domain for the whole
# design; MCLK/SCLK/LRCK are divided from it in i2s_clocks (docs/i2s.md §3)
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_audio
set_property -dict [list \
  CONFIG.CLKOUT1_JITTER {146.903} \
  CONFIG.CLKOUT1_PHASE_ERROR {119.384} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {98.30508} \
  CONFIG.MMCM_CLKFBOUT_MULT_F {7.250} \
  CONFIG.MMCM_CLKOUT0_DIVIDE_F {7.375} \
] [get_ips clk_wiz_audio]

# Self-checking testbenches stop themselves (std.env.finish), so run to the
# end instead of the default 1000 ns.
set_property -name xsim.simulate.runtime -value all -objects [get_filesets sim_1]

# Top levels: 
set_property top top [get_filesets sources_1]
set_property top top_tb [get_filesets sim_1]
foreach fs {sources_1 sim_1} {
    # Skip empty filesets (no top to find, just a critical warning).
    if {[llength [get_files -quiet -of_objects [get_filesets $fs] *.vhd]] > 0} {
        update_compile_order -fileset $fs
    }
}

puts "INFO: project ready: [file join $proj_dir $proj_name.xpr]"
