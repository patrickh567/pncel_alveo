# *************************************************************************
# AXI Register Slice — 256b AXI3 variant, 4-bit ID, used between the RM's
# `m_axi_hbm_mux` partition output and the static-side `decouple_axi_hbm_mux`
# decoupler.  Same protocol/width as `axi_register_slice_hbm` but with the
# narrower 4-bit ID that matches the mux flat port (which feeds
# `axi_hbm_switch.s01` on the static side, also 4-bit ID).
#
# Source IP : xilinx.com:ip:axi_register_slice:2.1
# *************************************************************************

create_ip -name axi_register_slice \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_register_slice_hbm_mux

set_ip_properties_safe axi_register_slice_hbm_mux [list \
  CONFIG.Component_Name   {axi_register_slice_hbm_mux} \
  CONFIG.PROTOCOL         {AXI3} \
  CONFIG.ADDR_WIDTH       {64} \
  CONFIG.DATA_WIDTH       {256} \
  CONFIG.ID_WIDTH         {4} \
  CONFIG.AWUSER_WIDTH     {0} \
  CONFIG.ARUSER_WIDTH     {0} \
  CONFIG.RUSER_WIDTH      {0} \
  CONFIG.WUSER_WIDTH      {0} \
  CONFIG.BUSER_WIDTH      {0} \
  CONFIG.HAS_BURST        {1} \
  CONFIG.HAS_LOCK         {1} \
  CONFIG.HAS_CACHE        {1} \
  CONFIG.HAS_QOS          {1} \
  CONFIG.HAS_PROT         {1} \
  CONFIG.HAS_REGION       {0} \
  CONFIG.REG_AW           {1} \
  CONFIG.REG_AR           {1} \
  CONFIG.REG_W            {1} \
  CONFIG.REG_B            {1} \
  CONFIG.REG_R            {1} \
]
