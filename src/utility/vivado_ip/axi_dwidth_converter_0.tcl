# *************************************************************************
# AXI Data Width Converter — 512-bit → 256-bit, AXI4 both sides.
#
# Sits on the XDMA path between axi_dma_switch.M00 (AXI4/512) and
# axi_hbm_switch.s00 (AXI4/256), narrowing the host DMA branch down to
# the HBM-native 256-bit width before it enters the 2:1 HBM switch.
# The mux branch (s01) arrives natively at AXI4/256 after
# axi_protocol_converter_0, so the switch is uniform AXI4/256 on both
# slaves and AXI3/256 on its m00 — no further width step inside the
# switch is required.
#
# Source IP : xilinx.com:ip:axi_dwidth_converter:2.1
# *************************************************************************

create_ip -name axi_dwidth_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_dwidth_converter_0

set_ip_properties_safe axi_dwidth_converter_0 [list \
  CONFIG.Component_Name   {axi_dwidth_converter_0} \
  CONFIG.SI_DATA_WIDTH    {512} \
  CONFIG.MI_DATA_WIDTH    {256} \
  CONFIG.ADDR_WIDTH       {64} \
  CONFIG.SI_ID_WIDTH      {4} \
  CONFIG.AWUSER_WIDTH     {0} \
  CONFIG.ARUSER_WIDTH     {0} \
  CONFIG.RUSER_WIDTH      {0} \
  CONFIG.WUSER_WIDTH      {0} \
  CONFIG.BUSER_WIDTH      {0} \
  CONFIG.READ_WRITE_MODE  {READ_WRITE} \
]
