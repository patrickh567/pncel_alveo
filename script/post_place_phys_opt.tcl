# *************************************************************************
# phys_opt_design loop hook — escalates directive aggressiveness across
# iterations while setup WNS stays negative.  Reused for both
# STEPS.PLACE_DESIGN.TCL.POST and STEPS.ROUTE_DESIGN.TCL.POST;
# phys_opt_design auto-detects the design state and runs the appropriate
# optimisations.
#
# Iteration tiers (indices cumulative up to MAX_ITER):
#   1..TIER1_END    : phys_opt_design                              (cheap)
#   TIER1_END+1..TIER2_END : phys_opt_design -directive AggressiveExplore
#   TIER2_END+1..MAX_ITER  : AggressiveExplore + SLR-crossing pass
#                            (U50 has two SLRs; SLR-crossing paths are a
#                             common residual-negative-slack source)
#
# Wire up in build.tcl:
#   set_property STEPS.PLACE_DESIGN.TCL.POST <script>  [get_runs impl_*]
#   set_property STEPS.ROUTE_DESIGN.TCL.POST <script>  [get_runs impl_*]
#
# Replaces the built-in single-pass post-place phys_opt driven by
# STEPS.PHYS_OPT_DESIGN.IS_ENABLED — leaving that flag on just causes
# one redundant pass after this hook finishes.
# *************************************************************************

# Tunables
set MAX_ITER  20
set TIER1_END 3   ;# iterations 1..3 use the default directive
set TIER2_END 6   ;# iterations 4..6 use AggressiveExplore
                  ;# iterations 7..MAX use AggressiveExplore + -slr_crossing_opt

proc __phys_opt_wns {} {
    # Worst-case setup slack in the design, or +inf if no setup-constrained
    # paths exist (purely combinational / unconstrained) — loop exits.
    set paths [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
    if {[llength $paths] == 0} { return 1e9 }
    set slack [get_property SLACK [lindex $paths 0]]
    if {$slack eq "" || $slack eq "inf"} { return 1e9 }
    return $slack
}

proc __phys_opt_iter {i tier1_end tier2_end} {
    if {$i <= $tier1_end} {
        puts "phys_opt_loop: iter $i — phys_opt_design (default)"
        phys_opt_design
    } elseif {$i <= $tier2_end} {
        puts "phys_opt_loop: iter $i — phys_opt_design -directive AggressiveExplore"
        phys_opt_design -directive AggressiveExplore
    } else {
        puts "phys_opt_loop: iter $i — AggressiveExplore + -slr_crossing_opt"
        phys_opt_design -directive AggressiveExplore
        phys_opt_design -slr_crossing_opt
    }
}

set wns [__phys_opt_wns]

puts "============================================================"
puts " phys_opt_loop: initial WNS = $wns ns (max $MAX_ITER iters)"
puts "============================================================"

for {set i 1} {$i <= $MAX_ITER} {incr i} {
    if {$wns >= 0} {
        puts "phys_opt_loop: timing met after [expr {$i - 1}] iteration(s)"
        break
    }
    __phys_opt_iter $i $TIER1_END $TIER2_END
    set wns [__phys_opt_wns]
    puts "phys_opt_loop: iter $i done, WNS = $wns ns"
}

if {$wns < 0} {
    puts "WARNING: phys_opt_loop: WNS still negative ($wns ns) after $MAX_ITER iteration(s)"
} else {
    puts "phys_opt_loop: final WNS = $wns ns"
}
