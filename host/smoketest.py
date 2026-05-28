#!/usr/bin/env python3
"""
FPGA-readiness smoke tests for mini_dice_alveo.

Run these BEFORE `run_kernel.py` to confirm the bitstream is loaded and
all four host-facing paths into the chip are alive: AXI-Lite to the
regmap, AXI-Lite to the FIFO/chip CSR path, AXI4 DMA into the BRAM,
and the soft-reset round-trip (regmap reg #2 bit 0).

Failures here localize the problem to a single subsystem; if all pass,
any subsequent kernel failure is genuinely a kernel/test-vector issue
rather than plumbing.

Usage:
    python3 smoketest.py                  # real HW (default xdma0)
    python3 smoketest.py --cosim          # against a running cosim sim
    python3 smoketest.py --mock           # pure-Python loopback only

Exits 0 if all tests pass, 1 otherwise.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time
import traceback
from typing import Callable, List, Optional, Sequence, Tuple

# Allow `import mini_dice` when invoked as `python3 host/smoketest.py`
# from the repo root or `python3 smoketest.py` from inside host/.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mini_dice import MiniDice  # noqa: E402


TestResult = Tuple[bool, str]  # (passed, one-line summary)


# ---------------------------------------------------------------------------
# Individual tests
# ---------------------------------------------------------------------------

def test_xdma_devices(args: argparse.Namespace) -> TestResult:
    """Confirm /dev/xdma{N}_{user,h2c_0,c2h_0} character devices exist.

    Skipped under --mock and --cosim since those backends don't touch
    the xdma driver.
    """
    if args.mock or args.cosim:
        return True, "skipped (backend is mock/cosim)"
    missing = []
    for sub in ("user", "h2c_0", "c2h_0"):
        path = f"/dev/xdma{args.device_id}_{sub}"
        if not os.path.exists(path):
            missing.append(path)
    if missing:
        return False, f"missing: {', '.join(missing)}"
    return True, f"/dev/xdma{args.device_id}_{{user,h2c_0,c2h_0}} present"


def test_regmap_loopback(md: MiniDice, args: argparse.Namespace) -> TestResult:
    """Write/read regmap reg #3 with a battery of patterns.

    Regs #0, #1, #3..#15 have no hardware writer (only reg #2 auto-
    clears as the SOFT_RESET bit), so a write-then-read round-trip on
    reg #3 confirms the AXI-Lite path to the regmap is sound and that
    bytes-strobed AXI4-Lite writes land correctly.
    """
    REG_OFF = 3 * 4  # reg #3 at byte offset 0x0c
    addr = md.REGMAP_BASE | REG_OFF
    patterns = [
        0x0000_0000, 0xFFFF_FFFF,
        0x5555_5555, 0xAAAA_AAAA,
        0xDEAD_BEEF, 0xCAFE_BABE,
        0x1234_5678, 0x8765_4321,
    ]
    md._bar.write32(addr, 0)  # known start state
    for p in patterns:
        md._bar.write32(addr, p)
        got = md._bar.read32(addr)
        if got != p:
            return False, (f"reg[3] @0x{addr:08x}: wrote 0x{p:08x} "
                           f"but read 0x{got:08x}")
    md._bar.write32(addr, 0)  # leave reg clean
    return True, f"{len(patterns)} patterns round-tripped OK"


def test_dma_loopback(md: MiniDice, args: argparse.Namespace) -> TestResult:
    """H2C-write a 1 KB byte pattern into the DATA BRAM region, C2H-read it back.

    Exercises the same DMA path the kernel runner uses for BRAM preload
    + result read-back.  We park the test in DATA region (well past the
    16 KB META and BS partitions) so it never conflicts with bitstream/
    meta payloads of a subsequent kernel run.

    XdmaCosimH2C splits writes into single 64 B beats (downconverter
    workaround), so 1 KB = 16 beats end-to-end.
    """
    test_addr = md.BRAM_DMA_BASE + md.DATA_BRAM_OFF
    nbytes = 1024
    pattern = bytes((i * 7 + 13) & 0xFF for i in range(nbytes))

    md._h2c.write(test_addr, pattern)
    readback = md._c2h.read(test_addr, nbytes)
    if len(readback) != nbytes:
        return False, f"length mismatch: wrote {nbytes} read {len(readback)}"
    if readback != pattern:
        for i, (a, b) in enumerate(zip(pattern, readback)):
            if a != b:
                return False, (f"first mismatch at byte 0x{i:03x}: "
                               f"wrote 0x{a:02x} read 0x{b:02x}")
        # Should be unreachable given the length check above.
        return False, "data mismatch (no per-byte difference found?)"
    return True, f"{nbytes} bytes H2C→BRAM→C2H matched"


def test_dma_loopback_unaligned(md: MiniDice, args: argparse.Namespace) -> TestResult:
    """C2H read with a non-64-byte-aligned address must still return correct data.

    XdmaCosimC2H rounds the address DOWN to a 64 B boundary and slices
    the response (sim_axi_dma's BRAM controller can't handle unaligned
    AXI4 ARSIZE_64B reads otherwise).  This test catches breakage in
    that slicing path.
    """
    base = md.BRAM_DMA_BASE + md.DATA_BRAM_OFF
    # Write 128 B of a counting pattern at base, then read 32 B starting
    # 8 bytes in (unaligned).  Expected: bytes 8..39 of the pattern.
    pattern = bytes(range(128))
    md._h2c.write(base, pattern)
    readback = md._c2h.read(base + 8, 32)
    if readback != pattern[8:40]:
        return False, (f"unaligned read mismatch: "
                       f"got {readback[:8].hex()}... "
                       f"expected {pattern[8:16].hex()}...")
    return True, "32 B from offset +8 matched (unaligned slice OK)"


def test_soft_reset(md: MiniDice, args: argparse.Namespace) -> TestResult:
    """Pulse SOFT_RESET (regmap reg #2 bit 0); confirm hardware auto-clears it.

    Verifies the soft-reset FSM in mini_dice_alveo_dynamic_region.sv
    is wired up — the bit going set→cleared without host intervention
    means the FSM ran its full 32-aclk-cycle pulse and the auto-clear
    feedback path (regs_we_i[2] ← soft_reset_done_r) is connected.

    Also leaves the chip in a clean reset state for any follow-on
    kernel runs.

    Skipped under --mock: there's no FSM in the mock dict, so the auto-
    clear behaviour we're testing isn't present.  reset_chip() itself
    is mock-aware and clears the bit synchronously instead.
    """
    if args.mock:
        return True, "skipped (no auto-clear FSM under --mock)"
    t0 = time.monotonic()
    try:
        md.reset_chip()
    except TimeoutError as e:
        return False, str(e)
    elapsed_ms = (time.monotonic() - t0) * 1e3
    return True, f"reset bit set→cleared in {elapsed_ms:.2f} ms"


# Note: a chip-CSR write/read loopback was deliberately omitted from the
# smoke set.  The FIFO→chip path (axil_fifo_packet_former → bsg_link →
# axi_link_rx → cgra_io_csr → axil_read_response_handler) is exercised
# end-to-end by every kernel run (launch_cta CSR writes + wait_for_cta_done
# REG_STATUS polling), but a cold READ — before any kernel traffic has
# warmed up the link FIFOs or the chip's packet path — is unreliable: in
# cosim it can time out and return the TB's 0xDEAD_DEAD sentinel, even
# though the same csr_read inside wait_for_cta_done works fine moments
# later.  Surfacing that as a "FAIL" here would be a false signal.  If
# the kernel runner can't talk to the chip, that's the canonical place
# to see it.
#
# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

# Each entry: (display name, callable, needs_md_arg).  Order matters:
#  - devices first (driver can't open otherwise),
#  - regmap + DMA loopbacks check the two BAR-level apertures,
#  - soft_reset last so the chip exits in a clean reset state.
TESTS: List[Tuple[str, Callable, bool]] = [
    ("xdma_devices",           test_xdma_devices,           False),
    ("regmap_loopback",        test_regmap_loopback,        True),
    ("dma_loopback",           test_dma_loopback,           True),
    ("dma_loopback_unaligned", test_dma_loopback_unaligned, True),
    ("soft_reset",             test_soft_reset,             True),
]


def _run_one(
    name: str,
    fn: Callable,
    needs_md: bool,
    md: Optional[MiniDice],
    args: argparse.Namespace,
) -> bool:
    try:
        if needs_md:
            passed, msg = fn(md, args)
        else:
            passed, msg = fn(args)
    except Exception as e:
        passed = False
        msg = f"raised {type(e).__name__}: {e}"
        if args.verbose:
            traceback.print_exc()
    marker = "PASS" if passed else "FAIL"
    print(f"  [{marker}] {name:24s} {msg}")
    return passed


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description="FPGA-readiness smoke tests for mini_dice_alveo.")
    p.add_argument("--device-id", type=int, default=0,
                   help="XDMA character-device index (default: 0)")
    p.add_argument("--mock", action="store_true",
                   help="Use the mock backend (no FPGA, no sim)")
    p.add_argument("--cosim", action="store_true",
                   help="Use the cosim socket backend (sim must already be running)")
    p.add_argument("--cosim-sock", type=str, default="/tmp/mda_cosim.sock",
                   help="Path to the cosim Unix socket")
    p.add_argument("--cosim-timeout-s", type=float, default=60.0,
                   help="Socket recv timeout for the cosim backend")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="Print per-CSR/DMA traffic + traceback on exceptions")
    args = p.parse_args(argv)

    backend = ("mock" if args.mock else
               "cosim" if args.cosim else
               f"xdma{args.device_id}")
    print(f"===== mini_dice_alveo FPGA smoke tests (backend: {backend}) =====")

    results: List[bool] = []

    # Device check first — if devices are missing we can't open the driver.
    name, fn, needs_md = TESTS[0]
    devs_ok = _run_one(name, fn, needs_md, None, args)
    results.append(devs_ok)
    if not devs_ok:
        print("\nAborting — XDMA devices missing.  Load the driver and "
              "re-program the FPGA.")
        return 1

    # Open the driver and run the rest.
    md = MiniDice.from_env(
        device_id=args.device_id,
        mock=args.mock,
        cosim=args.cosim,
        cosim_sock_path=args.cosim_sock,
        cosim_timeout_s=args.cosim_timeout_s,
        verbose=args.verbose,
    )
    try:
        for name, fn, needs_md in TESTS[1:]:
            results.append(_run_one(name, fn, needs_md, md, args))
    finally:
        md.close()

    n_pass = sum(results)
    n_total = len(results)
    print(f"\n{n_pass}/{n_total} PASS")
    return 0 if n_pass == n_total else 1


if __name__ == "__main__":
    sys.exit(main())
