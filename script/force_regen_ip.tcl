# Forcibly delete and re-source the axi_hbm_switch and axi_dma_switch
# IPs.  Use when update_ip.tcl's drift detector misses a structural
# change (e.g. protocol/width change on a slave port that doesn't
# show up in list_property the way the audit expects).
#
# Usage:
#   vivado -mode batch -source script/force_regen_ip.tcl

set project_name    alveo_u50_host
set root_dir        [file normalize [file dirname [info script]]/..]
set build_storage   /data/pdh4/${project_name}_build
set xpr             ${build_storage}/${project_name}/${project_name}.xpr
set src_dir         ${root_dir}/src
set board_repo      ${root_dir}/board_files

if {[file exists ${board_repo}]} {
    set_param board.repoPaths [list ${board_repo}]
}

if {![file exists ${xpr}]} {
    puts "ERROR: project file ${xpr} does not exist"
    exit 1
}

open_project ${xpr}

# Helper: same body as set_ip_properties_safe in build.tcl.  The IP TCL
# scripts rely on this proc being defined in the global namespace.
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

# Pairs of (module_name, tcl_path) — the IPs whose configs changed.
set targets [list \
    [list axi_hbm_switch            ${src_dir}/utility/vivado_ip/axi_hbm_switch.tcl] \
    [list axi_dma_switch            ${src_dir}/utility/vivado_ip/axi_dma_switch.tcl] \
    [list axi_dwidth_converter_0    ${src_dir}/utility/vivado_ip/axi_dwidth_converter_0.tcl] \
    [list axi_protocol_converter_0  ${src_dir}/utility/vivado_ip/axi_protocol_converter_0.tcl] \
]

foreach pair $targets {
    set mod    [lindex $pair 0]
    set script [lindex $pair 1]

    puts "================================================================"
    puts "force_regen: ${mod}"
    puts "================================================================"

    # Cancel any in-flight synth run for this IP.
    set runs [get_runs -quiet ${mod}_synth_1]
    if {[llength $runs] > 0} {
        puts "  resetting run ${mod}_synth_1"
        catch {reset_runs ${mod}_synth_1}
    }

    # Detach the .xci from the project (this does NOT delete the xci
    # file on disk; we want it gone too so create_ip starts fresh).
    set xci_files [get_files -quiet ${mod}.xci]
    if {[llength $xci_files] > 0} {
        puts "  detaching ${xci_files}"
        export_ip_user_files -of_objects $xci_files -no_script -reset -force -quiet
        remove_files $xci_files
    }

    # Wipe the on-disk IP directory (.srcs and .gen) so create_ip rebuilds
    # everything from scratch.
    set src_ip_dir [file join ${build_storage} ${project_name} ${project_name}.srcs sources_1 ip ${mod}]
    if {[file exists $src_ip_dir]} {
        puts "  removing $src_ip_dir"
        file delete -force $src_ip_dir
    }
    set gen_ip_dir [file join ${build_storage} ${project_name} ${project_name}.gen sources_1 ip ${mod}]
    if {[file exists $gen_ip_dir]} {
        puts "  removing $gen_ip_dir"
        file delete -force $gen_ip_dir
    }

    # Re-source the TCL — recreates the IP with the updated properties.
    puts "  re-sourcing $script"
    source $script
}

# Regenerate output products so synth_1 picks up the new stub.
puts "================================================================"
puts "Regenerating output products"
puts "================================================================"
generate_target all [get_ips axi_hbm_switch axi_dma_switch axi_dwidth_converter_0 axi_protocol_converter_0]

# Invalidate synth_1 so make synth rebuilds.
if {[llength [get_runs -quiet synth_1]] > 0} {
    set synth_progress [get_property PROGRESS [get_runs synth_1]]
    if {$synth_progress ne "0%"} {
        reset_runs synth_1
        puts "synth_1 reset; run \`make synth\` to rebuild."
    }
}

puts "================================================================"
puts "force_regen: done."
puts "================================================================"

close_project
