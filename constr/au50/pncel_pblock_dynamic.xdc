# *************************************************************************
#
# pncel-alveo DFX pblock for the dynamic region.
#
# Almost a verbatim copy of the original constr/au50/pblock_dynamic.xdc —
# same SLR1 + SLR0-top-band per-resource-type ranges, same EXCLUDE_PLACEMENT
# / CONTAIN_ROUTING semantics, same XDMA/SYSMON/PCIe/MMCM exclusions.  The
# only structural difference is that this file does NOT define the
# u_block_a / u_block_b / decouple_a / decouple_b nested child pblocks —
# pncel's dynamic region has its own internal floorplan (or no nested
# pblocks at all in the MVP scratch-RM), and pncel's static region uses
# only TWO axi_decoupler instances (u_decouple_data, u_decouple_ctrl) which
# are small enough that the placer handles them without a dedicated
# pblock.
#
# When HBM lands in the dynamic region (next iteration), add SLR0 Y0:Y1
# bottom-band ranges here so the HBM PHY columns and HBM controller
# fabric are inside the partition.  MMCM_X0Y3 will need to be added too
# for clk_wiz_hbm.
#
# Used in implementation only.
#
# *************************************************************************

create_pblock pblock_u_region
add_cells_to_pblock [get_pblocks pblock_u_region] [get_cells -quiet [list dynamic_inst/u_region]]

# SLR1 — main fabric area for the RM.
resize_pblock [get_pblocks pblock_u_region] -add {SLICE_X0Y240:SLICE_X232Y479}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_LEAF_X0Y16:BUFCE_LEAF_X1183Y31}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_X0Y96:BUFCE_ROW_X0Y191}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_FSR_X0Y4:BUFCE_ROW_FSR_X261Y7}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCE_X0Y96:BUFGCE_X0Y191}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCE_DIV_X0Y16:BUFGCE_DIV_X0Y31}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCTRL_X0Y32:BUFGCTRL_X0Y63}
resize_pblock [get_pblocks pblock_u_region] -add {DSP48E2_X0Y90:DSP48E2_X31Y185}
resize_pblock [get_pblocks pblock_u_region] -add {LAGUNA_X0Y120:LAGUNA_X31Y239}
resize_pblock [get_pblocks pblock_u_region] -add {MMCM_X0Y4:MMCM_X0Y7}
resize_pblock [get_pblocks pblock_u_region] -add {PLL_X0Y8:PLL_X0Y15}
resize_pblock [get_pblocks pblock_u_region] -add {URAM288_X0Y64:URAM288_X4Y127}

# SLR0 top-band (CLOCKREGION_X0Y2:X6Y3) — fabric area, per-type to skip
# XDMA/SYSMON/PCIe/MMCM hard blocks.
resize_pblock [get_pblocks pblock_u_region] -add {SLICE_X0Y120:SLICE_X205Y239}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_LEAF_X0Y8:BUFCE_LEAF_X1047Y15}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_X0Y48:BUFCE_ROW_X0Y95}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_FSR_X0Y2:BUFCE_ROW_FSR_X233Y3}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCE_X0Y48:BUFGCE_X0Y95}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCE_DIV_X0Y8:BUFGCE_DIV_X0Y15}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCTRL_X0Y16:BUFGCTRL_X0Y31}
resize_pblock [get_pblocks pblock_u_region] -add {DSP48E2_X0Y42:DSP48E2_X29Y89}
resize_pblock [get_pblocks pblock_u_region] -add {LAGUNA_X0Y0:LAGUNA_X27Y119}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB18_X0Y48:RAMB18_X11Y94}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB36_X0Y24:RAMB36_X11Y47}
resize_pblock [get_pblocks pblock_u_region] -add {URAM288_X0Y32:URAM288_X4Y63}

# MMCM_X0Y2:Y3 and PLL_X0Y4:Y7 deliberately omitted — those are the
# natural home for static system_config's clk_wiz_cms.  When HBM moves
# into dynamic and clk_wiz_hbm comes with it, MMCM_X0Y3 will need to be
# added here.

# SLR0 top-band right column (CLOCKREGION_X7Y2:Y3) — per-type, excludes
# XDMA's GTYE4/BUFG_GT/PCIE4CE4/SYSMONE4/CFGIO sites (XDMA hard blocks).
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_LEAF_X1048Y8:BUFCE_LEAF_X1183Y15}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_FSR_X234Y2:BUFCE_ROW_FSR_X261Y3}
resize_pblock [get_pblocks pblock_u_region] -add {DSP48E2_X30Y42:DSP48E2_X31Y89}
resize_pblock [get_pblocks pblock_u_region] -add {HARD_SYNC_X24Y4:HARD_SYNC_X27Y7}
resize_pblock [get_pblocks pblock_u_region] -add {LAGUNA_X28Y0:LAGUNA_X31Y119}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB18_X12Y48:RAMB18_X13Y95}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB36_X12Y24:RAMB36_X13Y47}
resize_pblock [get_pblocks pblock_u_region] -add {SLICE_X206Y120:SLICE_X232Y239}

set_property SNAPPING_MODE       ON    [get_pblocks pblock_u_region]
set_property IS_SOFT             FALSE [get_pblocks pblock_u_region]
set_property EXCLUDE_PLACEMENT   TRUE  [get_pblocks pblock_u_region]
set_property CONTAIN_ROUTING     TRUE  [get_pblocks pblock_u_region]
