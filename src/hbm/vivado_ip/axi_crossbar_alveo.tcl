# *************************************************************************
# 2:1 AXI4 crossbar for the mini_dice_alveo image.
#
#   SI[0] = chip L3 master via axi_dwidth_l3_to_bram (AXI4 256b, ID=20)
#   SI[1] = XDMA direct path s_axi_hbm           (AXI4 256b, ID=20 — the
#                                                 4 b XDMA ID is zero-
#                                                 extended at the wrapper)
#   MI    = single output to axi_bram_ctrl_alveo
#
# NUM_MI=1 with M00 covering the entire 64-bit space so every transaction
# routes to MI[0] regardless of address.  The crossbar widens IDs by one
# bit (NUM_SI=2 → log2=1), so the MI port carries a 21-bit ID — the
# downstream BRAM controller is configured for ID_WIDTH=21 to match.
# *************************************************************************

create_ip -name axi_crossbar \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_crossbar_alveo

set_ip_properties_safe axi_crossbar_alveo [list \
  CONFIG.PROTOCOL              {AXI4}                  \
  CONFIG.NUM_SI                {2}                     \
  CONFIG.NUM_MI                {1}                     \
  CONFIG.ADDR_WIDTH            {64}                    \
  CONFIG.DATA_WIDTH            {256}                   \
  CONFIG.ID_WIDTH              {20}                    \
  CONFIG.CONNECTIVITY_MODE     {SAMD}                  \
  CONFIG.M00_A00_BASE_ADDR     {0x0000000000000000}    \
  CONFIG.M00_A00_ADDR_WIDTH    {64}                    \
  CONFIG.AWUSER_WIDTH          {0}                     \
  CONFIG.ARUSER_WIDTH          {0}                     \
  CONFIG.WUSER_WIDTH           {0}                     \
  CONFIG.RUSER_WIDTH           {0}                     \
  CONFIG.BUSER_WIDTH           {0}                     \
]
