# *************************************************************************
#
# Export Vivado's VCS compile/elaborate/simulate script for a named
# simulation fileset.  Called from sim/Makefile.
#
# Vivado emits a self-contained shell script under
# ${export_dir}/vcs/<top>.sh that walks every IP in the project in
# dependency order, invoking vhdlan / vlogan with the correct +incdir
# flags and `+define+SIMULATION +define+__au50__` on the user RTL (those
# defines come from the selected simset's `verilog_define` property,
# which is set in script/build.tcl).  The script uses absolute paths
# so it can be invoked from any working directory.
#
# Args:
#   xpr        — path to the Vivado .xpr project file
#   export_dir — output directory (e.g. sim/export_vcs,
#                sim/export_vcs_axil)
#   simlib_dir — root of the pre-compiled Xilinx VCS-MX sim library tree
#   simset     — (optional) Vivado simulation fileset to export, e.g.
#                sim_1 or sim_axil.  Defaults to sim_1 for backward
#                compatibility with the HBM-testbench flow.
#
# *************************************************************************
if {[llength $argv] < 3} {
    puts "usage: export_sim.tcl <project.xpr> <export_dir> <simlib_dir> \[simset\]"
    exit 1
}
set xpr        [lindex $argv 0]
set export_dir [lindex $argv 1]
set simlib_dir [lindex $argv 2]
set simset     [expr {[llength $argv] >= 4 ? [lindex $argv 3] : "sim_1"}]

open_project $xpr

# Make the requested simset the active one before exporting — Vivado
# exports whatever is current_fileset at export_simulation time.
current_fileset -simset [get_filesets $simset]

export_simulation \
    -simulator    vcs          \
    -absolute_path             \
    -force                     \
    -directory    $export_dir  \
    -lib_map_path $simlib_dir

close_project
