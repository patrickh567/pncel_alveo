# *************************************************************************
# AXI-Lite clock converter — dedicated instance for the aurora-bridge
# control path (XDMA AXI-Lite at 250 MHz → aurora_user_clk).
#
# Functionally identical to utility/vivado_ip/axi_lite_clock_converter,
# but a SEPARATE IP module so the DFX flow can move it into the
# pncel_dynamic_region RM without conflicting with the same IP used
# inside system_config (which lives in the static region).
# *************************************************************************

create_ip -name axi_clock_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_lite_clock_converter_aurora

set_ip_properties_safe axi_lite_clock_converter_aurora [list \
  CONFIG.ACLK_ASYNC      {1}        \
  CONFIG.PROTOCOL        {AXI4LITE} \
  CONFIG.ADDR_WIDTH      {32}       \
  CONFIG.DATA_WIDTH      {32}       \
  CONFIG.ID_WIDTH        {0}        \
  CONFIG.AWUSER_WIDTH    {0}        \
  CONFIG.ARUSER_WIDTH    {0}        \
  CONFIG.WUSER_WIDTH     {0}        \
  CONFIG.RUSER_WIDTH     {0}        \
  CONFIG.BUSER_WIDTH     {0}        \
]
