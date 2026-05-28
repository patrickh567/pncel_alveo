# *************************************************************************
# AXI4 width converter: bridge's 512-bit m_* master → 256-bit input to
# the AXI4→AXI3 protocol converter that feeds HBM port 0.  Sits between
# axi_aurora_bridge_inv.m_* and axi_protocol_converter_bridge.
#
# Bridge DATA_W is 512 (harmonised with the zcu102 bridge) and the
# downstream HBM-port path is 256 → this converter narrows from the
# bridge to the protocol converter.  See plan
# `curried-wandering-hanrahan.md`, Phase 0.
# *************************************************************************
create_ip -name axi_dwidth_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_dwidth_bridge_to_hbm

set_ip_properties_safe axi_dwidth_bridge_to_hbm [list \
  CONFIG.SI_DATA_WIDTH        {512} \
  CONFIG.MI_DATA_WIDTH        {256} \
  CONFIG.ADDR_WIDTH           {32}  \
  CONFIG.SI_ID_WIDTH          {20}  \
  CONFIG.MAX_SPLIT_BEATS      {16}  \
]
