# *************************************************************************
#
# Alveo U50 Host - Vivado Project Build Script
#
# Usage:
#   vivado -mode batch -source script/build.tcl
#   vivado -mode tcl   -source script/build.tcl
#   vivado -mode gui   -source script/build.tcl
#
# Run from the project root directory.
#
# *************************************************************************

# =========================================================================
# Configuration
#
# The Vivado project + build artifacts live on /data/pdh4 (large
# filesystem, no per-user quota) instead of the project root, because
# the home directory has a tight 5 GB quota and a full DFX build plus
# IP gen + impl DCPs blow past that.  The project root keeps a `build/`
# symlink pointing at the real location so `make project` / `make synth`
# and any tooling that expects `<repo>/build/` just works.
# =========================================================================
# Design switch — select between the two top-level designs.
#   DESIGN=host   (default) — XDMA + HBM + default/mmu RMs.
#   DESIGN=aurora           — XDMA + HBM + aurora user-side stream
#                             crossing the partition; aurora_region is the
#                             only RM.  Aurora 64b/66b lives in static
#                             either way (just exposed in the aurora design).
# Each design uses a unique project name so the two builds coexist on
# disk under /data/pdh4/.
set design [expr {[info exists ::env(DESIGN)] ? $::env(DESIGN) : "host"}]
if {[lsearch -exact {host aurora} $design] < 0} {
    error "Unknown DESIGN '$design'; expected 'host' or 'aurora'."
}

if {$design eq "aurora"} {
    set project_name alveo_u50_aurora
    set top_module   alveo_host_top_aurora
} else {
    set project_name alveo_u50_host
    set top_module   alveo_host_top
}

set root_dir        [file normalize [file dirname [info script]]/..]
set src_dir         ${root_dir}/src
set constr_dir      ${root_dir}/constr/au50
set script_dir      ${root_dir}/script
set sim_dir         ${root_dir}/sim

set build_storage   /data/pdh4/${project_name}_build
set build_symlink   ${root_dir}/build
set project_dir     ${build_storage}/${project_name}

# Ensure the storage location exists and the repo-root symlink points at it.
# Idempotent: creates the dir if missing; refreshes the symlink if it's
# missing or points elsewhere.  Does not touch a real (non-symlink) build/
# dir if one exists — that gets a warning so the user can migrate manually.
# When building the alternate design, repoint the symlink at its storage
# location so the repo-root `build/` always reflects whichever project
# was last built.
if {![file exists ${build_storage}]} {
    file mkdir ${build_storage}
}
if {[file exists ${build_symlink}]} {
    if {[file type ${build_symlink}] eq "link"} {
        if {[file readlink ${build_symlink}] ne ${build_storage}} {
            file delete ${build_symlink}
            file link -symbolic ${build_symlink} ${build_storage}
        }
    } else {
        puts "WARNING: ${build_symlink} exists and is not a symlink; leaving it alone."
        puts "WARNING: Move its contents to ${build_storage} manually and re-run."
    }
} else {
    file link -symbolic ${build_symlink} ${build_storage}
}

# =========================================================================
# DFX switch
#
# dfx=1 (default): create a partial-reconfiguration project with a
#   partition definition at dynamic_inst/u_region and two reconfig modules
#   (stub + mmu), plus a child impl run for the mmu bitstream. The
#   dynamic-region pblock is applied in implementation.
#
# dfx=0: build a regular (flat) project.  The tied-off stub
#   `alveo_u50_dynamic_region` is synthesized in-context as a normal
#   hierarchical instance, no partition / reconfig module / pblock setup.
#
# Override by exporting DFX=0 in the environment before invoking vivado.
# =========================================================================
set dfx [expr {[info exists ::env(DFX)] ? $::env(DFX) : 1}]

# Board settings
source ${script_dir}/board_settings/au50.tcl

# =========================================================================
# Board file repository (local copy for offline builds)
# =========================================================================
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
    puts "WARNING: Board part ${board_part} not found, continuing with part only"
}
set_property target_language Verilog [current_project]

# =========================================================================
# Add RTL sources
# =========================================================================

# Interfaces (must be added first)
add_files -norecurse [list \
    ${src_dir}/utility/axi_if.sv \
    ${src_dir}/utility/axi_lite_if.sv \
    ${src_dir}/utility/apb_if.sv \
    ${src_dir}/utility/aurora_if.sv \
]

# Utility modules
add_files -norecurse [list \
    ${src_dir}/utility/axi_lite_register.sv \
    ${src_dir}/utility/axil_host_switch_wrapper.sv \
    ${src_dir}/utility/axi_dma_switch_wrapper.sv \
    ${src_dir}/utility/axi_dwidth_converter_0_wrapper.sv \
    ${src_dir}/utility/axi_protocol_converter_0_wrapper.sv \
    ${src_dir}/utility/axi_hbm_switch_wrapper.sv \
    ${src_dir}/utility/axi_register_slice_wrapper.sv \
    ${src_dir}/utility/axi_register_slice_hbm_wrapper.sv \
    ${src_dir}/utility/axi_register_slice_hbm_mux_wrapper.sv \
    ${src_dir}/utility/axi_apb_bridge_wrapper.sv \
    ${src_dir}/utility/axi_decoupler.sv \
    ${src_dir}/utility/dynamic_decoupler_a.sv \
    ${src_dir}/utility/dynamic_decoupler_b.sv \
    ${src_dir}/utility/hbm_slice_bank_a.sv \
    ${src_dir}/utility/hbm_slice_bank_b.sv \
    ${src_dir}/utility/axil_reg_map.sv \
]

# System config / CMS
add_files -norecurse [list \
    ${src_dir}/system_config/cms_subsystem_wrapper_if.sv \
    ${src_dir}/system_config/system_config_register.v \
    ${src_dir}/system_config/system_config.sv \
]

# PCIe / XDMA
add_files -norecurse [list \
    ${src_dir}/pcie/xdma_wrapper.sv \
]

# HBM
add_files -norecurse [list \
    ${src_dir}/hbm/hbm_wrapper.sv \
]

# The dynamic-region MMU sources (two TPU-style 32x32 int8 systolic
# matmul tiles instantiated in parallel — see src/dynamic/mmu/mmu_pkg.sv)
# are NOT added to sources_1. They belong to the `mmu` reconfig module,
# added below after the partition definition is created.  The default
# RM and loopback RM are self-contained — their files live in their
# respective RM filesets (see the DFX block below).

# Aurora 64b/66b static-side wrapper — only the aurora design uses it.
if {$design eq "aurora"} {
    add_files -norecurse [list \
        ${src_dir}/aurora/aurora_static.sv \
    ]
}

# Top-level modules — the host and aurora designs share the static
# core but differ in the static / dynamic / top-level wrappers, plus
# the partition top.  Source only the variant that matches $design.
if {$design eq "aurora"} {
    add_files -norecurse [list \
        ${src_dir}/alveo_u50_static_aurora.sv \
        ${src_dir}/alveo_u50_dynamic_aurora.sv \
        ${src_dir}/alveo_host_top_aurora.sv \
        ${src_dir}/dynamic/aurora/aurora_region.sv \
    ]
} else {
    add_files -norecurse [list \
        ${src_dir}/alveo_u50_static.sv \
        ${src_dir}/alveo_u50_dynamic_region.sv \
        ${src_dir}/alveo_u50_dynamic.sv \
        ${src_dir}/alveo_host_top.sv \
    ]
}

# Set include directories for macros
set_property include_dirs ${src_dir} [current_fileset]

# Set top module
set_property top ${top_module} [current_fileset]

# Verilog defines for AU50
set_property verilog_define {__au50__} [current_fileset]

# =========================================================================
# Add constraints
# =========================================================================
add_files -fileset constrs_1 -norecurse [list \
    ${constr_dir}/pins.xdc \
    ${constr_dir}/timing.xdc \
    ${constr_dir}/general.xdc \
    ${constr_dir}/debug.xdc \
]

# pins.xdc uses Tcl commands (if statements), so it must be loaded as a Tcl
# script rather than parsed as standard XDC.
set_property file_type {TCL} [get_files ${constr_dir}/pins.xdc]
set_property USED_IN {synthesis implementation} [get_files ${constr_dir}/pins.xdc]
set_property PROCESSING_ORDER EARLY [get_files ${constr_dir}/pins.xdc]

# debug.xdc runs in implementation only (the dbg_hub core is auto-inserted
# by opt_design) and LATE so the core exists before connect_debug_port.
set_property USED_IN {implementation}           [get_files ${constr_dir}/debug.xdc]
set_property PROCESSING_ORDER LATE              [get_files ${constr_dir}/debug.xdc]

# =========================================================================
# Create IP cores
# =========================================================================
# Helper used by every sourced IP script. Applies CONFIG.* properties one
# at a time and skips any that the catalog rejects (e.g. phantom properties
# the export tool emitted that don't exist on the catalog template). This
# prevents a single bad property from aborting the whole build.
proc set_ip_properties_safe {ip_name props} {
    set ip [get_ips $ip_name]
    # Fast path: apply everything in one dict so inter-property
    # dependencies resolve in a single constraint-solver pass. This is
    # ~10-50x faster than per-property set_property on large IPs, and
    # is the only path that works for IPs like xdma_0 where widths
    # (X16, 512_bit) are only valid once structural props like
    # pcie_blk_locn are simultaneously in place.
    if {![catch {set_property -dict $props $ip}]} {
        return
    }
    # Slow path: the dict apply was rejected by at least one property
    # (typically a phantom prop exported from a GUI instance that
    # doesn't exist on the catalog template). Two silent passes let
    # structural props take effect before per-port props that depend
    # on them; the final pass surfaces which properties the catalog
    # is actually rejecting.
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

# System config IPs
source ${src_dir}/system_config/vivado_ip/system_config_axi_crossbar.tcl
source ${src_dir}/system_config/vivado_ip/system_management_wiz.tcl
source ${src_dir}/system_config/vivado_ip/clk_wiz_50Mhz.tcl
source ${src_dir}/system_config/vivado_ip/cms_subsystem_0.tcl
source ${src_dir}/system_config/vivado_ip/axi_hbicap_0.tcl

# Utility IPs
source ${src_dir}/utility/vivado_ip/axi_lite_clock_converter.tcl
source ${src_dir}/utility/vivado_ip/axil_host_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_dma_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_dwidth_converter_0.tcl
source ${src_dir}/utility/vivado_ip/axi_protocol_converter_0.tcl
source ${src_dir}/utility/vivado_ip/axi_hbm_switch.tcl
source ${src_dir}/utility/vivado_ip/axi_register_slice_rp.tcl
source ${src_dir}/utility/vivado_ip/axi_register_slice_hbm.tcl
source ${src_dir}/utility/vivado_ip/axi_register_slice_hbm_mux.tcl
source ${src_dir}/utility/vivado_ip/axi_apb_bridge_0.tcl
source ${src_dir}/utility/vivado_ip/proc_sys_reset_0.tcl

# HBM IP
source ${src_dir}/hbm/vivado_ip/hbm_0.tcl
source ${src_dir}/hbm/vivado_ip/clk_wiz_hbm.tcl

# PCIe XDMA
source ${src_dir}/pcie/vivado_ip/xdma_0.tcl

# Aurora 64b/66b — instantiated in the static region of the aurora
# design only (see src/aurora/aurora_static.sv).  GT primitive lives
# in static so the dynamic-region partition doesn't have to satisfy
# GT-pad placement on every RM.
if {$design eq "aurora"} {
    source ${root_dir}/build/ip_tcl/aurora_64b66b_0.tcl
}

# =========================================================================
# Partial Reconfiguration (DFX) setup
#
# The dynamic-region partition is `dynamic_inst/u_region` in the elaborated
# hierarchy (alveo_host_top -> alveo_u50_dynamic dynamic_inst ->
# alveo_u50_dynamic_region u_region). Two reconfig modules are defined
# against a single partition definition:
#
#   * alveo_u50_dynamic_region — the tied-off stub in src/
#   * mmu                      — the TPU-style matrix multiplier
#                                (top = mmu_top, sources under src/dynamic/mmu)
#
# Two PR configurations pair the partition instance with each RM, and a
# child implementation run produces the MMU bitstream alongside the
# parent stub run.
#
# Skipped entirely when $dfx == 0: the flat flow synthesizes
# alveo_u50_dynamic_region in-context as a normal submodule.
# =========================================================================
update_compile_order -fileset sources_1

if {$dfx} {
    # Vivado 2025.1 requires PR_FLOW on the project to enable the
    # create_partition_def / create_reconfig_module / create_pr_configuration
    # commands below.  Without this the first PR call fails with
    # `[Common 17-69] Enable PR_FLOW property on project to execute PR
    # Flow TCL Commands` and the build aborts.
    set_property PR_FLOW TRUE [current_project]

    # Dynamic-region pblock (SLR1).  Post-synthesis floorplan, so scope it
    # to implementation only — applying it during OOC synth of the RMs
    # would over-constrain.
    add_files -fileset constrs_1 -norecurse ${constr_dir}/pblock_dynamic.xdc
    set_property USED_IN {implementation} [get_files ${constr_dir}/pblock_dynamic.xdc]

    if {$design eq "aurora"} {
        # Aurora design — single partition def whose top is `aurora_region`
        # (HBM ports + AXI-Lite + aurora user-side stream).
        # `aurora_region` itself doubles as the only RM today; add more
        # RMs by passing `-top <other_module>` whose port list matches.
        create_partition_def -name aurora_region -module aurora_region
        create_reconfig_module -name aurora_region \
            -partition_def [get_partition_defs aurora_region] \
            -define_from aurora_region

        create_pr_configuration -name config_1 \
            -partitions [list dynamic_inst/u_region:aurora_region]
        set_property PR_CONFIGURATION config_1 [get_runs impl_1]
    } else {
        create_partition_def -name alveo_u50_dynamic_region -module alveo_u50_dynamic_region

        # Default (stub) reconfig module — reuses alveo_u50_dynamic_region.sv;
        # Vivado moves that file from sources_1 into the new RM fileset.
        create_reconfig_module -name alveo_u50_dynamic_region \
            -partition_def [get_partition_defs alveo_u50_dynamic_region] \
            -define_from alveo_u50_dynamic_region

        # The default RM is fully self-contained in alveo_u50_dynamic_region.sv
        # (just tieoffs); -define_from moves the file into the RM fileset, so
        # no extra source files are required.

        # MMU reconfig module — top is `mmu_region`, a wrapper with flat ports
        # matching alveo_u50_dynamic_region. It instantiates mmu_top internally
        # and ties off the 20 HBM ports / DMA slave that mmu doesn't use.
        create_reconfig_module -name mmu \
            -partition_def [get_partition_defs alveo_u50_dynamic_region] \
            -top mmu_region
        add_files -norecurse -of_objects [get_reconfig_modules mmu] [list \
            ${src_dir}/utility/axi_if.sv \
            ${src_dir}/utility/axil_reg_map.sv \
            ${src_dir}/dynamic/mmu/mmu_pkg.sv \
            ${src_dir}/dynamic/mmu/mmu_systolic_pe.sv \
            ${src_dir}/dynamic/mmu/mmu_systolic_array.sv \
            ${src_dir}/dynamic/mmu/mmu_bram_2p.sv \
            ${src_dir}/dynamic/mmu/mmu_load_engine.sv \
            ${src_dir}/dynamic/mmu/mmu_store_engine.sv \
            ${src_dir}/dynamic/mmu/mmu_control.sv \
            ${src_dir}/dynamic/mmu/mmu_top.sv \
            ${src_dir}/dynamic/mmu/mmu_region.sv \
        ]

        # OOC synth constraints for the MMU (clock + reset false path). Scoped
        # to synthesis only — the parent impl run picks up the clock definition
        # from the static region's XDMA-generated XDC.
        #
        # Target the RM via -of_objects rather than -fileset <name>: in Vivado
        # 2025.1 `create_reconfig_module -name mmu -top mmu_region` creates a
        # fileset named after the -top (mmu_region), not the -name (mmu), so
        # `[get_filesets mmu]` returns empty.  `-of_objects
        # [get_reconfig_modules mmu]` side-steps the naming question entirely.
        add_files -norecurse -of_objects [get_reconfig_modules mmu] ${constr_dir}/mmu_ooc.xdc
        set_property USED_IN {synthesis out_of_context} \
            [get_files -of_objects [get_reconfig_modules mmu] ${constr_dir}/mmu_ooc.xdc]

        # PR configurations bind each RM to the partition instance.  The
        # default RM (alveo_u50_dynamic_region) is now the loopback HBM
        # traffic generator — it drives every HBM pseudo-channel and exposes
        # a start/error/busy register file over s_axil.
        create_pr_configuration -name config_1 \
            -partitions [list dynamic_inst/u_region:alveo_u50_dynamic_region]
        create_pr_configuration -name config_2 \
            -partitions [list dynamic_inst/u_region:mmu]

        # impl_1 builds the default (loopback) RM; child run builds the MMU
        # bitstream alongside.
        set_property PR_CONFIGURATION config_1 [get_runs impl_1]
        create_run child_0_impl_1 \
            -parent_run impl_1 \
            -flow {Vivado Implementation 2025} \
            -pr_config config_2
    }
}

# =========================================================================
# Phys-opt loop hooks — run phys_opt_design repeatedly while setup WNS
# is negative (max 10 iterations) after both place_design and
# route_design on every implementation run.  Applied outside the DFX
# guard so flat-mode impl_1 also gets them; in DFX mode this covers
# both impl_1 (stub) and child_0_impl_1 (MMU bitstream).
#
# Post-route phys_opt_design fixes routing-induced hold/setup violations
# that placement-time metrics couldn't see, so the same "loop until met"
# strategy is valuable there too.
# =========================================================================
set phys_opt_hook [file normalize ${script_dir}/post_place_phys_opt.tcl]
foreach r [get_runs -quiet -filter {IS_IMPLEMENTATION == 1}] {
    set_property STEPS.PLACE_DESIGN.TCL.POST $phys_opt_hook $r
    set_property STEPS.ROUTE_DESIGN.TCL.POST $phys_opt_hook $r
}

# =========================================================================
# Loopback-RM-only floorplan: static-side HBM register-slice pblocks.
#
# `pblock_slice_default_rm.xdc` constrains `u_slice_a` / `u_slice_b`
# (static-region register-slice banks at the top of `alveo_host_top`)
# to the bottom band of SLR0, half-device wide each.  The tight
# floorplan helps the loopback RM, which exercises all 31 direct HBM
# channels, but the cells live in the static region — they exist in
# every config, including the MMU bitstream, which doesn't need the
# constraint.
#
# Attaching the XDC to a reconfig module fails (Vivado roots
# `current_instance` at the RM and forces CONTAIN_ROUTING=TRUE on
# RM-attached pblocks).  Putting it in constrs_1 would apply to every
# impl run.  A per-run pre-hook on `impl_1` only — not on
# `child_0_impl_1` (config_2 = MMU bitstream) — gives us the scoping
# we want with full design-root visibility when the hook fires.
# =========================================================================
if {$dfx && $design ne "aurora"} {
    set slice_pblock_hook [file normalize ${script_dir}/apply_slice_pblock.tcl]
    set_property STEPS.OPT_DESIGN.TCL.PRE $slice_pblock_hook [get_runs impl_1]
}

# =========================================================================
# Generate IP simulation targets only
#
# This emits the behavioural / structural sim models under
# ${project_dir}/${project_name}.gen/sources_1/ip/<ip>/sim that
# `export_simulation -simulator vcs` needs, but SKIPS the synthesis
# target generation (which for BD-based IPs like cms_subsystem_0
# internally runs a block-design synthesis and dominates the build
# time).
#
# If you need the synthesis / implementation products (for running
# `make synth` or placing a full build on real hardware), use
# `make synth` at the repo root instead — that calls
# `script/synth.tcl` which opens this project and runs
# `generate_target all [get_ips]` plus the actual IP OOC runs.
# =========================================================================
generate_target simulation [get_ips]

# =========================================================================
# Simulation fileset (VCS flow lives under sim/, driven by sim/Makefile)
#
# The testbench needs two things from Vivado's sim_1 fileset:
#
#   1. `tb_hbm.sv` registered as a simulation source so that
#      `export_simulation -simulator vcs` emits compile commands for it.
#   2. `+define+SIMULATION` on every vlogan call, so that
#      `alveo_u50_static.sv` takes its testbench-mode port list (which
#      replaces PCIe / XDMA with direct sim_axil / sim_axi_dma inputs).
#
# `__au50__` is carried through for consistency with the synth path.
#
# This block runs AFTER IP generation because IP generation triggers
# Vivado to reload sim_1 from disk, which would silently discard any
# sim_1 properties set earlier in the script.
# =========================================================================
add_files -fileset sim_1 -norecurse [list \
    ${sim_dir}/tb_hbm.sv \
]
set_property top tb_hbm [get_filesets sim_1]
set_property verilog_define {SIMULATION __au50__} [get_filesets sim_1]
set_property include_dirs ${src_dir} [get_filesets sim_1]

# -------------------------------------------------------------------------
# Second simulation fileset — static-region AXI-Lite register map TB.
# Kept in its own simset so sim/Makefile can drive both TBs through
# separate export directories without juggling the "current" top.
# -------------------------------------------------------------------------
if {[llength [get_filesets -quiet sim_axil]] == 0} {
    create_fileset -simset sim_axil
}
add_files -fileset sim_axil -norecurse [list \
    ${sim_dir}/tb_axil_regs.sv \
]
set_property top tb_axil_regs [get_filesets sim_axil]
set_property verilog_define {SIMULATION __au50__} [get_filesets sim_axil]
set_property include_dirs ${src_dir} [get_filesets sim_axil]

# Flush sim fileset changes to the .xpr.  Vivado's batch-mode exit
# does not auto-save, so without close_project the sim/Makefile
# export_simulation step would see the project as if the blocks
# above had never run.
close_project

# =========================================================================
# Done
# =========================================================================
puts "============================================================"
puts " Project created: ${project_dir}/${project_name}.xpr"
puts " Part:            ${part}"
puts " Board:           ${board_part}"
puts " Design:          ${design}"
puts " Top module:      ${top_module}"
puts "============================================================"
puts ""
puts " To open in GUI:  vivado ${project_dir}/${project_name}.xpr"
puts ""
puts " IMPORTANT: open the project via the canonical /data path"
puts " above, NOT the ${build_symlink} symlink.  Vivado stores"
puts " file references relative to the .xpr's depth; opening from"
puts " the symlinked path breaks those references with duplicated"
puts " /home/pdh4/home/pdh4/... segments."
puts "============================================================"
