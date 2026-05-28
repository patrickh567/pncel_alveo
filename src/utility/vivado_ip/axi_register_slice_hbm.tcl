# *************************************************************************
# AXI Register Slice — 256b AXI3 variant, used between each of the 31
# HBM slave ports s_axi_01..31 coming from the RM and the HBM IP itself
# inside hbm_wrapper.
#
# Cuts the combinational paths that flow from the RM's DMA-to-HBM tree
# leaves (or MMU matmul engines in the MMU RM) across the RP boundary
# and into the HBM IP.  Without these slices, every HBM-bound AXI
# transaction requires a single-cycle settle across the full
# RM-edge-to-HBM-column span of SLR0, which dominates WNS on the
# busier ports.  Full register slices (REG_* = 1) add 1 aclk cycle of
# latency per AXI channel per hop.
#
# Matches HBM port widths exactly:
#   PROTOCOL = AXI3   (4-bit AWLEN, 2-bit AWLOCK)
#   DATA_WIDTH = 256  (per-port HBM native width)
#   ID_WIDTH = 6      (HBM port ID width)
#   ADDR_WIDTH = 64   (design-wide addr width; HBM trims internally)
#
# Source IP : xilinx.com:ip:axi_register_slice:2.1
# *************************************************************************

create_ip -name axi_register_slice \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_register_slice_hbm

set_ip_properties_safe axi_register_slice_hbm [list \
  CONFIG.Component_Name   {axi_register_slice_hbm} \
  CONFIG.PROTOCOL         {AXI3} \
  CONFIG.ADDR_WIDTH       {64} \
  CONFIG.DATA_WIDTH       {256} \
  CONFIG.ID_WIDTH         {6} \
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
  CONFIG.REG_R            {1} \
  CONFIG.REG_B            {1} \
]
