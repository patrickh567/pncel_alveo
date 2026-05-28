# *************************************************************************
#
# Open the Vivado project in GUI mode with the AU50 board repo loaded.
#
# Usage: vivado -source script/open_gui.tcl
# Or:    make gui
#
# `board.repoPaths` is a session-level Tcl param that must be set before
# the project is opened, otherwise Vivado can't resolve
# `xilinx.com:au50:part0:1.3`, silently blanks the BoardPart property on
# save, and every AU50-customised IP becomes locked.  Opening the .xpr
# directly with `vivado <xpr>` hits this trap — always route through this
# script (or `make gui`) instead.
#
# *************************************************************************

set project_name    alveo_u50_host
set root_dir        [file normalize [file dirname [info script]]/..]
set build_storage   /data/pdh4/${project_name}_build
set xpr             ${build_storage}/${project_name}/${project_name}.xpr

set board_repo      ${root_dir}/board_files
if {[file exists ${board_repo}]} {
    set_param board.repoPaths [list ${board_repo}]
}

if {![file exists ${xpr}]} {
    puts "ERROR: project file ${xpr} does not exist — run `make project` first"
    exit 1
}

start_gui
open_project ${xpr}
