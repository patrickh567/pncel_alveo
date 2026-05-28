# *************************************************************************
# Aurora-bridge AXI4 clock converter.  CDC for XDMA's 256-bit AXI4 path
# (axi_aclk, 250 MHz) into the bridge / Aurora user-clock domain
# (aurora_user_clk, ~156.25 MHz for 10.3125 Gb/s × 4 lanes).
# *************************************************************************

create_ip -name axi_clock_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_clock_converter_data

set_ip_properties_safe axi_clock_converter_data [list \
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
