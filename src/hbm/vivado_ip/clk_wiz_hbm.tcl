# *************************************************************************
# Clock Wizard (MMCM) — HBM reference-clock generator.
#
# Generates a clean 100 MHz clock for the HBM IP's REF_CLK_0 and REF_CLK_1
# inputs.  Sourced from axi_aclk (250 MHz, XDMA user clock) to avoid:
#
#   * The `bad_BUFG_GT_muxing` critical warning (BFGTL-1) that fires when
#     a new BUFG_GT shares the PCIe refclk's ODIV2 input with XDMA's
#     internal `bufg_gt_sysclk` but has mismatched CE/CLR connections.
#
#   * The need to poke into XDMA's internal reset-sequencing nets just to
#     match CE/CLR, which is fragile across IP versions.
#
# Using an MMCM instead puts HBM REF CLK generation on its own dedicated
# clocking resource — it has properly-buffered input and output paths
# and doesn't trigger any shared-buffer rules.
#
# PRIM_SOURCE = No_buffer: the input (axi_aclk) is already driven by
# XDMA's `bufg_gt_userclk` (a BUFG_GT on the global clock network), so
# there's no reason for clk_wiz to insert its own BUFGCE in front of
# the MMCM.  Leaving the default Global_buffer adds a second-stage
# BUFGCE that inherits the BUFG_GT → BUFGCE 5-hop adjacency
# requirement: the MMCM's natural placement near HBM (SLR0 Y0) forces
# that BUFGCE to low-Y sites, which exceeds the adjacency limit from
# the BUFG_GT at X1Y74 (CR Y3) and kills route_design on CLK_USERCLK.
# No_buffer removes the whole constraint — the MMCM consumes axi_aclk
# directly off the existing global-clock rail.
#
# Caveat: HBM initialisation is now gated on `axi_aclk` (itself derived
# from PCIe REFCLK via XDMA's BUFG_GT), so HBM comes up after PCIe link
# instead of at power-on.  That's fine for this project — HBM is only
# touched by host DMA after the host sees the link, so there's no
# practical ordering issue.
#
# Source IP : xilinx.com:ip:clk_wiz:6.0
# *************************************************************************

create_ip -name clk_wiz \
          -vendor xilinx.com \
          -library ip \
          -version 6.0 \
          -module_name clk_wiz_hbm

set_ip_properties_safe clk_wiz_hbm [list \
  CONFIG.Component_Name                {clk_wiz_hbm} \
  CONFIG.PRIM_SOURCE                   {No_buffer} \
  CONFIG.PRIM_IN_FREQ                  {250.000} \
  CONFIG.CLKIN1_JITTER_PS              {40.0} \
  CONFIG.CLK_OUT1_PORT                 {clk_out1} \
  CONFIG.CLKOUT1_USED                  {true} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ    {100.000} \
  CONFIG.CLKOUT1_REQUESTED_DUTY_CYCLE  {50.000} \
  CONFIG.CLKOUT1_REQUESTED_PHASE       {0.000} \
  CONFIG.USE_RESET                     {false} \
  CONFIG.RESET_PORT                    {reset} \
  CONFIG.RESET_TYPE                    {ACTIVE_LOW} \
  CONFIG.USE_LOCKED                    {false} \
  CONFIG.USE_SAFE_CLOCK_STARTUP        {false} \
]
