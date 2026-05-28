# *************************************************************************
# AXI4 clock-domain crossing between the Aurora bridge's user clock
# (aurora_user_clk, 156.25 MHz) and the BRAM-side aclk (250 MHz).
#
# Slot:
#   axi_dwidth_bridge_to_hbm.m_*     (AXI4 256b, aurora_user_clk)
#   → axi_clock_converter_bram       (this IP, async)
#   → axi_crossbar_bram.SI[0]        (AXI4 256b, aclk)
# *************************************************************************

create_ip -name axi_clock_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_clock_converter_bram

set_ip_properties_safe axi_clock_converter_bram [list \
  CONFIG.ACLK_ASYNC      {1}      \
  CONFIG.PROTOCOL        {AXI4}   \
  CONFIG.ADDR_WIDTH      {64}     \
  CONFIG.DATA_WIDTH      {256}    \
  CONFIG.ID_WIDTH        {4}      \
  CONFIG.AWUSER_WIDTH    {0}      \
  CONFIG.ARUSER_WIDTH    {0}      \
  CONFIG.WUSER_WIDTH     {0}      \
  CONFIG.RUSER_WIDTH     {0}      \
  CONFIG.BUSER_WIDTH     {0}      \
]
