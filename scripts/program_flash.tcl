# program_flash.tcl: writes the latest build into the Arty's QSPI flash.
#
# Run from the Vivado Tcl console (any project, or none):
#   cd D:/Repos/guitar-fx
#   source scripts/program_flash.tcl
# Then unplug and replug the USB, and check with fx.py read version.
# What it replaces: the manual steps in docs/qspi_boot.md.

# Where the repo is: this script's folder, then one level up.
set repo_dir [file normalize [file join [file dirname [info script]] ..]]

# The file to program, built from the repo path (never a remembered path).
set bin_file [file join $repo_dir build vivado guitar-fx.runs impl_1 top.bin]

# Stop at once if there's no build.
if {![file exists $bin_file]} {
    error "no $bin_file: run Generate Bitstream first"
}

# Show which file, and when it was built.
set built [clock format [file mtime $bin_file] -format "%d/%m/%Y %H:%M"]
puts "programming $bin_file (built $built)"

# Connect to the board (the same as Open Target -> Auto Connect). Each step
# is skipped if the Hardware Manager is already connected.
open_hw_manager
if {[llength [get_hw_servers -quiet]] == 0} {
    connect_hw_server -allow_non_jtag
}
# The FPGA only shows up once the target is open, so "no devices" means
# "not open yet" (current_hw_target alone isn't enough: it names the board
# even before it's opened).
if {[llength [get_hw_devices -quiet]] == 0} {
    open_hw_target
}

# The FPGA on the board's JTAG chain.
set fpga [get_hw_devices xc7a35t_0]
current_hw_device $fpga
refresh_hw_device -update_hw_probes false $fpga
puts "connected to $fpga"

# The flash chip, attached to the FPGA (Add Configuration Memory Device).
# Reuse it if the Hardware Manager already has it; add it if not (it can
# vanish after create_project.tcl rebuilds the project).
set flash [get_property PROGRAM.HW_CFGMEM $fpga]
if {$flash eq ""} {
    set part [lindex [get_cfgmem_parts {mt25ql128-spi-x1_x2_x4}] 0]
    set flash [create_hw_cfgmem -hw_device $fpga $part]
}

# What to do (the Program Configuration Memory Device dialog's options).
set_property PROGRAM.FILES         [list $bin_file] $flash
set_property PROGRAM.ADDRESS_RANGE {use_file}       $flash
set_property PROGRAM.ERASE         1                $flash
set_property PROGRAM.CFG_PROGRAM   1                $flash
set_property PROGRAM.VERIFY        1                $flash
set_property PROGRAM.BLANK_CHECK   0                $flash
set_property PROGRAM.CHECKSUM      0                $flash
puts "flash: $flash, file [get_property PROGRAM.FILES $flash]"

# The FPGA can't reach the flash on its own over JTAG: Vivado first loads a
# small helper design into the FPGA that bridges JTAG to the flash pins
# (so the effect stops while the flash is written).
create_hw_bitstream -hw_device $fpga [get_property PROGRAM.HW_CFGMEM_BITFILE $fpga]
program_hw_devices $fpga
refresh_hw_device $fpga

# Erase, program and verify the flash (stops with an error if any fails).
program_hw_cfgmem -hw_cfgmem $flash
puts "flash programmed and verified"

# Reload the FPGA from the flash (the same as pressing PROG).
boot_hw_device $fpga
puts "booting from flash: check with fx.py read version"
