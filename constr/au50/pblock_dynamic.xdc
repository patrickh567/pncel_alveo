# *************************************************************************
#
# Alveo U50 host — DFX pblock for the dynamic region.
#
# Constrains the reconfigurable partition (`dynamic_inst/u_region`) to SLR1
# on the U50.  SLR0 holds XDMA (PCIE4C_X1Y0), both HBM stacks, CMS,
# satellite UART/GPIO, and the static-region AXI switches; placing the
# dynamic region in SLR1 keeps the PR boundary SLR-clean.
#
# CONTAIN_ROUTING + EXCLUDE_PLACEMENT + IS_SOFT=FALSE are required for a
# DFX reconfigurable partition (Vivado HDPR DRC).  They make the region
# exclusive to the RM's cells at place and route time.
#
# Used in implementation only — pblocks are post-synthesis floorplan, and
# applying them during OOC synth of the RMs would over-constrain.
#
# --------------------------------------------------------------------------
# Why per-resource-type `-add` ranges instead of `SLR1:SLR1`
# --------------------------------------------------------------------------
# An umbrella range like `SLR1:SLR1` or `CLOCKREGION_*` pulls EVERY site
# type in that region into the pblock, including static-only hard blocks
# like IOBs, SYSMONE4, PCIE4CE4, GTYE4_*, CMACE4, BITSLICE_*, ...  With
# EXCLUDE_PLACEMENT on, any static cell that is pinned/locked at one of
# those sites (e.g. `satellite_gpio_0[0:1]` on IOB_X0Y247/248 via
# pins.xdc C16/C17; the SLR1 `inst_sysmon_ssit_slave0` on SYSMONE4_X0Y1)
# trips `[DRC HDPR-6] Logic illegally placed` at place_design.
#
# Trying to carve those sites back out with `resize_pblock -remove` does
# not work for DFX partitions: SNAPPING_MODE forces tile-aligned ranges
# (sub-tile removes warn with `[Vivado 12-25128]`) and even tile-level
# removes get undone by the DFX pblock-integrity pass that aligns frames
# to clock regions.  Verified empirically across several impl attempts.
#
# The correct pattern is to never `-add` the offending types in the
# first place.  Enumerate sites in the target clock regions, bucket by
# SITE_TYPE, and only add ranges for the types an RM can legitimately
# use (SLICE, DSP, BRAM, URAM, clocking distribution, LAGUNA).  Static-
# only types (IOBs, SYSMON, PCIe, SERDES, config, HBM refclks) are
# deliberately omitted — the pblock visually overlaps their sites but
# doesn't claim them.  This matches UG909's rule: "the region may
# overlap other site types, but these other sites must not be included."
#
# The ranges below were derived from a one-shot query over SLR1 on the
# routed synth DCP; re-enumerate if the part changes or if new HDPR-6
# errors surface on site types not currently covered.
# *************************************************************************

create_pblock pblock_u_region
add_cells_to_pblock [get_pblocks pblock_u_region] [get_cells -quiet [list dynamic_inst/u_region]]
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

# SLR0 top-band (CLOCKREGION_X0Y2:X6Y3) — per-type conversion of the
# previous umbrella `-add {CLOCKREGION_X0Y2:CLOCKREGION_X6Y3}`.
#
# The umbrella was pulling XDMA's BUFG_GT sites, SYSMONE4, PCIE4CE4,
# GTYE4_*, CMACE4, and the IOB family into the pblock; with
# EXCLUDE_PLACEMENT on, that blocked XDMA's bufg_gt_userclk from its
# natural SLR0 Y2:Y3 placement and forced clk_wiz_hbm's input BUFGCE
# down to BUFGCE_X0Y23, beyond the 5-hop BUFG_GT → BUFGCE clock-rail
# limit.  route_design died on CLK_USERCLK as a result.
#
# Ranges below were enumerated from CLOCKREGION_X0Y2:X6Y3 alone (not
# SLR1) so they cover exactly the same fabric area as the old umbrella
# minus the static-only hard blocks.  Every Y max is strictly less than
# the corresponding SLR1 range's Y min, so these ranges are disjoint
# from the SLR1 adds above and their union is contiguous.
resize_pblock [get_pblocks pblock_u_region] -add {SLICE_X0Y120:SLICE_X205Y239}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_LEAF_X0Y8:BUFCE_LEAF_X1047Y15}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_X0Y48:BUFCE_ROW_X0Y95}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_FSR_X0Y2:BUFCE_ROW_FSR_X233Y3}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCE_X0Y48:BUFGCE_X0Y95}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCE_DIV_X0Y8:BUFGCE_DIV_X0Y15}
resize_pblock [get_pblocks pblock_u_region] -add {BUFGCTRL_X0Y16:BUFGCTRL_X0Y31}
resize_pblock [get_pblocks pblock_u_region] -add {DSP48E2_X0Y42:DSP48E2_X29Y89}
resize_pblock [get_pblocks pblock_u_region] -add {LAGUNA_X0Y0:LAGUNA_X27Y119}
# MMCM_X0Y2:Y3 and PLL_X0Y4:Y7 deliberately omitted — the SLR0 Y2:Y3
# MMCM sites host static_inst/system_config_inst/clk_wiz_cms_inst
# (MMCM_X0Y3) and are the natural home for clk_wiz_hbm_inst's MMCM.
# Claiming them with EXCLUDE_PLACEMENT=TRUE doesn't trip HDPR-6 — it
# redirects the static MMCMs to SLR0 Y0:Y1 sites, which drags their
# input BUFGCEs down to BUFGCE_X0Y22 range.  XDMA's bufg_gt_userclk is
# locked at BUFG_GT_X1Y74 by the PCIe IP, and the resulting Y74→Y22
# clock-rail span exceeds the 5-hop BUFG_GT → BUFGCE adjacency limit,
# so route_design dies on CLK_USERCLK.  RMs don't instantiate their
# own MMCM/PLL in this design; clocks route in from static via BUFGCE
# and the BUFCE_* distribution tree.
resize_pblock [get_pblocks pblock_u_region] -add {RAMB18_X0Y48:RAMB18_X11Y94}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB36_X0Y24:RAMB36_X11Y47}
resize_pblock [get_pblocks pblock_u_region] -add {URAM288_X0Y32:URAM288_X4Y63}

# SLR0 top-band right column (CLOCKREGION_X7Y2:X7Y3) — per-type ranges,
# enumerated from the synth DCP because the column also hosts XDMA's
# PCIe GTY quads (GTYE4_COMMON / GTYE4_CHANNEL), the BUFG_GT clocking
# fabric tied to those quads, the SLR0 SYSMONE4, the PCIE4CE4 site,
# and the device's CFGIO_SITE — every one of which must NOT be claimed
# by EXCLUDE_PLACEMENT (they're locked to static / config logic).
# Re-generate with `script/enumerate_pblock_x7_y23.tcl` if the part
# changes or if HDPR-6 surfaces a new static-only site type.
#
# >>> BEGIN auto-generated CLOCKREGION_X7Y2:X7Y3 ranges
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_LEAF_X1048Y8:BUFCE_LEAF_X1183Y15}
resize_pblock [get_pblocks pblock_u_region] -add {BUFCE_ROW_FSR_X234Y2:BUFCE_ROW_FSR_X261Y3}
resize_pblock [get_pblocks pblock_u_region] -add {DSP48E2_X30Y42:DSP48E2_X31Y89}
resize_pblock [get_pblocks pblock_u_region] -add {HARD_SYNC_X24Y4:HARD_SYNC_X27Y7}
resize_pblock [get_pblocks pblock_u_region] -add {LAGUNA_X28Y0:LAGUNA_X31Y119}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB18_X12Y48:RAMB18_X13Y95}
resize_pblock [get_pblocks pblock_u_region] -add {RAMB36_X12Y24:RAMB36_X13Y47}
resize_pblock [get_pblocks pblock_u_region] -add {SLICE_X206Y120:SLICE_X232Y239}
# <<< END auto-generated CLOCKREGION_X7Y2:X7Y3 ranges

set_property SNAPPING_MODE ON [get_pblocks pblock_u_region]
set_property IS_SOFT FALSE [get_pblocks pblock_u_region]
set_property EXCLUDE_PLACEMENT TRUE [get_pblocks pblock_u_region]
set_property CONTAIN_ROUTING TRUE [get_pblocks pblock_u_region]


# *************************************************************************
# Nested pblocks for the per-block traffic generators inside the RM.
#
# loopback_block u_block_a — drives HBM ports 00..15 (m_axi_hbm_00..15)
# loopback_block u_block_b — drives HBM ports 16..31 (m_axi_hbm_16..31,
#                            where m_axi_hbm_31 is the muxed XDMA+RM
#                            path landing on HBM port 31 via the
#                            static-side axi_hbm_switch.s01)
#
# Both blocks live entirely in SLR0's top band (clock region rows
# Y2..Y3), right next to the HBM stacks — minimises the route from
# each loopback FSM into the static-side `s_axi_hbm_NN` ports.  Block
# A takes the left half of that band (clock regions X0Y2:X3Y3), block
# B the right half (clock regions X4Y2:X7Y3).
#
# Per-type ranges (rather than a CLOCKREGION umbrella) keep the
# children's claim aligned with the parent's static-only exclusions
# in CLOCKREGION_X7Y2:X7Y3.  Each range is the parent's SLR0-band
# range sliced 4/7 between the two children on X (matching 4 vs 3
# clock-region columns); the parent's separate SLR0-X7 ranges go
# entirely to block B.  Single-site-X-column types (BUFCE_ROW,
# BUFGCE, BUFGCE_DIV, BUFGCTRL — all at site X=0 in the parent)
# physically sit in clock-region column X4 (the U50's clocking spine
# is in the middle of the device), so they go entirely to block B
# even though their site-coordinate X is 0.  No SLR1 sites — both
# blocks are pure-SLR0.
#
# IS_SOFT FALSE + EXCLUDE_PLACEMENT TRUE on both children gives a
# strict mutual-exclusion split: block A cells can't drift into
# block B's region or vice versa.  CONTAIN_ROUTING is left FALSE so
# routes can flow freely between the two halves and out into the
# parent's SLR1 area; the parent pblock_u_region's CONTAIN_ROUTING
# TRUE still keeps every route inside the DFX partition.  Off-by-a-
# few X coords from the 4/7 split should be tolerable since the
# unused gap is at most one column wide and the placer has plenty of
# breathing room within each half.
# *************************************************************************
create_pblock pblock_u_block_a
add_cells_to_pblock [get_pblocks pblock_u_block_a] \
    [get_cells -quiet [list dynamic_inst/u_region/u_block_a]]
resize_pblock [get_pblocks pblock_u_block_a] -add {SLICE_X0Y120:SLICE_X117Y239}
resize_pblock [get_pblocks pblock_u_block_a] -add {DSP48E2_X0Y42:DSP48E2_X17Y89}
resize_pblock [get_pblocks pblock_u_block_a] -add {LAGUNA_X0Y0:LAGUNA_X15Y119}
resize_pblock [get_pblocks pblock_u_block_a] -add {RAMB18_X0Y48:RAMB18_X6Y94}
resize_pblock [get_pblocks pblock_u_block_a] -add {RAMB36_X0Y24:RAMB36_X6Y47}
resize_pblock [get_pblocks pblock_u_block_a] -add {URAM288_X0Y32:URAM288_X2Y63}
resize_pblock [get_pblocks pblock_u_block_a] -add {BUFCE_LEAF_X0Y8:BUFCE_LEAF_X598Y15}
resize_pblock [get_pblocks pblock_u_block_a] -add {BUFCE_ROW_FSR_X0Y2:BUFCE_ROW_FSR_X133Y3}
set_property IS_SOFT FALSE [get_pblocks pblock_u_block_a]
set_property EXCLUDE_PLACEMENT TRUE [get_pblocks pblock_u_block_a]
set_property CONTAIN_ROUTING FALSE [get_pblocks pblock_u_block_a]

create_pblock pblock_u_block_b
add_cells_to_pblock [get_pblocks pblock_u_block_b] \
    [get_cells -quiet [list dynamic_inst/u_region/u_block_b]]
# All other immediate children of u_region (the inline AXI-Lite slave
# FSM flops, status aggregation, port-31 ID-shim) join block B's
# pblock so they place next to its half of the fabric instead of
# being pushed into SLR1 by the children's EXCLUDE_PLACEMENT.
# u_block_a is already claimed by pblock_u_block_a — most-specific
# assignment wins, so the wildcard plus the explicit exclusion below
# leaves it where it is.
add_cells_to_pblock [get_pblocks pblock_u_block_b] \
    [get_cells -quiet dynamic_inst/u_region/* \
        -filter {NAME != "dynamic_inst/u_region/u_block_a" && \
                 NAME != "dynamic_inst/u_region/u_block_b"}]
resize_pblock [get_pblocks pblock_u_block_b] -add {SLICE_X118Y120:SLICE_X232Y239}
resize_pblock [get_pblocks pblock_u_block_b] -add {DSP48E2_X18Y42:DSP48E2_X31Y89}
resize_pblock [get_pblocks pblock_u_block_b] -add {LAGUNA_X16Y0:LAGUNA_X31Y119}
resize_pblock [get_pblocks pblock_u_block_b] -add {RAMB18_X7Y48:RAMB18_X13Y95}
resize_pblock [get_pblocks pblock_u_block_b] -add {RAMB36_X7Y24:RAMB36_X13Y47}
resize_pblock [get_pblocks pblock_u_block_b] -add {URAM288_X3Y32:URAM288_X4Y63}
resize_pblock [get_pblocks pblock_u_block_b] -add {BUFCE_LEAF_X599Y8:BUFCE_LEAF_X1183Y15}
resize_pblock [get_pblocks pblock_u_block_b] -add {BUFCE_ROW_X0Y48:BUFCE_ROW_X0Y95}
resize_pblock [get_pblocks pblock_u_block_b] -add {BUFCE_ROW_FSR_X134Y2:BUFCE_ROW_FSR_X261Y3}
resize_pblock [get_pblocks pblock_u_block_b] -add {BUFGCE_X0Y48:BUFGCE_X0Y95}
resize_pblock [get_pblocks pblock_u_block_b] -add {BUFGCE_DIV_X0Y8:BUFGCE_DIV_X0Y15}
resize_pblock [get_pblocks pblock_u_block_b] -add {BUFGCTRL_X0Y16:BUFGCTRL_X0Y31}
set_property IS_SOFT FALSE [get_pblocks pblock_u_block_b]
set_property EXCLUDE_PLACEMENT TRUE [get_pblocks pblock_u_block_b]
set_property CONTAIN_ROUTING FALSE [get_pblocks pblock_u_block_b]


# *************************************************************************
# Static-region decoupler pblocks — one clock-region row below the
# nested RM block pblocks above (CLOCKREGION_*Y1, half-device width).
#
# The dynamic_decoupler_a / dynamic_decoupler_b modules sit just outside
# the PR partition and route every RM-side master through axi_decoupler
# instances on the way to the static-side switches / HBM IP.  Placing
# each decoupler bank in CLOCKREGION_*Y1 of the same X half as its
# corresponding RM block keeps the route from each loopback FSM
# (CLOCKREGION_*Y2:Y3) into its decoupler short — one clock-region
# vertical hop, no SLR crossing.
#
# Per-resource-type ranges (rather than a CLOCKREGION_X*Y1 umbrella)
# avoid claiming static-locked sites in those rows: the U50's HD/HP
# IO banks (IOB / HPIOBDIFF*), BITSLICE primitives, MMCM/PLL clocking
# (already used by static clk_wiz_50Mhz / clk_wiz_hbm and reachable
# for CMAC if added), GTYE4 / BUFG_GT / CMACE4 transceivers, and the
# RIU_OR / XIPHY_FEEDTHROUGH IO management blocks all stay outside
# the decoupler pblocks.
#
# IS_SOFT FALSE keeps the decouplers strictly inside their assigned
# half.  EXCLUDE_PLACEMENT is left FALSE so the rest of the static
# region (HBICAP control, system_config, HBM AXI fabric) is free to
# share the row.  CONTAIN_ROUTING is left FALSE so routes from the
# decouplers can run vertically up into the RM and down into HBM
# without being pinned to one row.
#
# Re-generate by running script/enumerate_pblock_x7_y23.tcl with the
# regions list pointed at {X0Y1..X3Y1} or {X4Y1..X7Y1} (or use the
# ad-hoc /tmp/enum_y1.tcl helper that already targets these ranges).
# *************************************************************************
create_pblock pblock_decouple_a
add_cells_to_pblock [get_pblocks pblock_decouple_a] \
    [get_cells -quiet [list u_decouple_a]]
resize_pblock [get_pblocks pblock_decouple_a] -add {SLICE_X0Y60:SLICE_X116Y119}
resize_pblock [get_pblocks pblock_decouple_a] -add {DSP48E2_X0Y18:DSP48E2_X15Y41}
resize_pblock [get_pblocks pblock_decouple_a] -add {RAMB18_X0Y24:RAMB18_X7Y47}
resize_pblock [get_pblocks pblock_decouple_a] -add {RAMB36_X0Y12:RAMB36_X7Y23}
resize_pblock [get_pblocks pblock_decouple_a] -add {URAM288_X0Y16:URAM288_X1Y31}
resize_pblock [get_pblocks pblock_decouple_a] -add {BUFCE_LEAF_X0Y4:BUFCE_LEAF_X591Y7}
resize_pblock [get_pblocks pblock_decouple_a] -add {BUFCE_ROW_FSR_X0Y1:BUFCE_ROW_FSR_X131Y1}
resize_pblock [get_pblocks pblock_decouple_a] -add {HARD_SYNC_X0Y2:HARD_SYNC_X15Y3}
set_property IS_SOFT FALSE [get_pblocks pblock_decouple_a]
set_property EXCLUDE_PLACEMENT FALSE [get_pblocks pblock_decouple_a]
set_property CONTAIN_ROUTING FALSE [get_pblocks pblock_decouple_a]

create_pblock pblock_decouple_b
add_cells_to_pblock [get_pblocks pblock_decouple_b] \
    [get_cells -quiet [list u_decouple_b u_slice_axi_hbm_31]]
resize_pblock [get_pblocks pblock_decouple_b] -add {SLICE_X117Y60:SLICE_X232Y119}
resize_pblock [get_pblocks pblock_decouple_b] -add {DSP48E2_X16Y18:DSP48E2_X31Y41}
resize_pblock [get_pblocks pblock_decouple_b] -add {RAMB18_X8Y24:RAMB18_X13Y47}
resize_pblock [get_pblocks pblock_decouple_b] -add {RAMB36_X8Y12:RAMB36_X13Y23}
resize_pblock [get_pblocks pblock_decouple_b] -add {URAM288_X2Y16:URAM288_X4Y31}
resize_pblock [get_pblocks pblock_decouple_b] -add {BUFCE_LEAF_X592Y4:BUFCE_LEAF_X1183Y7}
resize_pblock [get_pblocks pblock_decouple_b] -add {BUFCE_ROW_X0Y24:BUFCE_ROW_X0Y47}
resize_pblock [get_pblocks pblock_decouple_b] -add {BUFCE_ROW_FSR_X132Y1:BUFCE_ROW_FSR_X261Y1}
resize_pblock [get_pblocks pblock_decouple_b] -add {BUFGCE_X0Y24:BUFGCE_X0Y47}
resize_pblock [get_pblocks pblock_decouple_b] -add {BUFGCE_DIV_X0Y4:BUFGCE_DIV_X0Y7}
resize_pblock [get_pblocks pblock_decouple_b] -add {BUFGCTRL_X0Y8:BUFGCTRL_X0Y15}
resize_pblock [get_pblocks pblock_decouple_b] -add {HARD_SYNC_X16Y2:HARD_SYNC_X27Y3}
set_property IS_SOFT FALSE [get_pblocks pblock_decouple_b]
set_property EXCLUDE_PLACEMENT FALSE [get_pblocks pblock_decouple_b]
set_property CONTAIN_ROUTING FALSE [get_pblocks pblock_decouple_b]


# Fabric placement resources

# SLR-crossing Laguna registers (only the SLR1 side; the SLR0 side stays
# in the static region)

# Clock distribution inside the RP

# MMCM / PLL — SLR1 clock-region set only.  If HDPR-6 fires on any static
# clocking primitive that ended up inside this range, drop these two adds
# (RMs don't generally need to instantiate their own MMCM/PLL).


# Debug-hub clock constraints live in constr/au50/debug.xdc so they
# apply in both DFX and flat builds.

