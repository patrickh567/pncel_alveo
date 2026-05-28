# *************************************************************************
#
# VCS simulation driver for the pncel-alveo HBM testbench, via Vivado's
# export_simulation flow.
#
# The heavy lifting is done by `export_simulation -simulator vcs`, which
# emits a self-contained compile/elaborate/simulate shell script for the
# tb_pncel_hbm fileset.
#
# `+define+SIMULATION +define+__au50__` is set on the simset in
# script/pncel_build.tcl so the vlogan calls for the user RTL take the
# testbench-mode port lists on pncel_top / pncel_static / pncel_dynamic
# / pncel_dynamic_region (no XDMA, no PCIe, Aurora replaced by sim
# pass-through).
#
# Usage:
#   make                — run the HBM TB through compile+elab+simulate
#   make hbm            — same as `make`, explicit
#   make hbm-compile    — analyzer pass only
#   make hbm-elaborate  — compile + elaborate
#   make hbm-simulate   — compile + elaborate + run
#   make export         — regenerate Vivado script for the TB
#   make clean          — wipe the export directory
#
# Prerequisites:
#   - VCS on PATH
#   - `vivado -mode batch -source script/pncel_build.tcl` already run
#     from the repo root (produces the .xpr with sim_1 registered and
#     all IPs generated).
#
# *************************************************************************

# Use bash with pipefail so failures on the left side of a pipe propagate
# through any downstream filters in recipes.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

ROOT_DIR    := $(shell cd .. && pwd)
SIM_DIR     := $(CURDIR)
BUILD_DIR   := $(ROOT_DIR)/build/pncel_alveo
PROJECT     := $(BUILD_DIR)/pncel_alveo.xpr

VIVADO      ?= vivado
SIMLIB_DIR  ?= /data/pdh4/vivado_simlib

# -------------------------------------------------------------------------
# HBM testbench (sim_1 fileset, tb_pncel_hbm top)
# -------------------------------------------------------------------------
HBM_SIMSET     := sim_1
HBM_EXPORT_DIR := $(SIM_DIR)/export_vcs
HBM_EXPORT_VCS := $(HBM_EXPORT_DIR)/vcs
HBM_SH         := $(HBM_EXPORT_VCS)/tb_pncel_hbm.sh

# -------------------------------------------------------------------------
# Aurora packet-bridge testbench (sim_aurora fileset, tb_pncel_aurora top)
# -------------------------------------------------------------------------
AUR_SIMSET     := sim_aurora
AUR_EXPORT_DIR := $(SIM_DIR)/export_vcs_aurora
AUR_EXPORT_VCS := $(AUR_EXPORT_DIR)/vcs
AUR_SH         := $(AUR_EXPORT_VCS)/tb_pncel_aurora.sh

.PHONY: all export clean \
        hbm hbm-export hbm-compile hbm-elaborate hbm-simulate \
        aurora aurora-export aurora-compile aurora-elaborate aurora-simulate

all: hbm

export: hbm-export aurora-export

clean:
	rm -rf $(HBM_EXPORT_DIR) $(AUR_EXPORT_DIR)

# =========================================================================
# HBM testbench targets
# =========================================================================

# Regenerate the VCS shell script only when the project file is newer
# than the last export.  The script uses absolute paths, so edits to
# src/*.sv or sim/tb_pncel_hbm.sv are picked up by vlogan on the next
# compile without a re-export — only structural changes (new IP, changed
# fileset) require `make hbm-export`.
$(HBM_SH): $(PROJECT) $(SIM_DIR)/export_sim.tcl
	$(VIVADO) -mode batch -nojournal -nolog \
	    -source $(SIM_DIR)/export_sim.tcl \
	    -tclargs $(PROJECT) $(HBM_EXPORT_DIR) $(SIMLIB_DIR) $(HBM_SIMSET)

hbm-export: $(HBM_SH)

hbm-compile: $(HBM_SH)
	cd $(HBM_EXPORT_VCS) && ./tb_pncel_hbm.sh -step compile

hbm-elaborate: hbm-compile
	cd $(HBM_EXPORT_VCS) && ./tb_pncel_hbm.sh -step elaborate

hbm-simulate: hbm-elaborate
	echo 'run; quit' > $(HBM_EXPORT_VCS)/simulate.do
	cd $(HBM_EXPORT_VCS) && ./tb_pncel_hbm.sh -step simulate

hbm: hbm-simulate

# =========================================================================
# Aurora packet-bridge testbench targets
# =========================================================================

$(AUR_SH): $(PROJECT) $(SIM_DIR)/export_sim.tcl
	$(VIVADO) -mode batch -nojournal -nolog \
	    -source $(SIM_DIR)/export_sim.tcl \
	    -tclargs $(PROJECT) $(AUR_EXPORT_DIR) $(SIMLIB_DIR) $(AUR_SIMSET)

aurora-export: $(AUR_SH)

aurora-compile: $(AUR_SH)
	cd $(AUR_EXPORT_VCS) && ./tb_pncel_aurora.sh -step compile

aurora-elaborate: aurora-compile
	cd $(AUR_EXPORT_VCS) && ./tb_pncel_aurora.sh -step elaborate

aurora-simulate: aurora-elaborate
	echo 'run; quit' > $(AUR_EXPORT_VCS)/simulate.do
	cd $(AUR_EXPORT_VCS) && ./tb_pncel_aurora.sh -step simulate

aurora: aurora-simulate
