# *************************************************************************
#
# Copyright 2020 Xilinx, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# *************************************************************************
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK Enable [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 63.8 [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN disable [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR Yes [current_design]
set_operating_conditions -design_power_budget 63

# Debug-hub clock constraints live in constr/au50/debug.xdc (loaded with
# PROCESSING_ORDER LATE, USED_IN implementation).

# -----------------------------------------------------------------------
# Cross-domain false paths for the static-region control bits.
#
# The static register map (`static_inst/static_reg_map_inst/regs_reg[*][*]`)
# is now clocked on icap_clk (100 MHz) because the AXI-Lite switch network
# runs at 100 MHz. Two bits of register 0 drive quasi-static software
# controls consumed on the axi_aclk (250 MHz) side:
#
#   regs_reg[0][0]  →  decouple      (34 × axi_decoupler, combinational)
#   regs_reg[0][1]  →  ~gate for dyn_aresetn (dynamic region's async
#                                             reset + _dy axi_if aresetn)
#
# Both targets are either combinational passthrough (decouple → mux
# gating inside axi_decoupler) or used as an async reset, so the
# cross-domain handshake is inherently safe — but without this
# constraint Vivado STA would report large TNS across these paths
# since no explicit synchronizers sit on them.  Quasi-static software
# bits are the canonical use-case for set_false_path.
# -----------------------------------------------------------------------
set_false_path -from [get_cells -hierarchical -regexp {.*static_reg_map_inst/regs_reg\[0\]\[[01]\]}]

# clk_wiz_hbm uses PRIM_SOURCE=No_buffer (see
# src/hbm/vivado_ip/clk_wiz_hbm.tcl), so no clkin1_bufg BUFGCE is
# instantiated and no LOC constraints on the MMCM are needed — the
# placer is free to put the MMCM wherever HBM REF_CLK output routing
# is cheapest.

