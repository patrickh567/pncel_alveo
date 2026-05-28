# *************************************************************************
#
# Static-side HBM register-slice pblocks — scoped to the default
# (loopback HBM traffic-generator) reconfigurable module only.
#
# `u_slice_a` and `u_slice_b` (in `alveo_host_top`) bank the
# axi_register_slice_hbm instances that sit between each direct HBM
# decoupler and the HBM IP.  They're useful when ALL 31 direct HBM
# channels carry traffic, which is the loopback RM's workload.  Other
# RMs (e.g., the MMU) only exercise 12 channels and don't benefit from
# the same tight floorplan, so this XDC is added to the loopback RM's
# fileset only and inherited by impl_1 alone.
#
# Geometry mirrors the per-side decoupler bands (CLOCKREGION_*Y1):
#   pblock_u_slice_a — left half  (X0:X3 Y1) — same row as
#                       pblock_decouple_a, sized loose enough to share
#                       the band with the decoupler cells.
#   pblock_u_slice_b — right half (X4:X7 Y1) — sibling on the other
#                       half of the bottom band.
#
# Property choices match the decoupler pblocks: IS_SOFT FALSE keeps
# each bank confined to its half but EXCLUDE_PLACEMENT FALSE +
# CONTAIN_ROUTING FALSE leave room for the existing decoupler /
# axi_register_slice_hbm_mux cells already in the same area.
#
# Used in implementation only (post-synthesis floorplan).
# *************************************************************************

create_pblock pblock_u_slice_a
add_cells_to_pblock [get_pblocks pblock_u_slice_a] \
    [get_cells -quiet [list u_slice_a]]
resize_pblock [get_pblocks pblock_u_slice_a] -add {SLICE_X0Y60:SLICE_X116Y119}
resize_pblock [get_pblocks pblock_u_slice_a] -add {DSP48E2_X0Y18:DSP48E2_X15Y41}
resize_pblock [get_pblocks pblock_u_slice_a] -add {RAMB18_X0Y24:RAMB18_X7Y47}
resize_pblock [get_pblocks pblock_u_slice_a] -add {RAMB36_X0Y12:RAMB36_X7Y23}
resize_pblock [get_pblocks pblock_u_slice_a] -add {URAM288_X0Y16:URAM288_X1Y31}
resize_pblock [get_pblocks pblock_u_slice_a] -add {BUFCE_LEAF_X0Y4:BUFCE_LEAF_X591Y7}
resize_pblock [get_pblocks pblock_u_slice_a] -add {BUFCE_ROW_FSR_X0Y1:BUFCE_ROW_FSR_X131Y1}
resize_pblock [get_pblocks pblock_u_slice_a] -add {HARD_SYNC_X0Y2:HARD_SYNC_X15Y3}
set_property IS_SOFT FALSE [get_pblocks pblock_u_slice_a]
set_property EXCLUDE_PLACEMENT FALSE [get_pblocks pblock_u_slice_a]
set_property CONTAIN_ROUTING FALSE [get_pblocks pblock_u_slice_a]

create_pblock pblock_u_slice_b
add_cells_to_pblock [get_pblocks pblock_u_slice_b] \
    [get_cells -quiet [list u_slice_b]]
resize_pblock [get_pblocks pblock_u_slice_b] -add {SLICE_X117Y60:SLICE_X232Y119}
resize_pblock [get_pblocks pblock_u_slice_b] -add {DSP48E2_X16Y18:DSP48E2_X31Y41}
resize_pblock [get_pblocks pblock_u_slice_b] -add {RAMB18_X8Y24:RAMB18_X13Y47}
resize_pblock [get_pblocks pblock_u_slice_b] -add {RAMB36_X8Y12:RAMB36_X13Y23}
resize_pblock [get_pblocks pblock_u_slice_b] -add {URAM288_X2Y16:URAM288_X4Y31}
resize_pblock [get_pblocks pblock_u_slice_b] -add {BUFCE_LEAF_X592Y4:BUFCE_LEAF_X1183Y7}
resize_pblock [get_pblocks pblock_u_slice_b] -add {BUFCE_ROW_X0Y24:BUFCE_ROW_X0Y47}
resize_pblock [get_pblocks pblock_u_slice_b] -add {BUFCE_ROW_FSR_X132Y1:BUFCE_ROW_FSR_X261Y1}
resize_pblock [get_pblocks pblock_u_slice_b] -add {BUFGCE_X0Y24:BUFGCE_X0Y47}
resize_pblock [get_pblocks pblock_u_slice_b] -add {BUFGCE_DIV_X0Y4:BUFGCE_DIV_X0Y7}
resize_pblock [get_pblocks pblock_u_slice_b] -add {BUFGCTRL_X0Y8:BUFGCTRL_X0Y15}
resize_pblock [get_pblocks pblock_u_slice_b] -add {HARD_SYNC_X16Y2:HARD_SYNC_X27Y3}
set_property IS_SOFT FALSE [get_pblocks pblock_u_slice_b]
set_property EXCLUDE_PLACEMENT FALSE [get_pblocks pblock_u_slice_b]
set_property CONTAIN_ROUTING FALSE [get_pblocks pblock_u_slice_b]
