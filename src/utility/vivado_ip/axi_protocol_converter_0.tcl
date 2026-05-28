# *************************************************************************
# AXI Protocol Converter — AXI3 → AXI4, 256-bit data, 4-bit ID.
#
# Sits on the RM port-31 path between the dynamic-region's AXI3/256
# output (s_axi_hbm_31, the muxed XDMA+RM landing) and
# axi_hbm_switch.s01.  The hbm switch IP forces
# both slave ports to share one protocol/width when NUM_SI > 1, so the
# RM path has to be lifted from AXI3/256 up to the AXI4/256 shape
# matching the XDMA branch (also at 256 b after the static-side
# axi_dwidth_converter_0 that narrows from XDMA's native 512 b).
#
# Source IP : xilinx.com:ip:axi_protocol_converter:2.1
# *************************************************************************

create_ip -name axi_protocol_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_protocol_converter_0

set_ip_properties_safe axi_protocol_converter_0 [list \
  CONFIG.Component_Name   {axi_protocol_converter_0} \
  CONFIG.SI_PROTOCOL      {AXI3} \
  CONFIG.MI_PROTOCOL      {AXI4} \
  CONFIG.TRANSLATION_MODE {2} \
  CONFIG.ADDR_WIDTH       {64} \
  CONFIG.DATA_WIDTH       {256} \
  CONFIG.ID_WIDTH         {4} \
  CONFIG.AWUSER_WIDTH     {0} \
  CONFIG.ARUSER_WIDTH     {0} \
  CONFIG.RUSER_WIDTH      {0} \
  CONFIG.WUSER_WIDTH      {0} \
  CONFIG.BUSER_WIDTH      {0} \
  CONFIG.READ_WRITE_MODE  {READ_WRITE} \
]
