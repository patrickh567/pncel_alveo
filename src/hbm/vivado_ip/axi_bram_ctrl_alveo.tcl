# *************************************************************************
# 64 KB AXI4 BRAM controller for the mini_dice_alveo image.
#
#   axi_crossbar_alveo (2 SI → 1 MI, AXI4, ID=20)  ─►  axi_bram_ctrl_alveo
#                                                              │
#                                                     internal blk_mem_gen
#                                                     (BMG_INSTANCE=INTERNAL)
#
# Sizing: 256 b data × 2048 entries = 64 KB.  AXI_ADDR_WIDTH auto-derives
# to log2(64 KB) = 16 b; the wrapper slices the crossbar's 64 b address
# down to 16 b at the SI port.
#
# ID_WIDTH=21 because the 2-SI crossbar widens IDs by 1 bit
# (NUM_SI=2 → log2(2)=1) on top of the input ID_WIDTH=20.
# *************************************************************************

create_ip -name axi_bram_ctrl \
          -vendor xilinx.com \
          -library ip \
          -version 4.1 \
          -module_name axi_bram_ctrl_alveo

set_ip_properties_safe axi_bram_ctrl_alveo [list \
  CONFIG.PROTOCOL              {AXI4}      \
  CONFIG.DATA_WIDTH            {256}       \
  CONFIG.ID_WIDTH              {21}        \
  CONFIG.MEM_DEPTH             {2048}      \
  CONFIG.SUPPORTS_NARROW_BURST {1}         \
  CONFIG.SINGLE_PORT_BRAM      {1}         \
  CONFIG.BMG_INSTANCE          {INTERNAL}  \
  CONFIG.READ_LATENCY          {1}         \
  CONFIG.ECC_TYPE              {0}         \
]
