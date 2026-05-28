# *************************************************************************
#
# Alveo U50 host — top-level timing constraints.
#
# Only covers constraints on top-level ports; every internal clock domain
# (XDMA axi_aclk, HBM AXI clocks, CMS aclk_ctrl) is constrained by the
# clocking XDC that ships inside the respective IP .gen tree. Cross-domain
# paths between axi_aclk and the HBM AXI clocks are handled by the
# axi_clock_converter instances inside axi_hbm_switch / axi_dma_switch, so
# no manual set_max_delay / set_false_path is required here.
#
# *************************************************************************

# PCIe Gen3 x16 reference clock — 100 MHz differential input
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# Asynchronous PERST# from the host
set_false_path -through [get_ports pcie_rstn]


