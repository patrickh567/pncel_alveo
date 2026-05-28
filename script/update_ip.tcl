# *************************************************************************
#
# Audit every IP in the project against the parameters declared in its
# `src/**/vivado_ip/*.tcl` script.  For each drifted IP (or missing IP,
# or IP that shares a TCL with a drifted sibling), delete the IP and
# re-source the owning TCL script so the project matches the spec again.
#
# Does NOT launch or create OOC synth runs — it only refreshes output
# products for the recreated IPs and resets `synth_1` so `make synth`
# will rebuild the top-level netlist with the refreshed IP DCPs.
#
# Usage:
#   make update-ip
#   vivado -mode batch -source script/update_ip.tcl
#
# HOW DRIFT IS DETECTED
# ---------------------
# Each IP TCL script is sourced twice:
#
#   1. RECORD MODE — `create_ip` and `set_ip_properties_safe` are stubbed
#      to capture (module name, property list) pairs without touching the
#      project.  Produces the expected-state snapshot.
#
#   2. REAL MODE (only for drifted scripts) — the real commands are
#      restored and the script is re-sourced, so the affected IPs are
#      re-created against the project with their freshly-declared props.
#
# A property counts as drifted iff (a) the IP catalog template recognises
# it (filtered via `list_property`, to skip phantom props the safe setter
# discards) and (b) its current value differs from the declared value.
#
# Any script that produces multiple IPs (a single TCL with multiple
# create_ip calls inside a `proc`, for instance)
# is treated atomically: if ANY of its IPs drifted or is missing, ALL
# of its IPs are deleted and the script is re-sourced in full so the
# produced set stays internally consistent.
#
# *************************************************************************

set root_dir        [file normalize [file dirname [info script]]/..]
set src_dir         ${root_dir}/src
set board_repo      ${root_dir}/board_files

if {[file exists ${board_repo}]} {
    set_param board.repoPaths [list ${board_repo}]
}

# Reuse the already-open project when this script is sourced into a
# live Vivado session (e.g. from the GUI or after build.tcl).  When
# launched standalone, fall back to opening the host design's default
# project from disk.  The flag controls whether we close it again at
# the end.
set already_open [expr {[llength [current_project -quiet]] > 0}]

if {$already_open} {
    set project_name  [current_project]
    set project_dir   [get_property DIRECTORY [current_project]]
    set build_storage [file dirname $project_dir]
    puts "update_ip: reusing already-open project '${project_name}'"
} else {
    set project_name  alveo_u50_host
    set build_storage /data/pdh4/${project_name}_build
    set project_dir   ${build_storage}/${project_name}
    set xpr           ${project_dir}/${project_name}.xpr

    if {![file exists ${xpr}]} {
        puts "ERROR: project file ${xpr} does not exist — run `make project` first"
        return
    }
}

# Every IP TCL script sourced by build.tcl.  Keep this list in sync with
# the `source` statements under "Create IP cores" in script/build.tcl —
# this script only audits IPs produced by these files.
set ip_tcl_scripts [list \
    ${src_dir}/system_config/vivado_ip/system_config_axi_crossbar.tcl \
    ${src_dir}/system_config/vivado_ip/system_management_wiz.tcl \
    ${src_dir}/system_config/vivado_ip/clk_wiz_50Mhz.tcl \
    ${src_dir}/system_config/vivado_ip/cms_subsystem_0.tcl \
    ${src_dir}/system_config/vivado_ip/axi_hbicap_0.tcl \
    ${src_dir}/utility/vivado_ip/axi_lite_clock_converter.tcl \
    ${src_dir}/utility/vivado_ip/axil_host_switch.tcl \
    ${src_dir}/utility/vivado_ip/axi_dma_switch.tcl \
    ${src_dir}/utility/vivado_ip/axi_dwidth_converter_0.tcl \
    ${src_dir}/utility/vivado_ip/axi_protocol_converter_0.tcl \
    ${src_dir}/utility/vivado_ip/axi_hbm_switch.tcl \
    ${src_dir}/utility/vivado_ip/axi_register_slice_rp.tcl \
    ${src_dir}/utility/vivado_ip/axi_register_slice_hbm.tcl \
    ${src_dir}/utility/vivado_ip/axi_register_slice_hbm_mux.tcl \
    ${src_dir}/utility/vivado_ip/axi_apb_bridge_0.tcl \
    ${src_dir}/utility/vivado_ip/proc_sys_reset_0.tcl \
    ${src_dir}/hbm/vivado_ip/hbm_0.tcl \
    ${src_dir}/hbm/vivado_ip/clk_wiz_hbm.tcl \
    ${src_dir}/pcie/vivado_ip/xdma_0.tcl \
]

# =========================================================================
# Record-mode overrides
#
# In record mode `create_ip` and `set_ip_properties_safe` only capture
# state; they don't touch the project.  Sourcing an IP TCL under these
# stubs yields an expected-state snapshot.
# =========================================================================
array set expected_props           {}
array set expected_module_script   {}
array set expected_script_modules  {}
set __current_script ""

proc __record_create_ip {args} {
    global expected_module_script expected_script_modules __current_script
    set idx [lsearch -exact $args "-module_name"]
    if {$idx < 0 || $idx + 1 >= [llength $args]} {
        puts "WARNING: create_ip without -module_name in ${__current_script}"
        return
    }
    set name [lindex $args [expr {$idx + 1}]]
    set expected_module_script($name) $__current_script
    lappend expected_script_modules($__current_script) $name
}

rename create_ip          __real_create_ip
rename __record_create_ip create_ip

# set_ip_properties_safe is defined in build.tcl; this interpreter
# doesn't have it yet, so define the record-mode version directly.
proc set_ip_properties_safe {ip_name props} {
    global expected_props
    set expected_props($ip_name) $props
}

foreach script $ip_tcl_scripts {
    if {![file exists $script]} {
        puts "WARNING: IP TCL not found: $script (skipping)"
        continue
    }
    set __current_script $script
    if {[catch {source $script} err]} {
        puts "ERROR sourcing $script in record mode: $err"
    }
}
set __current_script ""

# =========================================================================
# Restore real create_ip + install the real set_ip_properties_safe
# (copy of the helper in script/build.tcl — keep the two in sync).
# =========================================================================
rename create_ip       __stub_create_ip
rename __real_create_ip create_ip

rename set_ip_properties_safe __stub_set_ip_properties_safe
proc set_ip_properties_safe {ip_name props} {
    set ip [get_ips $ip_name]
    if {![catch {set_property -dict $props $ip}]} { return }
    for {set pass 1} {$pass <= 2} {incr pass} {
        foreach {prop val} $props { catch {set_property $prop $val $ip} }
    }
    foreach {prop val} $props {
        if {[catch {set_property $prop $val $ip} err]} {
            puts "WARNING: ${ip_name}: skipped ${prop} (${err})"
        }
    }
}

# =========================================================================
# Open the project (only when not already open) and compare live IPs
# to the recorded spec.
# =========================================================================
if {!$already_open} {
    open_project ${xpr}
}

# Flag any project IP not produced by one of the audited scripts.
foreach ip [get_ips] {
    set name [get_property NAME $ip]
    if {![info exists expected_module_script($name)]} {
        puts "WARNING: IP '$name' has no matching TCL script; not audited."
    }
}

set scripts_to_resource [list]
array set drift_reasons {}

foreach mod [lsort [array names expected_props]] {
    if {[llength [get_ips -quiet $mod]] == 0} {
        set drift_reasons($mod) "missing"
        set src $expected_module_script($mod)
        if {[lsearch -exact $scripts_to_resource $src] < 0} {
            lappend scripts_to_resource $src
        }
        continue
    }

    set ip          [get_ips $mod]
    set valid_props [list_property $ip]
    set drifted     [list]

    foreach {prop val} $expected_props($mod) {
        # Skip phantom properties the catalog doesn't expose — the safe
        # setter silently drops these during build, so they're not part
        # of the IP's actual spec.
        if {[lsearch -exact $valid_props $prop] < 0} { continue }
        set cur [get_property $prop $ip]
        if {$cur ne $val} {
            lappend drifted [format "    %s: %s -> %s" $prop $cur $val]
        }
    }

    if {[llength $drifted] > 0} {
        set drift_reasons($mod) $drifted
        set src $expected_module_script($mod)
        if {[lsearch -exact $scripts_to_resource $src] < 0} {
            lappend scripts_to_resource $src
        }
    }
}

if {[llength $scripts_to_resource] == 0} {
    puts "================================================================"
    puts "update_ip: all IPs match their TCL spec; nothing to do."
    puts "================================================================"
    if {!$already_open} {
        close_project
    }
    return
}

puts "================================================================"
puts "update_ip: drift detected"
puts "================================================================"
foreach mod [lsort [array names drift_reasons]] {
    set reason $drift_reasons($mod)
    if {$reason eq "missing"} {
        puts "  $mod: missing from project"
    } else {
        puts "  $mod:"
        foreach d $reason { puts $d }
    }
}
puts ""
puts "Scripts to re-source:"
foreach s $scripts_to_resource { puts "  $s" }
puts ""

# =========================================================================
# Delete every module owned by a drifted script (atomic per script),
# then re-source each script in real mode.
# =========================================================================
foreach script $scripts_to_resource {
    if {![info exists expected_script_modules($script)]} { continue }
    foreach mod $expected_script_modules($script) {
        if {[llength [get_ips -quiet $mod]] == 0} { continue }
        puts "  removing $mod"
        if {[llength [get_runs -quiet ${mod}_synth_1]] > 0} {
            delete_runs ${mod}_synth_1
        }
        set xci_files [get_files -quiet ${mod}.xci]
        if {[llength $xci_files] > 0} {
            export_ip_user_files -of_objects $xci_files -no_script -reset -force -quiet
            remove_files $xci_files
        }
        set gen_dir [file join ${build_storage} ${project_name} ${project_name}.gen sources_1 ip $mod]
        if {[file exists $gen_dir]} { file delete -force $gen_dir }
        set src_ip_dir [file join ${build_storage} ${project_name} ${project_name}.srcs sources_1 ip $mod]
        if {[file exists $src_ip_dir]} { file delete -force $src_ip_dir }
    }
}

foreach script $scripts_to_resource {
    puts "  re-sourcing $script"
    source $script
}

# =========================================================================
# Regenerate output products (no OOC runs launched) and invalidate the
# parent synth run so `make synth` will rebuild against the new DCPs.
# =========================================================================
puts "================================================================"
puts "Regenerating output products for updated IPs"
puts "================================================================"
generate_target all [get_ips]

if {[llength [get_runs -quiet synth_1]] > 0} {
    set synth_progress [get_property PROGRESS [get_runs synth_1]]
    if {$synth_progress ne "0%"} {
        reset_runs synth_1
        puts "synth_1 reset; run `make synth` to rebuild the top-level netlist."
    }
}

puts "================================================================"
puts "update_ip: done. OOC synth runs were NOT launched."
puts "Launch them via the GUI or let `make synth` drive them."
puts "================================================================"

if {!$already_open} {
    close_project
}
