# *************************************************************************
# AXI Register Slice — cuts the combinational path on the 512b AXI4
# DMA-direct path inside the static region (see src/alveo_u50_static.sv,
# axi_dma_hbm_regslice):
#
#   axi_dma_switch.m01 → slice → axi_hbm_switch.s00 (DMA → HBM direct)
#
# The PR-mux-return path (RM → axi_hbm_switch.s01) is now 256b AXI3 and
# uses axi_register_slice_hbm — this 512b AXI4 slice is unused on that
# branch.
#
# Before this slice was added, the worst-case path in impl_1 crossed
# the RP boundary with 1.4 ns of route going in and 3.1 ns coming back
# (WNS = -2.285 ns).  A full register slice (REG_* = 1) adds 1 aclk
# cycle of latency per AXI channel and bounds the route at the slice
# input and output FDREs instead of leaking all the way across SLR0.
#
# 512b AXI4, 64b addr, 4b ID — matches XDMA's DMA path widths.
#
# Source IP : xilinx.com:ip:axi_register_slice:2.1
# *************************************************************************

create_ip -name axi_register_slice \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_register_slice_rp

set_ip_properties_safe axi_register_slice_rp [list \
  CONFIG.Component_Name   {axi_register_slice_rp} \
  CONFIG.PROTOCOL         {AXI4} \
  CONFIG.ADDR_WIDTH       {64} \
  CONFIG.DATA_WIDTH       {512} \
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
  CONFIG.HAS_REGION       {1} \
  CONFIG.REG_AW           {1} \
  CONFIG.REG_AR           {1} \
  CONFIG.REG_W            {1} \
  CONFIG.REG_R            {1} \
  CONFIG.REG_B            {1} \
]
