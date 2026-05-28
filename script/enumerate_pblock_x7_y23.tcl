# *************************************************************************
# Enumerate per-resource-type ranges for CLOCKREGION_X7Y2:X7Y3 to extend
# the dynamic-region pblock into SLR0's right-most column without
# claiming any of the static-only hard blocks that live there.
#
# Why this script exists
# ----------------------
# Adding the column as an umbrella (`-add CLOCKREGION_X7Y2:X7Y3`) pulls
# every site type — including GTYE4_COMMON / GTYE4_CHANNEL / BUFG_GT
# sites locked to XDMA's PCIe transceiver hierarchy — into the pblock.
# With EXCLUDE_PLACEMENT=TRUE that trips HDPR-6 at place_design.  The
# right pattern (matching the X0:X6 band already in pblock_dynamic.xdc)
# is per-resource-type adds for only the site types an RM can use.
#
# This script enumerates sites in CLOCKREGION_X7Y2:X7Y3, buckets them
# by SITE_TYPE, drops every static-only / GT-only type, and prints
# ready-to-paste `resize_pblock -add` lines.
#
# Usage
# -----
#   make project                                           ;# if not built
#   make synth                                             ;# routed DCP
#   vivado -mode tcl
#     open_checkpoint /data/pdh4/alveo_u50_host_build/alveo_u50_host/alveo_u50_host.runs/synth_1/alveo_host_top.dcp
#     source script/enumerate_pblock_x7_y23.tcl
#     close_project
#
# Then copy the printed `resize_pblock` lines into the marked block in
# constr/au50/pblock_dynamic.xdc.
# *************************************************************************

set target_regions { X7Y2 X7Y3 }

# Site types deliberately omitted from the pblock — these are static-
# only on this design or otherwise unsafe to claim with EXCLUDE_PLACEMENT.
set skip_types {
    IOB
    HPIOBDIFFINBUF
    HPIOBDIFFOUTBUF
    BIAS
    HPIO_VREF_SITE
    BITSLICE_TX
    BITSLICE_RX_TX
    BITSLICE_CONTROL
    PLL_SELECT_SITE
    PSS_ALTO
    SYSMONE4
    PCIE4CE4
    PCIE40E4
    CMACE4
    ILKNE4
    GTYE4_CHANNEL
    GTYE4_COMMON
    BUFG_GT
    BUFG_GT_SYNC
    HSADC
    HSDAC
    RFADC
    RFDAC
    CONFIG_SITE
    CFGIO_SITE
    DIFFRXP
    DIFFRXN
    DIFFTXP
    DIFFTXN
    HBM_REF_CLK_X0Y0
    HBM_REF_CLK
    AMS
}

# Helpers
proc __min {a b} { return [expr {$a < $b ? $a : $b}] }
proc __max {a b} { return [expr {$a > $b ? $a : $b}] }

array set site_min_x {}
array set site_min_y {}
array set site_max_x {}
array set site_max_y {}

foreach cr $target_regions {
    set region [get_clock_regions $cr -quiet]
    if {[llength $region] == 0} {
        puts "WARNING: clock region $cr not found"
        continue
    }
    foreach site [get_sites -of_objects $region -quiet] {
        set st [get_property SITE_TYPE $site]
        if {[lsearch -exact $skip_types $st] >= 0} { continue }

        # Bucket by site-NAME prefix (physical site family), not by
        # SITE_TYPE — SLICE sites are SITE_TYPE SLICEL/SLICEM but the
        # pblock-range syntax uses the SLICE_X*Y* physical name; ditto
        # for RAMB18/RAMB36 vs RAMB181/RAMBFIFO* alternates.
        set sn [get_property NAME $site]
        if {![regexp {^(.+)_X(\d+)Y(\d+)$} $sn -> prefix sx sy]} { continue }

        if {![info exists site_min_x($prefix)]} {
            set site_min_x($prefix) $sx
            set site_min_y($prefix) $sy
            set site_max_x($prefix) $sx
            set site_max_y($prefix) $sy
        } else {
            set site_min_x($prefix) [__min $site_min_x($prefix) $sx]
            set site_min_y($prefix) [__min $site_min_y($prefix) $sy]
            set site_max_x($prefix) [__max $site_max_x($prefix) $sx]
            set site_max_y($prefix) [__max $site_max_y($prefix) $sy]
        }
    }
}

puts ""
puts "================================================================"
puts " resize_pblock lines for CLOCKREGION_X7Y2:X7Y3 (paste into"
puts " constr/au50/pblock_dynamic.xdc, between the BEGIN/END markers)"
puts "================================================================"
foreach prefix [lsort [array names site_min_x]] {
    set lo [format "%s_X%dY%d" $prefix $site_min_x($prefix) $site_min_y($prefix)]
    set hi [format "%s_X%dY%d" $prefix $site_max_x($prefix) $site_max_y($prefix)]
    puts [format "resize_pblock \[get_pblocks pblock_u_region\] -add {%s:%s}" $lo $hi]
}
puts "================================================================"

# Also list everything we deliberately skipped so the user can verify
# nothing useful was dropped.
puts ""
puts "Site types found in CLOCKREGION_X7Y2:X7Y3 but skipped (static-only):"
array set skipped_seen {}
foreach cr $target_regions {
    set region [get_clock_regions $cr -quiet]
    if {[llength $region] == 0} continue
    foreach site [get_sites -of_objects $region -quiet] {
        set st [get_property SITE_TYPE $site]
        if {[lsearch -exact $skip_types $st] >= 0} {
            set skipped_seen($st) 1
        }
    }
}
foreach st [lsort [array names skipped_seen]] {
    puts "  $st"
}
puts ""
