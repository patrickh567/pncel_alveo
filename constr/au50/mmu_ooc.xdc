# *************************************************************************
#
# MMU reconfig module — out-of-context timing constraints.
#
# Applied only during the RM's OOC synth run; the parent implementation
# run picks up the clock definition from the XDMA-generated XDC instead,
# so this file is marked USED_IN={synthesis out_of_context} in build.tcl.
#
# aclk is driven by the XDMA user clock (250 MHz = 4.0 ns period).
#
# aresetn is used as a *synchronous* reset inside the MMU
# (`always_ff @(posedge clk) if (~aresetn) ...`), so the path from the
# port to the flop D-mux is timed normally — no set_false_path.
#
# *************************************************************************
create_clock -period 4.000 -name aclk [get_ports aclk]
