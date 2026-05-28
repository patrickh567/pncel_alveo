# *************************************************************************
# Debug hub (auto-inserted by Vivado from IP-internal mark_debug attributes)
# is clocked on icap_clk (100 MHz, clk_wiz_50Mhz.clk_out2 → BUFG → HBICAP
# ICAPE3).  Without this the impl-time DRC fails with
# "dbg_hub/clk has 1 unconnected channels"; the BSCAN-chain logic inside
# dbg_hub's xsdbm core isn't rated to run at the 250 MHz axi_aclk, so
# anchoring there pushes ~114 endpoints inside the debug hub into
# violation.  The HBICAP IP is a black box, so the icap_clk input pin
# name survives flattening in both DFX and non-DFX builds (unlike
# hierarchical net references through the system_config SV wrapper).
#
# Lives in its own XDC so:
#   * It applies in flat AND DFX builds (pblock_dynamic.xdc is DFX-only).
#   * PROCESSING_ORDER LATE runs it after opt_design auto-inserts the
#     dbg_hub — connect_debug_port needs the core to exist first, and
#     running the command too early is what triggered Vivado to silently
#     drop it on previous impl runs.
# *************************************************************************

set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false     [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1            [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk \
    [get_nets -of_objects [get_pins -hierarchical -filter {NAME =~ */hbicap_inst/icap_clk}]]
