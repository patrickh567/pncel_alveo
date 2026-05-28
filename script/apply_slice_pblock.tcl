# *************************************************************************
#
# OPT_DESIGN.TCL.PRE hook — applies the static-side HBM register-slice
# pblocks (pblock_u_slice_a / pblock_u_slice_b) at impl time.
#
# Why a per-run hook instead of an XDC in the project: the cells being
# constrained (`u_slice_a`, `u_slice_b`) are static-region instances at
# the top of `alveo_host_top`.  Attaching the XDC to a reconfig module
# fails because Vivado roots `current_instance` at the RM and forces
# `CONTAIN_ROUTING=TRUE` on RM-attached pblocks (DFX rule: routes inside
# an RM pblock can't leak into static).  Putting the XDC in `constrs_1`
# would apply it to every impl run, including `child_0_impl_1` (the
# MMU bitstream), which doesn't benefit from the tight floorplan.
#
# Sourcing the XDC from a pre-impl hook on `impl_1` only side-steps both
# problems: `current_instance` is at design root when the hook runs, so
# `get_cells u_slice_a` resolves to the static cell; and the hook is
# attached to `impl_1` only, so `child_0_impl_1` (config_2 = MMU) skips
# it entirely.
#
# *************************************************************************

read_xdc [file normalize [file dirname [info script]]/../constr/au50/pblock_slice_default_rm.xdc]
