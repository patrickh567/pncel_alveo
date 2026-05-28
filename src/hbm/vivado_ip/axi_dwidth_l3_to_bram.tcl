# *************************************************************************
# AXI4 width converter: L3 cache master (512 b) → axi_crossbar_bram
# slave port (256 b).  Used by mini_dice_alveo_dynamic_region.sv to
# adapt the chip's L3-side AXI4 master into the BRAM-side crossbar SI.
#
# Mirrors axi_dwidth_bridge_to_hbm.tcl (same widths, same Xilinx IP) —
# different module name so both can coexist in projects that need both.
# *************************************************************************
create_ip -name axi_dwidth_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_dwidth_l3_to_bram

set_ip_properties_safe axi_dwidth_l3_to_bram [list \
  CONFIG.SI_DATA_WIDTH        {512} \
  CONFIG.MI_DATA_WIDTH        {256} \
  CONFIG.ADDR_WIDTH           {32}  \
  CONFIG.SI_ID_WIDTH          {20}  \
  CONFIG.MAX_SPLIT_BEATS      {16}  \
]
