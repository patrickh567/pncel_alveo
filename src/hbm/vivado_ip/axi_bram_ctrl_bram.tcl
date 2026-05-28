# *************************************************************************
# 64 KB AXI4 BRAM controller — primary on-chip data memory.
#
#   axi_crossbar_bram (2 SI → 1 MI, AXI4)  ─►  axi_bram_ctrl_bram
#                                                       │
#                                              internal blk_mem_gen
#                                              (BMG_INSTANCE=INTERNAL)
#
# Sizing: 256 b data × 2048 entries = 64 KB.  AXI_ADDR_WIDTH auto-derives
# to log2(64 KB) = 16 b; the wrapper in pncel_dynamic_region.sv slices
# the crossbar's 64 b address down to 16 b.
#
# ID_WIDTH=5 because the 2-SI crossbar widens IDs by 1 bit
# (NUM_SI=2 → log2(2)=1) on top of the input ID_WIDTH=4.
# *************************************************************************

create_ip -name axi_bram_ctrl \
          -vendor xilinx.com \
          -library ip \
          -version 4.1 \
          -module_name axi_bram_ctrl_bram

set_ip_properties_safe axi_bram_ctrl_bram [list \
  CONFIG.PROTOCOL              {AXI4}      \
  CONFIG.DATA_WIDTH            {256}       \
  CONFIG.ID_WIDTH              {5}         \
  CONFIG.MEM_DEPTH             {2048}      \
  CONFIG.SUPPORTS_NARROW_BURST {1}         \
  CONFIG.SINGLE_PORT_BRAM      {1}         \
  CONFIG.BMG_INSTANCE          {INTERNAL}  \
  CONFIG.READ_LATENCY          {1}         \
  CONFIG.ECC_TYPE              {0}         \
]
