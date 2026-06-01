# *************************************************************************
#
# pncel-alveo Vivado project build script.
#
# Forked from script/build.tcl with the static region trimmed down to
# XDMA + system_config + minimal AXI splitters.  Everything that used to
# live in static (HBM, MMCM, proc_sys_reset, control-plane CDCs, the
# control-fanout switch, APB bridge) moves into the dynamic region as
# part of the RM body.
#
# Usage:
#   vivado -mode batch -source script/pncel_build.tcl
#   vivado -mode tcl   -source script/pncel_build.tcl
#   vivado -mode gui   -source script/pncel_build.tcl
#
# Environment:
#   DFX=0   build flat (default 1) — useful for elaboration smoke tests
#           before turning on the full partition flow.
#
# *************************************************************************

# =========================================================================
# Configuration
# =========================================================================
set project_name pncel_alveo
set top_module   pncel_top

set root_dir        [file normalize [file dirname [info script]]/..]
set src_dir         ${root_dir}/src
set constr_dir      ${root_dir}/constr/au50
set script_dir      ${root_dir}/script
set sim_dir         ${root_dir}/sim

# Project storage lives inside the working dir under `build/`.  Self-
# contained: no symlinks, no off-tree dependencies.
set build_dir       ${root_dir}/build
set project_dir     ${build_dir}/${project_name}

if {![file exists ${build_dir}]} {
    file mkdir ${build_dir}
}

set dfx [expr {[info exists ::env(DFX)] ? $::env(DFX) : 1}]

# Board settings (part, board_part)
source ${script_dir}/board_settings/au50.tcl

set board_repo ${root_dir}/board_files
if {[file exists ${board_repo}]} {
    set_param board.repoPaths [list ${board_repo}]
}

# =========================================================================
# Create project
# =========================================================================
create_project ${project_name} ${project_dir} -part ${part} -force
if {[llength [get_board_parts -quiet ${board_part}]] > 0} {
    set_property board_part ${board_part} [current_project]
} else {
    puts "WARNING: Board part ${board_part} not found; continuing with part only."
}
set_property target_language Verilog [current_project]

# =========================================================================
# Add RTL sources
# =========================================================================

# Interfaces (must be added first so other files see them)
add_files -norecurse [list \
    ${src_dir}/utility/axi_if.sv \
    ${src_dir}/utility/axi_lite_if.sv \
    ${src_dir}/utility/apb_if.sv \
]

# Utility modules — keep only the ones the minimal design needs.
add_files -norecurse [list \
    ${src_dir}/utility/axi_lite_register.sv \
    ${src_dir}/utility/axil_host_switch_wrapper.sv \
    ${src_dir}/utility/axi_dma_switch_wrapper.sv \
    ${src_dir}/utility/axi_dwidth_converter_0_wrapper.sv \
    ${src_dir}/utility/axi_apb_bridge_wrapper.sv \
    ${src_dir}/utility/axi_decoupler.sv \
]

# system_config (HBICAP + SYSMON + CMS + scfg-reg with REG_PR_CTRL)
add_files -norecurse [list \
    ${src_dir}/system_config/cms_subsystem_wrapper_if.sv \
    ${src_dir}/system_config/system_config_register.v \
    ${src_dir}/system_config/system_config.sv \
]

# PCIe / XDMA
add_files -norecurse [list \
    ${src_dir}/pcie/xdma_wrapper.sv \
]

# Aurora-bridge sources — host-side packetizer modules copied from the
# mini_dice_zcu102 design.  Used by pncel_dynamic_region to convert
# XDMA AXI4/AXI-Lite traffic into Aurora 64b/66b streams.
add_files -norecurse [list \
    ${src_dir}/aurora_bridge/axi_packetizer.sv \
    ${src_dir}/aurora_bridge/axi_depacketizer.sv \
    ${src_dir}/aurora_bridge/axi_aurora_responder.sv \
    ${src_dir}/aurora_bridge/aurora_r_receiver.sv \
    ${src_dir}/aurora_bridge/axi_lite_to_aurora.sv \
    ${src_dir}/aurora_bridge/axi_to_aurora.sv \
    ${src_dir}/aurora_bridge/axi_aurora_bridge_inv.sv \
]

# HBM removed — replaced with axi_crossbar_hbm_stub + axi_bram_ctrl_hbm_stub
# (64 KB BRAM) instantiated directly in pncel_dynamic_region.sv.

# pncel design top-levels — static, dynamic shim, dynamic region (RM
# body), and the synthesis top that stitches them with two decouplers.
add_files -norecurse [list \
    ${src_dir}/pncel_static.sv \
    ${src_dir}/pncel_dynamic.sv \
    ${src_dir}/pncel_dynamic_region.sv \
    ${src_dir}/pncel_top.sv \
]

set_property include_dirs ${src_dir} [current_fileset]
set_property top ${top_module}        [current_fileset]

# Stamp the BUILD_TIMESTAMP parameter on the top with the current epoch
# time so each `make project` produces a bitstream with a unique scfg_reg
# REG_BUILD_TIMESTAMP value.  Read it back from the host with
# host/read_bitstream_info.py to confirm which build is actually loaded.
# (Default in pncel_top.sv is 32'h01010000 — used only if this property
# isn't set.)
set BUILD_TS_HEX [format %08x [clock seconds]]
set_property generic "BUILD_TIMESTAMP=32'h${BUILD_TS_HEX}" [current_fileset]
puts "pncel_build.tcl: BUILD_TIMESTAMP = 32'h${BUILD_TS_HEX} ([clock format [clock seconds]])"

set_property verilog_define {__au50__} [current_fileset]

# =========================================================================
# Constraints
# =========================================================================
add_files -fileset constrs_1 -norecurse [list \
    ${constr_dir}/pins.xdc \
    ${constr_dir}/timing.xdc \
    ${constr_dir}/general.xdc \
    ${constr_dir}/debug.xdc \
]

set_property file_type        {TCL}                          [get_files ${constr_dir}/pins.xdc]
set_property USED_IN          {synthesis implementation}     [get_files ${constr_dir}/pins.xdc]
set_property PROCESSING_ORDER EARLY                          [get_files ${constr_dir}/pins.xdc]
set_property USED_IN          {implementation}               [get_files ${constr_dir}/debug.xdc]
set_property PROCESSING_ORDER LATE                           [get_files ${constr_dir}/debug.xdc]

# =========================================================================
# Create IP cores
# =========================================================================
# Helper that applies CONFIG.* in one dict, with a per-property fallback
# for IPs whose validator rejects part of the dict (see build.tcl line 236).
proc set_ip_properties_safe {ip_name props} {
    set ip [get_ips $ip_name]
    if {![catch {set_property -dict $props $ip}]} {
        return
    }
    for {set pass 1} {$pass <= 2} {incr pass} {
        foreach {prop val} $props {
            catch {set_property $prop $val $ip}
        }
    }
    foreach {prop val} $props {
        if {[catch {set_property $prop $val $ip} err]} {
            puts "WARNING: ${ip_name}: skipped ${prop} (${err})"
        }
    }
}

# system_config sub-IPs (HBICAP, CMS, SYSMON, etc.)
source ${src_dir}/system_config/vivado_ip/system_config_axi_crossbar.tcl
source ${src_dir}/system_config/vivado_ip/system_management_wiz.tcl
source ${src_dir}/system_config/vivado_ip/clk_wiz_50Mhz.tcl
source ${src_dir}/system_config/vivado_ip/cms_subsystem_0.tcl
source ${src_dir}/system_config/vivado_ip/axi_hbicap_0.tcl

# Static-side fabric IPs (data + control splitters, dwidth converter)
source ${src_dir}/utility/vivado_ip/axil_host_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_dma_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_dwidth_converter_0.tcl
source ${src_dir}/utility/vivado_ip/axi_lite_clock_converter.tcl

# Pncel-specific override on axi_dma_switch — bump from 1→2 to 1→3.
#   M00 (0x0_0000_0000 – 0x1_FFFF_FFFF, 8 GB) → aurora bridge (existing)
#   M01 (0x2_0000_0000 – 0x2_0000_FFFF, 64 KB) → HBICAP        (existing)
#   M02 (0x4_0000_0000 – 0x4_0FFF_FFFF, 256 MB) → HBM port 31  (NEW)
# 256-bit AXI4 output; HBM port is 33 b addr / 6 b ID — width adaptation
# happens in pncel_dynamic_region via axi_protocol_converter.
set_property -dict [list \
  CONFIG.NUM_MI                  {3}                      \
  CONFIG.M02_AXI_ADDR_WIDTH      {64}                     \
  CONFIG.M02_AXI_DATA_WIDTH      {256}                    \
  CONFIG.M02_AXI_PROTOCOL        {AXI4}                   \
  CONFIG.M02_SEG00_BASE_ADDR     {0x0000000400000000}     \
  CONFIG.M02_SEG00_HIGH_ADDR     {0x000000040FFFFFFF}     \
] [get_ips axi_dma_switch]

# Dynamic-side Aurora IPs.  clk_wiz_hbm generates the 100 MHz init_clk
# for Aurora's reset state machine + hbm_ref_clk; axi_clock_converter_data
# CDCs the XDMA 256 b AXI4 path from axi_aclk (250 MHz) into
# aurora_user_clk.  (axi_lite_clock_converter sourced above also handles
# the AXI-Lite CDC.)  axi_clock_converter_bram CDCs the
# aurora_user_clk → aclk on the AXI4 path that lands on the BRAM
# controller (axi_bram_ctrl_bram, fronted by axi_crossbar_bram).
source ${src_dir}/hbm/vivado_ip/clk_wiz_hbm.tcl
source ${src_dir}/aurora_bridge/axi_clock_converter_data.tcl
source ${src_dir}/aurora_bridge/axi_lite_clock_converter_aurora.tcl
source ${src_dir}/aurora_bridge/aurora_64b66b_0.tcl
# Debug-only ILA on the Aurora status pool (channel/lane up, hard/soft
# error, GT pll/powergood, CRC indicators, QPLL state).  Synth-only —
# pncel_dynamic_region drops the ILA + synchroniser block under
# SIMULATION since the sim stub doesn't model the link state in detail.
source ${src_dir}/aurora_bridge/vivado_ip/ila_aurora_status.tcl
source ${src_dir}/aurora_bridge/axi_dwidth_xdma_to_bridge.tcl
source ${src_dir}/aurora_bridge/axi_dwidth_bridge_to_hbm.tcl
source ${src_dir}/aurora_bridge/axi_clock_converter_bram.tcl
source ${src_dir}/hbm/vivado_ip/axi_crossbar_bram.tcl
source ${src_dir}/hbm/vivado_ip/axi_bram_ctrl_bram.tcl

# PCIe XDMA
source ${src_dir}/pcie/vivado_ip/xdma_0.tcl

# =========================================================================
# Partial Reconfiguration (DFX) setup
# =========================================================================
update_compile_order -fileset sources_1

if {$dfx} {
    set_property PR_FLOW TRUE [current_project]

    # New pblock — same SLR1 + SLR0-top-band fabric envelope, minus the
    # u_block_a/b/decouple_a/b nested children (this design has no
    # loopback engines and only two decouplers, both small enough to
    # leave to the placer).
    add_files -fileset constrs_1 -norecurse ${constr_dir}/pncel_pblock_dynamic.xdc
    set_property USED_IN {implementation} [get_files ${constr_dir}/pncel_pblock_dynamic.xdc]

    create_partition_def -name pncel_dynamic_region -module pncel_dynamic_region

    # Default RM = the scratch-pad pncel_dynamic_region itself.  Vivado
    # moves the source file into the new RM fileset; no extra files
    # required for this default RM.
    create_reconfig_module -name pncel_dynamic_region \
        -partition_def [get_partition_defs pncel_dynamic_region] \
        -define_from pncel_dynamic_region

    create_pr_configuration -name config_1 \
        -partitions [list dynamic_inst/u_region:pncel_dynamic_region]
    set_property PR_CONFIGURATION config_1 [get_runs impl_1]
}

# =========================================================================
# Phys-opt hook — same as the original build.tcl (loop until met after
# both place and route, max 10 iterations).
# =========================================================================
set phys_opt_hook [file normalize ${script_dir}/post_place_phys_opt.tcl]
if {[file exists $phys_opt_hook]} {
    foreach r [get_runs -quiet -filter {IS_IMPLEMENTATION == 1}] {
        set_property STEPS.PLACE_DESIGN.TCL.POST $phys_opt_hook $r
        set_property STEPS.ROUTE_DESIGN.TCL.POST $phys_opt_hook $r
    }
}

# Refresh compile order across every fileset (sources_1 + each RM) so
# the GUI's Sources panel shows the elaborated hierarchy on first open
# instead of "Hierarchy update needed".
foreach fs [get_filesets -filter {FILESET_TYPE =~ "*DesignSrc*" || FILESET_TYPE =~ "*BlockSrc*"} -quiet] {
    update_compile_order -quiet -fileset $fs
}

# =========================================================================
# Generate IP simulation models (consumed by `export_simulation -simulator
# vcs` from sim/Makefile).  No-op when IP cache already has the products.
# =========================================================================
generate_target simulation [get_ips]

# =========================================================================
# Simulation fileset (VCS flow lives under sim/, driven by sim/Makefile)
#
# The HBM testbench needs two things from Vivado's sim_1 fileset:
#
#   1. `tb_pncel_hbm.sv` registered as a simulation source so that
#      `export_simulation -simulator vcs` emits compile commands for it.
#   2. `+define+SIMULATION` on every vlogan call, so that pncel_top.sv,
#      pncel_static.sv, pncel_dynamic.sv, and pncel_dynamic_region.sv
#      take their testbench-mode port lists (XDMA + Aurora IPs replaced
#      by direct sim_axil / sim_axi_dma / sim_aurora_* inputs).
#
# `__au50__` is carried through for consistency with the synth path.
#
# Block runs AFTER IP generation — generate_target reloads sim_1 from
# disk and would silently discard any properties set earlier.
# =========================================================================
add_files -fileset sim_1 -norecurse [list \
    ${sim_dir}/tb_pncel_hbm.sv \
]
# Under DFX the RM body lives only in the partition fileset, not in
# sources_1 — but the TB instantiates pncel_top, which transitively
# needs the RM body to elaborate.  Add it explicitly to sim_1 so the
# sim flow works whether DFX is on or off.
if {$dfx} {
    add_files -fileset sim_1 -norecurse [list \
        ${src_dir}/pncel_dynamic_region.sv \
    ]
}
set_property top tb_pncel_hbm [get_filesets sim_1]
set_property verilog_define {SIMULATION __au50__} [get_filesets sim_1]
set_property include_dirs ${src_dir} [get_filesets sim_1]

# -------------------------------------------------------------------------
# Second simulation fileset — aurora packet-bridge TB.  Kept in its own
# simset so sim/Makefile can drive both TBs through separate export
# directories without juggling the "current" top.
# -------------------------------------------------------------------------
if {[llength [get_filesets -quiet sim_aurora]] == 0} {
    create_fileset -simset sim_aurora
}
add_files -fileset sim_aurora -norecurse [list \
    ${sim_dir}/tb_pncel_aurora.sv \
]
if {$dfx} {
    add_files -fileset sim_aurora -norecurse [list \
        ${src_dir}/pncel_dynamic_region.sv \
    ]
}
set_property top tb_pncel_aurora [get_filesets sim_aurora]
set_property verilog_define {SIMULATION __au50__} [get_filesets sim_aurora]
set_property include_dirs ${src_dir} [get_filesets sim_aurora]

# Flush sim fileset changes to the .xpr.  Vivado's batch-mode exit does
# not auto-save, so without close_project the sim/Makefile
# export_simulation step would see the project as if the blocks above
# had never run.
close_project

puts "============================================================"
puts "pncel_build.tcl: project created at"
puts "  ${project_dir}/${project_name}.xpr"
puts "Top: ${top_module}"
puts "DFX: ${dfx}"
puts "============================================================"
