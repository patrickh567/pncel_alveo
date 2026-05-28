# One-shot: open the impl_2 routed DCP, enumerate every failing path on
# the clk_out2_clk_wiz_50Mhz -> aclk crossing, group by start-point cell.
set dcp /data/pdh4/alveo_u50_host_build/alveo_u50_host/alveo_u50_host.runs/impl_2/alveo_host_top_routed.dcp
open_checkpoint $dcp

# Pull all setup-violating paths on the failing crossing.  Slack threshold
# above 0 picks up every negative-slack endpoint (nominally 96).
set paths [get_timing_paths \
    -from [get_clocks clk_out2_clk_wiz_50Mhz] \
    -to   [get_clocks aclk] \
    -setup \
    -max_paths 500 \
    -slack_lesser_than 0]

puts "================================================================"
puts "Failing paths: [llength $paths]"
puts "================================================================"

# Bucket endpoints by source cell.
array set src_count {}
array set dst_count {}
array set pair_count {}

foreach p $paths {
    set src [get_property STARTPOINT_PIN $p]
    set dst [get_property ENDPOINT_PIN   $p]
    set src_cell [get_property NAME [get_cells -of_objects [get_pins $src]]]
    set dst_cell [get_property NAME [get_cells -of_objects [get_pins $dst]]]
    incr src_count($src_cell)
    incr dst_count($dst_cell)
    set pair "$src_cell  ==>  $dst_cell"
    incr pair_count($pair)
}

puts ""
puts "---- Source (launch) cells, sorted by count ----"
foreach k [lsort [array names src_count]] {
    puts [format "  %4d  %s" $src_count($k) $k]
}

puts ""
puts "---- Destination (capture) cells, sorted by count ----"
foreach k [lsort [array names dst_count]] {
    puts [format "  %4d  %s" $dst_count($k) $k]
}

puts ""
puts "---- (source, dest) pairs ----"
foreach k [lsort [array names pair_count]] {
    puts [format "  %4d  %s" $pair_count($k) $k]
}

close_project
