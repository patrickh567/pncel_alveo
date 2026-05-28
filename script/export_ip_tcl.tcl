# *************************************************************************
#
# Export IP creation Tcl for all IPs in the alveo_u50_host project.
#
# Unlike `write_ip_tcl`, which only emits properties that differ from the
# IP catalog defaults, this script writes EVERY CONFIG.* property of each
# IP. The generated scripts are therefore self-contained and immune to
# changes in catalog defaults across Vivado versions.
#
# Usage:
#   vivado -mode batch -source script/export_ip_tcl.tcl
#   vivado -mode tcl   -source script/export_ip_tcl.tcl
#
# Or, if the project is already open in an interactive Vivado session:
#   source script/export_ip_tcl.tcl
#
# Output:
#   build/ip_tcl/<ip_name>.tcl   (one file per IP)
#
# *************************************************************************

set project_name alveo_u50_host
set root_dir     [file normalize [file dirname [info script]]/..]
set project_xpr  ${root_dir}/build/${project_name}/${project_name}.xpr
set out_dir      ${root_dir}/build/ip_tcl

# =========================================================================
# Open the project if it isn't already open
# =========================================================================
if {[current_project -quiet] eq ""} {
    if {![file exists ${project_xpr}]} {
        error "Project not found: ${project_xpr}\nRun 'make project' first."
    }
    open_project ${project_xpr}
} else {
    puts "Using already-open project: [current_project]"
}

# =========================================================================
# Write a fully-specified create_ip + set_property script for one IP.
#
# Walks every CONFIG.* property on the IP (skipping the .VALUE_SRC
# sentinel companions) and emits a set_property call for each, so the
# resulting script reproduces the IP exactly regardless of what the
# catalog defaults happen to be.
# =========================================================================
proc write_ip_full_tcl {ip out_file} {
    set ip_name [get_property NAME $ip]
    set ipdef   [get_property IPDEF $ip]
    lassign [split $ipdef ":"] ip_vendor ip_library ip_def_name ip_version

    set fp [open $out_file w]
    puts $fp "# *************************************************************************"
    puts $fp "# Auto-generated IP creation script for ${ip_name}"
    puts $fp "# Source IP : ${ipdef}"
    puts $fp "# Generated : [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    puts $fp "# *************************************************************************"
    puts $fp ""
    puts $fp "create_ip -name ${ip_def_name} \\"
    puts $fp "          -vendor ${ip_vendor} \\"
    puts $fp "          -library ${ip_library} \\"
    puts $fp "          -version ${ip_version} \\"
    puts $fp "          -module_name ${ip_name}"
    puts $fp ""

    # Collect every CONFIG.* property except the .VALUE_SRC sentinels
    # (those are read-only flags Vivado uses to track value provenance).
    set props [list]
    foreach p [list_property [get_ips ${ip_name}]] {
        if {![string match "CONFIG.*" $p]} { continue }
        if { [string match "*.VALUE_SRC" $p]} { continue }
        lappend props $p
    }
    set props [lsort $props]

    if {[llength $props] > 0} {
        # Use set_ip_properties_safe (defined in build.tcl) instead of a
        # raw set_property -dict so that any phantom CONFIG.* properties
        # the catalog rejects are skipped with a warning rather than
        # aborting the whole build.
        puts $fp "set_ip_properties_safe ${ip_name} \[list \\"
        foreach p $props {
            set v [get_property $p [get_ips ${ip_name}]]
            # Brace-quote the value so spaces/braces survive verbatim.
            puts $fp [format "  %-60s {%s} \\" $p $v]
        }
        puts $fp "\]"
    }
    puts $fp ""
    close $fp
}

# =========================================================================
# Drive the export
# =========================================================================
file mkdir ${out_dir}

set ips [get_ips]
if {[llength ${ips}] == 0} {
    puts "WARNING: no IPs found in project [current_project]"
    return
}

puts "Exporting [llength ${ips}] IP(s) to ${out_dir}"
foreach ip ${ips} {
    set ip_name [get_property NAME ${ip}]
    set out_file ${out_dir}/${ip_name}.tcl
    puts "  ${ip_name} -> ${out_file}"
    write_ip_full_tcl ${ip} ${out_file}
}

puts "============================================================"
puts " Exported [llength ${ips}] IP(s) to:"
puts "   ${out_dir}"
puts "============================================================"
