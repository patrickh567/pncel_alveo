# *************************************************************************
#
# mini_dice_alveo Vivado project build script.
#
# Variant of script/pncel_build.tcl that:
#   - Builds the new mini_dice_alveo top (chip-on-BRAM, no Aurora)
#   - Reuses pncel_static.sv (XDMA + system_config) verbatim
#   - Drops all aurora-bridge sources + aurora IP TCLs
#   - Drops the old pncel_top.sv / pncel_dynamic.sv / pncel_dynamic_region.sv
#   - Adds the new BRAM-side IPs (axi_dwidth_l3_to_bram, axi_crossbar_alveo,
#     axi_bram_ctrl_alveo)
#
# FRAMEWORK PASS: the chip stack (mini_dice_top + cache_hierarchy +
# packet plumbing + axi_lite_fifo) is NOT yet wired in.  The dynamic
# region stubs s_axi_data and s_axil_ctrl and exercises only the
# XDMA → s_axi_hbm → crossbar → BRAM path.  Once this framework
# elaborates clean, the next pass adds the zcu102 RTL + Vortex +
# Mini_Dice_Backend trees and connects the chip's L3 master to the
# crossbar SI[0].
#
# Usage:
#   vivado -mode batch -source script/mini_dice_alveo_build.tcl
#
# Environment:
#   DFX=0   build flat (default 1) — useful for elaboration smoke tests
#           before turning on the full partition flow.
#
# *************************************************************************

set project_name mini_dice_alveo
set top_module   mini_dice_alveo

set root_dir        [file normalize [file dirname [info script]]/..]
set src_dir         ${root_dir}/src
set constr_dir      ${root_dir}/constr/au50
set script_dir      ${root_dir}/script
set sim_dir         ${root_dir}/sim

set build_dir       ${root_dir}/build
set project_dir     ${build_dir}/${project_name}

if {![file exists ${build_dir}]} {
    file mkdir ${build_dir}
}

set dfx [expr {[info exists ::env(DFX)] ? $::env(DFX) : 0}]

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

# Interfaces first
add_files -norecurse [list \
    ${src_dir}/utility/axi_if.sv \
    ${src_dir}/utility/axi_lite_if.sv \
    ${src_dir}/utility/apb_if.sv \
]

# Utility modules
add_files -norecurse [list \
    ${src_dir}/utility/axi_lite_register.sv \
    ${src_dir}/utility/axil_host_switch_wrapper.sv \
    ${src_dir}/utility/axi_dma_switch_wrapper.sv \
    ${src_dir}/utility/axi_dwidth_converter_0_wrapper.sv \
    ${src_dir}/utility/axi_apb_bridge_wrapper.sv \
    ${src_dir}/utility/axi_decoupler.sv \
]

# system_config (reused from pncel)
add_files -norecurse [list \
    ${src_dir}/system_config/cms_subsystem_wrapper_if.sv \
    ${src_dir}/system_config/system_config_register.v \
    ${src_dir}/system_config/system_config.sv \
]

# PCIe / XDMA
add_files -norecurse [list \
    ${src_dir}/pcie/xdma_wrapper.sv \
]

# Chip-side RTL trees pulled in from the zcu102 image.
#   ZCU_ROOT, BSG_ROOT, DICE_BACKEND, DICE_CGRA — env-overridable like in
#   combined_sim/scripts/create_project.tcl.
set ZCU_ROOT     [expr {[info exists ::env(ZCU_ROOT)] \
                          ? [file normalize $::env(ZCU_ROOT)] \
                          : [file normalize "${root_dir}/../mini_dice_zcu102"]}]
set BSG_ROOT     [expr {[info exists ::env(BSG_ROOT)] \
                          ? [file normalize $::env(BSG_ROOT)] \
                          : [file normalize "~/repos/basejump_stl"]}]
set DICE_BACKEND [expr {[info exists ::env(DICE_BACKEND)] \
                          ? [file normalize $::env(DICE_BACKEND)] \
                          : [file normalize "~/repos/Mini_Dice_Backend"]}]
set DICE_ROOT    [file normalize "${DICE_BACKEND}/Mini_Dice/rtl"]
set DICE_CGRA    [expr {[info exists ::env(DICE_CGRA)] \
                          ? [file normalize $::env(DICE_CGRA)] \
                          : [file normalize "${DICE_BACKEND}/Mini_Dice/dora/examples/devices/dice-isca/mini_dice/static-build/rtl"]}]
set VORTEX_RTL   [file normalize "${ZCU_ROOT}/vortex/hw/rtl"]

# zcu102 chip-side RTL (cache_hierarchy, packet_parser, id_dispatcher,
# burst_*, response_collector, rr_arbiter, axil_*_*, mini_dice_top
# helpers).  Drop aurora-bridge / bsg_link / chip_top / TB files.
set ZCU_FILES [glob -nocomplain -directory ${ZCU_ROOT}/rtl *.sv]
set ZCU_DROP_PATTERNS [list \
    "*axi_aurora_bridge*" "*axi_to_aurora*" "*aurora_to_axi*" \
    "*axi_lite_to_aurora*" "*axi_depacketizer*" "*axi_packetizer*" \
    "*aurora_r_receiver*" "*axi_aurora_responder*" \
    "*chip_top*" "*tb_*" \
]
foreach pat ${ZCU_DROP_PATTERNS} {
    set ZCU_FILES [lsearch -all -inline -not -glob ${ZCU_FILES} ${pat}]
}
add_files -norecurse ${ZCU_FILES}

# basejump_stl (.v files mixing SV — re-tag as SystemVerilog below).
set BSG_FILES [concat \
    [glob -nocomplain -directory ${BSG_ROOT}/bsg_misc     *.sv *.v] \
    [glob -nocomplain -directory ${BSG_ROOT}/bsg_async    *.sv *.v] \
    [glob -nocomplain -directory ${BSG_ROOT}/bsg_dataflow *.sv *.v] \
    [glob -nocomplain -directory ${BSG_ROOT}/bsg_mem      *.sv *.v] \
    [glob -nocomplain -directory ${BSG_ROOT}/bsg_link     *.sv *.v] \
]
add_files -norecurse ${BSG_FILES}

# Vortex hw/rtl (cache + core libs needed by cache_hierarchy + Vortex
# adapter).
set VORTEX_HDRS  [glob -nocomplain -directory ${VORTEX_RTL} *.vh]
set VORTEX_FILES [concat ${VORTEX_HDRS} \
    [glob -nocomplain -directory ${VORTEX_RTL}       *.sv] \
    [glob -nocomplain -directory ${VORTEX_RTL}/cache *.sv] \
    [glob -nocomplain -directory ${VORTEX_RTL}/mem   *.sv] \
    [glob -nocomplain -directory ${VORTEX_RTL}/libs  *.sv] \
]
add_files -norecurse ${VORTEX_FILES}
foreach h ${VORTEX_HDRS} {
    set fh [get_files -quiet [file tail $h]]
    if {$fh ne ""} {
        set_property file_type "Verilog Header" $fh
        set_property is_global_include 1 $fh
    }
}

# Mini_Dice_Backend RTL (mini_dice_top + cgra_core + cta_dispatcher +
# IO + axi_crossbar + interfaces).  Same exclusion list as combined_sim.
if {[file isdirectory ${DICE_ROOT}]} {
    set DICE_FILES [split [exec find ${DICE_ROOT} -type f \
                                \( -name "*.sv" -o -name "*.svh" \)] "\n"]
    set DICE_FILES [lsearch -all -inline -not -glob ${DICE_FILES} "*/axi_crossbar/axi/axi/*"]
    set DICE_FILES [lsearch -all -inline -not -glob ${DICE_FILES} "*/axi_test.sv"]
    set DICE_FILES [lsearch -all -inline -not -glob ${DICE_FILES} "*/tb_*.sv"]
    set DICE_FILES [lsearch -all -inline -not -glob ${DICE_FILES} "*/chip_top.sv"]
    set DICE_FILES [lsearch -all -inline -not -glob ${DICE_FILES} "*/interfaces/VX_mem_bus_if.sv"]
    add_files -norecurse ${DICE_FILES}
}

# Dora-generated CGRA fabric (dice_top + companions).
if {[file isdirectory ${DICE_CGRA}]} {
    set CGRA_FILES [split [exec find ${DICE_CGRA} -type f \
                                \( -name "*.sv" -o -name "*.v" \)] "\n"]
    add_files -norecurse ${CGRA_FILES}
}

# mini_dice_alveo design top + shim + dynamic region.  Reuses
# pncel_static.sv for the host-side XDMA + system_config block.
add_files -norecurse [list \
    ${src_dir}/pncel_static.sv \
    ${src_dir}/mini_dice_alveo.sv \
    ${src_dir}/mini_dice_alveo_dynamic.sv \
    ${src_dir}/mini_dice_alveo_dynamic_region.sv \
]

# Include directories — Vortex + BSG + Mini_Dice_Backend + alveo src.
set_property include_dirs [list \
    ${src_dir} \
    ${BSG_ROOT}/bsg_misc \
    ${BSG_ROOT}/bsg_link \
    ${BSG_ROOT}/bsg_async \
    ${BSG_ROOT}/bsg_dataflow \
    ${BSG_ROOT}/bsg_mem \
    ${VORTEX_RTL} \
    ${VORTEX_RTL}/cache \
    ${VORTEX_RTL}/mem \
    ${VORTEX_RTL}/libs \
    ${DICE_ROOT}/includes \
    ${DICE_ROOT}/interfaces \
    ${DICE_ROOT}/axi_crossbar/axi/include \
    ${DICE_ROOT}/axi_crossbar/common_cells/common_cells/include \
] [current_fileset]
set_property top ${top_module} [current_fileset]
# Hardware build defines.  Match mini_dice_zcu102's synth flow + Vortex's
# requirement for SYNTHESIS to gate sim-only constructs.  No SIMULATION
# or SIM_*_STUB flags — this is a real synth target.
set_property verilog_define { \
    __au50__ \
    SYNTHESIS \
    UUID_WIDTH_OVERRIDE=12 \
    L1_MEM_PORTS=1 \
    L2_ENABLE \
    L2_MEM_PORTS=1 \
    L3_ENABLE \
    L3_MEM_PORTS=1 \
} [current_fileset]

# Re-tag .sv files that Vivado auto-detected as Verilog, and any .v
# files in basejump that use SV-only constructs.
foreach f [get_files -quiet -filter {FILE_TYPE == "Verilog" && NAME =~ "*.sv"}] {
    set_property file_type "SystemVerilog" $f
}
foreach f ${BSG_FILES} {
    set fh [get_files -quiet [file tail $f]]
    if {$fh ne ""} { set_property file_type "SystemVerilog" $fh }
}

# =========================================================================
# Constraints (reuse pncel's — same board, same pin map; aurora-specific
# pins that no longer have a driver will trigger Vivado warnings but
# don't block elaboration).
# =========================================================================
if {[file exists ${constr_dir}/pins.xdc]} {
    add_files -fileset constrs_1 -norecurse [list \
        ${constr_dir}/pins.xdc \
        ${constr_dir}/timing.xdc \
        ${constr_dir}/general.xdc \
    ]
    set_property file_type        {TCL}                          [get_files ${constr_dir}/pins.xdc]
    set_property USED_IN          {synthesis implementation}     [get_files ${constr_dir}/pins.xdc]
    set_property PROCESSING_ORDER EARLY                          [get_files ${constr_dir}/pins.xdc]
}

# =========================================================================
# Create IP cores
# =========================================================================
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

# system_config sub-IPs (HBICAP, CMS, SYSMON, etc.) — reused as-is
source ${src_dir}/system_config/vivado_ip/system_config_axi_crossbar.tcl
source ${src_dir}/system_config/vivado_ip/system_management_wiz.tcl
source ${src_dir}/system_config/vivado_ip/clk_wiz_50Mhz.tcl
source ${src_dir}/system_config/vivado_ip/cms_subsystem_0.tcl
source ${src_dir}/system_config/vivado_ip/axi_hbicap_0.tcl

# Static-side fabric IPs
source ${src_dir}/utility/vivado_ip/axil_host_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_dma_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_dwidth_converter_0.tcl
source ${src_dir}/utility/vivado_ip/axi_lite_clock_converter.tcl

# Bump axi_dma_switch from 1→2 to 1→3 (M02 = direct AXI4 path to BRAM).
set_property -dict [list \
  CONFIG.NUM_MI                  {3}                      \
  CONFIG.M02_AXI_ADDR_WIDTH      {64}                     \
  CONFIG.M02_AXI_DATA_WIDTH      {256}                    \
  CONFIG.M02_AXI_PROTOCOL        {AXI4}                   \
  CONFIG.M02_SEG00_BASE_ADDR     {0x0000000400000000}     \
  CONFIG.M02_SEG00_HIGH_ADDR     {0x000000040FFFFFFF}     \
] [get_ips axi_dma_switch]

# BRAM-side IPs (new for mini_dice_alveo)
source ${src_dir}/hbm/vivado_ip/axi_dwidth_l3_to_bram.tcl
source ${src_dir}/hbm/vivado_ip/axi_crossbar_alveo.tcl
source ${src_dir}/hbm/vivado_ip/axi_bram_ctrl_alveo.tcl

# Chip-side AXI-Lite switch IP (instantiated inside axi_lite_switch.sv).
# 1S→2M crossbar that splits the host AXI-Lite stream into:
#   M00 → axi_lite_fifo   (64 KB at 0x0008_0000) ← CSR-write FIFO.  The
#         lower 16 b of the host AXI-Lite address become the OP_WRITE
#         packet's `addr` field, which the chip's axi_link_rx routes to
#         cgra_io_csr (REG_STARTPC=0xFF02, REG_CTRL=0xFF00, etc.).
#         BASE is within axil_host_switch.M02 (0x0008_0000-0x0009_FFFF)
#         so host writes to 0x0008_FFxx pass through cleanly.
#   M01 → axi_lite_regmap (4 KB at 0x0009_0000) ← shifted from
#         0x0008_0000 to make room for the FIFO's 16-bit aperture.
# Must agree with mini_dice_alveo_dynamic_region.sv FIFO/regmap base
# addrs (lines ~1629-1632) and pncel_alveo/host/mini_dice.py
# FIFO_BASE / REGMAP_BASE.
create_ip -name axi_crossbar -vendor xilinx.com -library ip -module_name axi_lite_switch_xbar
set_property -dict [list \
  CONFIG.PROTOCOL             {AXI4LITE} \
  CONFIG.NUM_SI               {1} \
  CONFIG.NUM_MI               {2} \
  CONFIG.ADDR_WIDTH           {32} \
  CONFIG.DATA_WIDTH           {32} \
  CONFIG.CONNECTIVITY_MODE    {SASD} \
  CONFIG.M00_A00_BASE_ADDR    {0x0000000000080000} \
  CONFIG.M00_A00_ADDR_WIDTH   {16} \
  CONFIG.M01_A00_BASE_ADDR    {0x0000000000090000} \
  CONFIG.M01_A00_ADDR_WIDTH   {12} \
] [get_ips axi_lite_switch_xbar]

# PCIe XDMA
source ${src_dir}/pcie/vivado_ip/xdma_0.tcl

# =========================================================================
# Compile order
# =========================================================================
update_compile_order -fileset sources_1

# =========================================================================
# Sim products + final report
# =========================================================================
generate_target simulation [get_ips]

puts "============================================================"
puts "mini_dice_alveo_build.tcl: project created at"
puts "  ${project_dir}/${project_name}.xpr"
puts "Top: ${top_module}"
puts "============================================================"
