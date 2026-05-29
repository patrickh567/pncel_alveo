# Host-side runner for `mini_dice_alveo`

Python tooling that drives the FPGA from userspace once the bitstream is
loaded and the Xilinx XDMA driver (`xdma.ko`) is bound to the card.

Mirrors the simulation flow in
`/data2/pdh4/mini_dice_alveo_sim/sim/tb_mini_dice_alveo_cta.sv`, but
talks to real silicon through `/dev/xdma0_*` instead of through VCS
hierarchical references.

## Files

| File                  | Role |
|-----------------------|------|
| `xdma.py`             | Low-level wrappers around `/dev/xdma{N}_user`, `_h2c_0`, `_c2h_0`.  In-memory `mock=True` backend lets the rest of the stack run with no FPGA. |
| `mini_dice.py`        | Chip driver — knows the BRAM partition map and the chip's CSR layout; exposes `csr_read/write`, `bram_write_meta/bs`, `launch_cta`, `wait_for_cta_done`. |
| `test_vector.py`      | Pure-Python port of the DPI verifier's `.mem` / `.json` parsers (`load_memfile_map`, `meta_read32`, `bitstream_read32`, `load_runtime_json`, `load_cta_desc`). |
| `verifier.py`         | Actual-vs-expected AXI-write diff (port of `dice_core_tb_check_done`). |
| `run_kernel.py`       | Entry point — opens XDMA, preloads BRAM, launches CTAs, reads back results, prints PASS/FAIL. |
| `tests/`              | `unittest` suites for the parsers, the verifier, and the mock backend.  No FPGA needed. |

## Prerequisites

On the FPGA host:

```bash
# Bitstream loaded (one of):
#   - via Vivado hardware manager,
#   - via JTAG (xsdb / xsdct), or
#   - via the DFX flow if the partial bit was built (DFX=1).

# XDMA kernel module loaded.
sudo modprobe xdma  # or load the OOT driver build per its README

# Confirm the three classes of device exist + are accessible.
ls -l /dev/xdma0_user /dev/xdma0_h2c_0 /dev/xdma0_c2h_0
```

User typically needs to be in the right group (often `xdma` or `video`)
or run the script with `sudo`.  No other Python packages required —
this uses only stdlib.

## Quick reference — address map

The script's address constants come from these RTL definitions:

| Constant in `mini_dice.py` | Value | Source |
|---|---|---|
| `FIFO_BASE`        | `0x0008_0000`    | `axil_host_switch.tcl` M02 SEG00 (1 MB BAR) |
| `REGMAP_BASE`      | `0x0009_0000`    | inside M02 SEG00 (axi_lite_switch_xbar M01) |
| `BRAM_DMA_BASE`    | `0x4_0000_0000`  | `mini_dice_alveo_build.tcl:286` axi_dma_switch.M02 SEG00 |
| `META_BRAM_OFF`    | `0x0000`         | mini_dice_alveo_dynamic_region.sv: mfetch is 1:1 from chip_addr to BRAM byte |
| `BS_BRAM_OFF`      | `0x4000`         | `mini_dice_alveo_dynamic_region.sv`: `localparam BS_BRAM_OFFSET = 17'h4000` |
| `DATA_BRAM_OFF`    | `0x8000`         | `mini_dice_alveo_dynamic_region.sv`: `DATA_BRAM_OFFSET_WORDS = 17'h2000` × cache×4 = 0x8000 bytes |
| `REG_CTRL`         | `0xFF00`         | `cgra_io_csr.sv`: bit0=START, bit1=cgra_reset, bit2=bsload_en |
| `REG_STARTPC`      | `0xFF02`         | `cgra_io_csr.sv` |
| `REG_STATUS`       | `0xFF04`         | `cgra_io_csr.sv`: bit0=complete_sticky |
| `REG_THREAD_COUNT` | `0xFF0C`         | `cgra_io_csr.sv` |
| `REG_CSRX0..7`     | `0xFF10..0xFF1E` | `cgra_io_csr.sv` (stride 2 bytes; 16-bit registers) |

Host accesses chip CSR offset `O` by reading/writing AXI-Lite address
`FIFO_BASE | O` (e.g. `0x0008_FF00` to pulse START).  The axi_lite_fifo
inside the dynamic region extracts the low 16 bits as the chip's CSR
offset and emits an `OP_WRITE` packet that the chip's `axi_link_rx`
delivers to `cgra_io_csr`.

## Running

### On the FPGA host

```bash
cd /data2/pdh4/pncel_alveo/host

# Run all four bundled test vectors (default sweep).
python3 run_kernel.py

# Run one vector with verbose CSR/DMA logging.
python3 run_kernel.py --test gemm --verbose

# Use a non-default vectors directory.
python3 run_kernel.py --vectors-dir /path/to/my/test_vectors

# Bump per-CTA timeout (default 5 s — plenty for gemm's ~17k cycles at 50 MHz).
python3 run_kernel.py --per-cta-timeout-s 30
```

A Makefile target wraps this — from `/data2/pdh4/pncel_alveo/`:

```bash
make run_kernel                                     # all four
make run_kernel TEST_ARGS="--test full_mul_array_test_vector --verbose"
```

### On any machine (no FPGA)

The mock backend lets you exercise everything but the hardware:

```bash
cd /data2/pdh4/pncel_alveo/host

# Unit tests for parsers, verifier, mocked XDMA, mocked chip driver.
python3 -m unittest discover tests

# End-to-end control-flow smoke against all four vectors.
python3 run_kernel.py --mock --verbose
```

The mock backend simulates the chip's `complete_sticky` clear-on-start
+ set-when-done so the polling loops in `wait_for_cta_done` exercise
both phases.  It does **not** simulate the chip's actual writes, so
the read-back diff is skipped in mock mode and every test reports PASS
as long as the host control-flow ran clean.

## What can go wrong on real hardware

The script doesn't crash on these — it prints them and continues so you
can diagnose without re-running:

| Symptom                              | Likely cause |
|--------------------------------------|--------------|
| `csr_read` blocks / times out        | Chip's `axil_read_packet_former` → chip → `axil_read_response_handler` round trip is stuck.  Try reading the regmap at `0x0009_0000` directly to confirm the BAR/AXI-Lite path itself is alive. |
| `wait_for_cta_done` times out        | Same race we saw in sim, or the chip genuinely hung.  Bump `--per-cta-timeout-s` first; then run the sim TB on the same vector to compare cycle counts. |
| `read_back_writes` shows all 0       | DMA c2h not landing in the right region.  Sanity-check by writing a known pattern via h2c then reading it back at the same DMA addr — the `--mock` mode covers this loopback for the byte arithmetic, but the real driver may need `O_SYNC` / page-alignment hints depending on the kernel version. |
| Diff says all UNEXPECTED             | Wrong scaling between chip_addr and BRAM byte.  The script uses `8X + 0x8000`; if you changed `DATA_BRAM_OFFSET_WORDS` in the RTL, update `DATA_BRAM_OFF` here. |

## Adding a new kernel

1. Generate `_meta.mem`, `_bitstream.mem`, `_cta_desc.mem`, and
   `_runtime.json` using the Mini_Dice_Backend toolchain
   (`gen_memfile.py` etc.).
2. Drop them into a subdirectory of your `--vectors-dir` (or sit them
   directly in the root with a `_test_vector_*` stem).
3. Run:
   ```bash
   python3 run_kernel.py --test my_new_kernel --verbose
   ```

For non-echo workloads (the bundled vectors all expect
`axi_read16(addr) = addr`), replace the `md.preload_data_echo(...)`
call in `run_test` with `md.bram_write_data_word(chip_addr, value)`
calls that load real operand data, and remove `preload_data_echo`
entirely.
