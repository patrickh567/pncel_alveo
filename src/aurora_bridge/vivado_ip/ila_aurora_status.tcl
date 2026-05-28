# *************************************************************************
# ila_aurora_status — Integrated Logic Analyzer on every status / error
# / clocking signal coming out of the Aurora 64b/66b IP, clocked off
# the 100 MHz init_clk domain.
#
# The ILA samples 15 separate probes (mix of 1-bit link-state signals
# and the 4-bit lane_up / gt_powergood vectors) plus the QPLL lock /
# refclk-lost telemetry.  All probes are sync'd into init_clk via a
# 2-FF chain in pncel_dynamic_region.sv before reaching the ILA — the
# user-clk / refclk domain Aurora outputs would otherwise be CDC-
# unsafe on the ILA capture clock.
#
# Capture depth = 4096 samples × 10 ns = 40 us per capture, more than
# enough to see channel_up bring-up sequencing (which completes within
# ~100 us of release-from-reset in hardware).
# *************************************************************************

create_ip -name ila \
          -vendor xilinx.com \
          -library ip \
          -module_name ila_aurora_status

set_ip_properties_safe ila_aurora_status [list \
  CONFIG.C_NUM_OF_PROBES        {15}    \
  CONFIG.C_DATA_DEPTH           {4096}  \
  CONFIG.C_TRIGOUT_EN           {false} \
  CONFIG.C_ADV_TRIGGER          {true}  \
  CONFIG.C_INPUT_PIPE_STAGES    {0}     \
  CONFIG.C_EN_STRG_QUAL         {1}     \
  CONFIG.ALL_PROBE_SAME_MU      {true}  \
  CONFIG.ALL_PROBE_SAME_MU_CNT  {2}     \
  CONFIG.C_PROBE0_WIDTH         {1}     \
  CONFIG.C_PROBE1_WIDTH         {4}     \
  CONFIG.C_PROBE2_WIDTH         {1}     \
  CONFIG.C_PROBE3_WIDTH         {1}     \
  CONFIG.C_PROBE4_WIDTH         {1}     \
  CONFIG.C_PROBE5_WIDTH         {1}     \
  CONFIG.C_PROBE6_WIDTH         {1}     \
  CONFIG.C_PROBE7_WIDTH         {1}     \
  CONFIG.C_PROBE8_WIDTH         {4}     \
  CONFIG.C_PROBE9_WIDTH         {1}     \
  CONFIG.C_PROBE10_WIDTH        {1}     \
  CONFIG.C_PROBE11_WIDTH        {1}     \
  CONFIG.C_PROBE12_WIDTH        {1}     \
  CONFIG.C_PROBE13_WIDTH        {1}     \
  CONFIG.C_PROBE14_WIDTH        {1}     \
  CONFIG.Component_Name         {ila_aurora_status} \
]
