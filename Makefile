SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

VIVADO_SETTINGS ?= /data/eda_tools/AMD/2025.1/Vivado/settings64.sh
VIVADO_CMD       = source $(VIVADO_SETTINGS) && vivado

PROJECT    ?= pncel_alveo
BUILD_DIR   = build/$(PROJECT)

DFX        ?= 1
export DFX

# -------------------------------------------------------------------------
# Targets
#
#   make project                — Create the original pncel_alveo Vivado
#                                 project (Aurora-based design).
#   make mini_dice_alveo        — Create the mini_dice_alveo project
#                                 (chip stack on BRAM, no Aurora).  Sources
#                                 + IPs come from script/mini_dice_alveo_build.tcl.
#
#   Both project targets respect:
#     DFX=1 (default) → partial-reconfig flow with a dynamic region
#     DFX=0           → flat build (everything in one fileset)
#
#   make gui [PROJECT=name]     — Open the named project in the Vivado GUI.
#                                 Default PROJECT=pncel_alveo; use
#                                 `make gui PROJECT=mini_dice_alveo` for
#                                 the mini_dice project.
#
#   make synth [PROJECT=name]   — Run synth_1 on the named project.
#   make bit   [PROJECT=name]   — Run impl_1 through write_bitstream.
#                                 Bitstream lands in
#                                 build/<project>/<project>.runs/impl_1/.
#
#   make run_kernel [TEST_ARGS=…] — Run the host-side Python kernel runner
#                                   against a live FPGA (mini_dice_alveo
#                                   bitstream must already be loaded and
#                                   xdma.ko bound).  See host/README.md.
#                                   Example: TEST_ARGS="--test gemm --verbose"
#   make run_kernel_mock          — Same script in mock mode (no FPGA).
#
#   make host_test                — Run all host/ unit tests (no FPGA).
#
#   make clean   — Wipe the build directory.
# -------------------------------------------------------------------------
.PHONY: project mini_dice_alveo gui synth bit mcs run_kernel run_kernel_mock smoketest smoketest_mock host_test clean

project:
	$(VIVADO_CMD) -mode batch -source script/pncel_build.tcl

mini_dice_alveo:
	$(VIVADO_CMD) -mode batch -source script/mini_dice_alveo_build.tcl

gui:
	$(VIVADO_CMD) $(BUILD_DIR)/$(PROJECT).xpr

synth:
	@tmp=$$(mktemp /tmp/vivado_synth_XXXX.tcl); \
	    echo "open_project $(BUILD_DIR)/$(PROJECT).xpr" > $$tmp; \
	    echo "launch_runs synth_1 -jobs 8"             >> $$tmp; \
	    echo "wait_on_run synth_1"                     >> $$tmp; \
	    echo "if {[get_property STATUS [get_runs synth_1]] eq {synth_design Complete!}} { puts {SYNTH OK} } else { puts {SYNTH FAIL}; exit 1 }" >> $$tmp; \
	    $(VIVADO_CMD) -mode batch -source $$tmp; rc=$$?; rm -f $$tmp; exit $$rc

bit:
	@tmp=$$(mktemp /tmp/vivado_bit_XXXX.tcl); \
	    echo "open_project $(BUILD_DIR)/$(PROJECT).xpr"                          > $$tmp; \
	    echo "launch_runs impl_1 -to_step write_bitstream -jobs 8"              >> $$tmp; \
	    echo "wait_on_run impl_1"                                                >> $$tmp; \
	    echo "if {[get_property STATUS [get_runs impl_1]] eq {write_bitstream Complete!}} { puts {BIT OK} } else { puts {BIT FAIL}; exit 1 }" >> $$tmp; \
	    $(VIVADO_CMD) -mode batch -source $$tmp; rc=$$?; rm -f $$tmp; exit $$rc

# Package the impl_1 .bit into a flash-ready .mcs for the Alveo U50's
# onboard MT25QU01G QSPI.  U50 defaults: SPIx4, 128 MByte, offset
# 0x01002000 (user partition; 0x0 is the write-protected factory gold).
# Override via env vars:
#     make mcs OFFSET=0x0           # only if gold-region write-protect is off
#     make mcs BIT=/path MCS=/path  # arbitrary paths
# Use `mt25qu01g-spi-x1_x2_x4` as the cfgmem part in the hw_manager.
BIT ?= $(BUILD_DIR)/$(PROJECT).runs/impl_1/$(PROJECT).bit
MCS ?= $(BUILD_DIR)/$(PROJECT).runs/impl_1/$(PROJECT).mcs
mcs:
	@if [ ! -f "$(BIT)" ]; then \
	    echo "ERROR: BIT not found: $(BIT)"; \
	    echo "       Build it first with: make bit PROJECT=$(PROJECT)"; \
	    exit 1; \
	fi
	env BIT='$(abspath $(BIT))' MCS='$(abspath $(MCS))' \
	  $(if $(INTERFACE),INTERFACE='$(INTERFACE)') \
	  $(if $(SIZE),SIZE='$(SIZE)') \
	  $(if $(OFFSET),OFFSET='$(OFFSET)') \
	  bash -c 'source $(VIVADO_SETTINGS) && vivado -mode batch -source script/write_cfgmem.tcl'

run_kernel:
	cd host && python3 run_kernel.py $(TEST_ARGS)

run_kernel_mock:
	cd host && python3 run_kernel.py --mock $(TEST_ARGS)

# Quick FPGA-readiness smoke test (XDMA devices, regmap loopback, DMA
# loopback, soft-reset round-trip).  Run before run_kernel when bringing
# up a freshly-programmed board.  TEST_ARGS forwarded to the script
# (--cosim, --mock, --device-id N, -v, etc.).
smoketest:
	cd host && python3 smoketest.py $(TEST_ARGS)

smoketest_mock:
	cd host && python3 smoketest.py --mock $(TEST_ARGS)

host_test:
	cd host && python3 -m unittest discover tests

clean:
	rm -rf build/
	rm -f vivado*.{log,jou,backup.{log,jou}}
	rm -rf .Xil/
