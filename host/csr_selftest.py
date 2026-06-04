#!/usr/bin/env python3
"""csr_selftest.py — characterize the mini_dice_alveo chip CSR WRITE path.

Background
---------
On HW the launch CSRs (STARTPC / THREAD_COUNT / CSRX) read back 0x0000 after
being written nonzero, while CSR *reads* return live values — i.e. the AXI-Lite
CSR *write* path

    host BAR write (FIFO_BASE|offset)
      -> axil_host_switch (1S->2M address decode)
      -> axi_lite_clock_converter_chip (aclk 250 MHz -> cache_clk 100 MHz CDC)
      -> axi_lite_fifo (write FSM)
      -> OP_WRITE packet (low 16b addr = chip CSR offset, payload = value)
      -> chip axi_link_rx -> cgra_io_csr register write

drops or zeroes writes, so the chip never receives its launch config and wedges
in dispatch (STATUS busy+dispatching, kernel never runs).

This tool writes known patterns to the *read/write* CSRs (STARTPC, THREAD_COUNT,
CSRX0, CSRX7 — never CTRL, so it never pulses START/reset) and reads them back to
characterize the failure shape:

  - 0/N on every offset, every pattern  -> writes never land (hard write-path break)
  - some land, varies round-to-round    -> intermittent (CDC/race on the write channel)
  - specific bits always drop (walk1)   -> data-lane / width problem
  - one offset works, others don't      -> address-decode regression (FIFO_BASE/BAR/switch remap)

Usage
-----
  python3 csr_selftest.py                 # real HW, device 0
  python3 csr_selftest.py --device-id 1
  python3 csr_selftest.py --rounds 5      # repeat to gauge intermittency
  python3 csr_selftest.py --mock          # control-flow smoke (no FPGA)
"""
import argparse
import sys
from typing import List, Sequence, Tuple

from mini_dice import MiniDice


def _patterns() -> List[Tuple[str, int]]:
    """16-bit test patterns chosen to expose stuck/dropped bits and aliasing."""
    walk1 = [(f"walk1[{i:02d}]", 1 << i) for i in range(16)]
    walk0 = [(f"walk0[{i:02d}]", (~(1 << i)) & 0xFFFF) for i in range(16)]
    seq = [(f"seq[{i:02d}]", (i * 0x1111) & 0xFFFF) for i in range(16)]
    misc = [("aaaa", 0xAAAA), ("5555", 0x5555), ("ffff", 0xFFFF), ("0001", 0x0001)]
    return walk1 + walk0 + seq + misc


def selftest(md: MiniDice, offsets: Sequence[Tuple[str, int]], rounds: int) -> bool:
    """Write each pattern to each R/W CSR and read it back.  Returns True iff
    every write on every offset landed across all rounds."""
    all_ok = True
    pats = _patterns()
    for rnd in range(rounds):
        if rounds > 1:
            print(f"=== round {rnd} ===")
        for name, off in offsets:
            landed = 0
            diff_mask = 0  # OR of (written ^ readback) over the mismatching writes
            for pname, v in pats:
                md.csr_write(off, v)
                rb = md.csr_read(off) & 0xFFFF
                if rb == (v & 0xFFFF):
                    landed += 1
                else:
                    diff_mask |= rb ^ (v & 0xFFFF)
                    print(f"    {name:13s} off=0x{off:04x} {pname:9s} "
                          f"w=0x{v & 0xFFFF:04x} r=0x{rb:04x} DROP")
            ok = landed == len(pats)
            all_ok = all_ok and ok
            extra = "" if ok else f"  (ever-differing bits = 0x{diff_mask:04x})"
            print(f"  {name:13s} off=0x{off:04x}: {landed}/{len(pats)} landed{extra}")
    return all_ok


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Characterize the mini_dice chip CSR WRITE path "
                    "(diagnoses the 'CSRs read back 0x0000 after write' HW failure).")
    p.add_argument("--device-id", type=int, default=0,
                   help="XDMA device index (default: 0 -> /dev/xdma0_*).")
    p.add_argument("--rounds", type=int, default=1,
                   help="Repeat the full sweep N times to gauge intermittency.")
    p.add_argument("--mock", action="store_true",
                   help="Run against the in-memory mock instead of the FPGA.")
    args = p.parse_args(argv)

    md = MiniDice.from_env(device_id=args.device_id, mock=args.mock)
    try:
        offsets = [
            ("STARTPC", md.REG_STARTPC),
            ("THREAD_COUNT", md.REG_THREAD_COUNT),
            ("CSRX0", md.REG_CSRX_BASE + 0),
            ("CSRX7", md.REG_CSRX_BASE + 2 * 7),
        ]
        ok = selftest(md, offsets, args.rounds)
    finally:
        md.close()

    print("\n========== CSR WRITE SELFTEST ==========")
    if ok:
        print("  PASS — every CSR write landed (write path healthy)")
    else:
        print("  FAIL — CSR writes dropped/corrupted. Read the shape:")
        print("    0/N everywhere      -> hard write-path break")
        print("    varies by round     -> intermittent (CDC/race on the write channel)")
        print("    specific bits only  -> data-lane / width problem")
        print("    one offset only     -> address-decode regression")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
