# *************************************************************************
# AXI4 crossbar in front of the BRAM controller.  Merges two AXI4
# masters onto a single MI that drives axi_bram_ctrl_bram:
#
#   SI[0] = aurora-bridge return path (AXI4 256b, post-CDC, aclk)
#   SI[1] = XDMA direct path          (AXI4 256b, aclk, from s_axi_hbm)
#
# NUM_MI=1 with M00 covering the entire 64-bit space so every transaction
# routes to MI[0] regardless of address.  The crossbar widens IDs by one
# bit (NUM_SI=2 → log2=1), so the MI port carries a 5-bit ID — the
# downstream BRAM controller is configured for ID_WIDTH=5 to match.
# *************************************************************************

create_ip -name axi_crossbar \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_crossbar_bram

set_ip_properties_safe axi_crossbar_bram [list \
  CONFIG.PROTOCOL              {AXI4}                  \
  CONFIG.NUM_SI                {2}                     \
  CONFIG.NUM_MI                {1}                     \
  CONFIG.ADDR_WIDTH            {64}                    \
  CONFIG.DATA_WIDTH            {256}                   \
  CONFIG.ID_WIDTH              {4}                     \
  CONFIG.CONNECTIVITY_MODE     {SAMD}                  \
  CONFIG.M00_A00_BASE_ADDR     {0x0000000000000000}    \
  CONFIG.M00_A00_ADDR_WIDTH    {64}                    \
  CONFIG.AWUSER_WIDTH          {0}                     \
  CONFIG.ARUSER_WIDTH          {0}                     \
  CONFIG.WUSER_WIDTH           {0}                     \
  CONFIG.RUSER_WIDTH           {0}                     \
  CONFIG.BUSER_WIDTH           {0}                     \
]
