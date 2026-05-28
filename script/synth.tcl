# *************************************************************************
#
# Alveo U50 host — IP synthesis / output-product generation
#
# This script is the "heavy" half of the project build.  It opens
# the existing Vivado project (previously created by
# `script/build.tcl` via `make project`) and:
#
#   1. Runs `generate_target all [get_ips]` to emit the synthesis
#      and implementation output products (on top of the simulation
#      targets that `make project` already produced).  For BD-based
#      IPs like `cms_subsystem_0` this internally runs a block-
#      design synthesis and can take several minutes.
#
#   2. Launches every IP's out-of-context (OOC) synthesis run and
#      waits for completion.  This produces the per-IP .dcp files
#      that the top-level synth / impl flow needs.  Only triggered
#      if a synthesis run exists for the IP — some IPs (clk_wiz_*,
#      system_management_wiz, ...) are synthesized in-context and
#      have no dedicated run.
#
# The result is a project in which every IP has both simulation and
# synthesis output products, ready for a full top-level synth /
# impl flow.  The sim export flow under `sim/Makefile` does not
# need this — it only consumes the simulation targets, which are
# already produced by `make project`.
#
# Usage:
#   make synth          (from the repo root)
#   vivado -mode batch -source script/synth.tcl
#
# *************************************************************************

# =========================================================================
# Paths (kept in sync with build.tcl)
#
# Open the project via its canonical `/data/pdh4/...` path, not the
# `<repo>/build/` symlink.  Vivado stores file references relative to
# `$PPRDIR` (the directory containing the .xpr); those relative paths
# assume the canonical depth.  Opening via the symlink changes $PPRDIR's
# depth and breaks the `../../../..` traversal, producing duplicated
# path segments like `/home/pdh4/home/pdh4/...`.
# =========================================================================
set project_name    alveo_u50_host
set root_dir        [file normalize [file dirname [info script]]/..]
set build_storage   /data/pdh4/${project_name}_build
set project_dir     ${build_storage}/${project_name}
set xpr             ${project_dir}/${project_name}.xpr

if {![file exists $xpr]} {
    puts "ERROR: project file $xpr does not exist — run `make project` first"
    exit 1
}

# Board file repository (local copy for offline builds)
set board_repo ${root_dir}/board_files
if {[file exists ${board_repo}]} {
    set_param board.repoPaths [list ${board_repo}]
}

open_project $xpr

# =========================================================================
# Step 1: emit all remaining IP output products
# =========================================================================
puts ""
puts "============================================================"
puts " Generating all IP output products (synthesis + implementation)"
puts "============================================================"
generate_target all [get_ips]

# =========================================================================
# Step 2: launch OOC synthesis runs for every IP that has one
# =========================================================================
#
# Vivado auto-creates a per-IP OOC synthesis run named
# <ip>_synth_1 when the IP is configured for OOC synthesis.
# We enumerate those runs and launch them in parallel, then wait
# for completion.
# =========================================================================
set ip_runs [get_runs -quiet -filter {IS_SYNTHESIS == 1 && SRCSET != sources_1}]
if {[llength $ip_runs] > 0} {
    puts ""
    puts "============================================================"
    puts " Launching [llength $ip_runs] IP OOC synthesis run(s)"
    puts "============================================================"
    foreach r $ip_runs { puts "  $r" }
    reset_runs  $ip_runs
    launch_runs $ip_runs -jobs 110
    foreach r $ip_runs {
        wait_on_run $r
    }
} else {
    puts "No IP OOC synthesis runs found — nothing to synthesize."
}

close_project

puts ""
puts "============================================================"
puts " Synthesis done.  Project: $xpr"
puts "============================================================"
