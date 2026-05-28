# *************************************************************************
# AXI4 width converter: XDMA's 256-bit data (post clock-converter) →
# bridge's 512-bit s_full slave.  Sits between axi_clock_converter_data
# and axi_aurora_bridge_inv.
#
# Bridge DATA_W is 512 to match the zcu102-side bridge instantiation
# (mini_dice_zcu102_top.sv) — keeping the two endpoints on the same
# bridge geometry is what lets the cross-coupled Aurora streams in the
# combined-sim TB actually exchange coherent packets.  See plan
# `curried-wandering-hanrahan.md`, Phase 0.
# *************************************************************************
create_ip -name axi_dwidth_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_dwidth_xdma_to_bridge

set_ip_properties_safe axi_dwidth_xdma_to_bridge [list \
  CONFIG.SI_DATA_WIDTH        {256} \
  CONFIG.MI_DATA_WIDTH        {512} \
  CONFIG.ADDR_WIDTH           {64}  \
  CONFIG.SI_ID_WIDTH          {4}   \
  CONFIG.MAX_SPLIT_BEATS      {16}  \
]
