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
characterize the failure shape.  It prints a one-line FINGERPRINT at the end that
is easy to transcribe by hand.

Usage
-----
  python3 csr_selftest.py                 # real HW, device 0
  python3 csr_selftest.py --device-id 1
  python3 csr_selftest.py --rounds 5      # repeat to gauge intermittency
  python3 csr_selftest.py --mock          # control-flow smoke (no FPGA)
"""
import argparse
import sys
from typing import Dict, List, Sequence, Tuple

from mini_dice import MiniDice

# Short labels used in the type-back fingerprint, in this order.
SHORT = {"STARTPC": "SP", "THREAD_COUNT": "TC", "CSRX0": "X0", "CSRX7": "X7"}


def _patterns() -> List[Tuple[str, int]]:
    """16-bit test patterns chosen to expose stuck/dropped bits and aliasing."""
    walk1 = [(f"walk1[{i:02d}]", 1 << i) for i in range(16)]
    walk0 = [(f"walk0[{i:02d}]", (~(1 << i)) & 0xFFFF) for i in range(16)]
    seq = [(f"seq[{i:02d}]", (i * 0x1111) & 0xFFFF) for i in range(16)]
    misc = [("aaaa", 0xAAAA), ("5555", 0x5555), ("ffff", 0xFFFF), ("0001", 0x0001)]
    return walk1 + walk0 + seq + misc


def selftest(md: MiniDice, offsets: Sequence[Tuple[str, int]], rounds: int):
    """Write each pattern to each R/W CSR and read it back.

    Returns (per_off, per_round, npats):
      per_off[name]   = {landed, total, diff (OR of written^readback on misses),
                         missrb (set of distinct readback values on misses)}
      per_round[r]    = total writes that landed across all offsets in round r
      npats           = patterns per offset per round
    """
    pats = _patterns()
    per_off: Dict[str, dict] = {
        name: {"landed": 0, "total": 0, "diff": 0, "missrb": set()}
        for name, _ in offsets
    }
    per_round: List[int] = []
    for rnd in range(rounds):
        if rounds > 1:
            print(f"=== round {rnd} ===")
        round_landed = 0
        for name, off in offsets:
            landed = 0
            diff_mask = 0
            for pname, v in pats:
                md.csr_write(off, v)
                rb = md.csr_read(off) & 0xFFFF
                if rb == (v & 0xFFFF):
                    landed += 1
                else:
                    diff_mask |= rb ^ (v & 0xFFFF)
                    per_off[name]["missrb"].add(rb)
                    print(f"    {name:13s} off=0x{off:04x} {pname:9s} "
                          f"w=0x{v & 0xFFFF:04x} r=0x{rb:04x} DROP")
            d = per_off[name]
            d["landed"] += landed
            d["total"] += len(pats)
            d["diff"] |= diff_mask
            round_landed += landed
            ok = landed == len(pats)
            extra = "" if ok else f"  diff=0x{diff_mask:04x}"
            print(f"  {name:13s} off=0x{off:04x}: {landed}/{len(pats)} landed{extra}")
        per_round.append(round_landed)
    return per_off, per_round, len(pats)


def _verdict(per_off, per_round, npats, names) -> str:
    total_all = sum(per_off[n]["total"] for n in names)
    landed_all = sum(per_off[n]["landed"] for n in names)
    miss_all = set().union(*(per_off[n]["missrb"] for n in names)) if names else set()
    if landed_all == total_all:
        return "PASS-write-ok"
    if landed_all == 0:
        return "HARD-readback0" if miss_all <= {0} else "HARD-drop-garbage"
    full = [n for n in names if per_off[n]["landed"] == per_off[n]["total"]]
    zero = [n for n in names if per_off[n]["landed"] == 0]
    if full and zero:
        return "OFFSET-addr-decode"
    if len(set(per_round)) > 1:
        return "INTERMITTENT-cdc-race"
    diff_all = 0
    for n in names:
        diff_all |= per_off[n]["diff"]
    if 0 < bin(diff_all).count("1") < 16:
        return "BIT-data-lane"
    return "PARTIAL-see-lines"


def summarize(per_off, per_round, npats, names) -> bool:
    """Print a one-line, hand-transcribable fingerprint. Returns overall pass."""
    tot_each = per_off[names[0]]["total"] if names else 0
    land_str = "/".join(str(per_off[n]["landed"]) for n in names)
    order = "/".join(SHORT.get(n, n) for n in names)
    miss_all = sorted(set().union(*(per_off[n]["missrb"] for n in names))) if names else []
    if not miss_all:
        rb_str = "none"
    elif miss_all == [0]:
        rb_str = "0000"
    else:
        rb_str = ",".join(f"{v:04x}" for v in miss_all[:4]) + ("+" if len(miss_all) > 4 else "")
    diff_all = 0
    for n in names:
        diff_all |= per_off[n]["diff"]
    rounds_str = ",".join(str(x) for x in per_round)
    verdict = _verdict(per_off, per_round, npats, names)
    ok = verdict == "PASS-write-ok"

    print("\n==== TYPE THIS ONE LINE BACK ====")
    print(f"CSRFP land[{order}]={land_str} of{tot_each} "
          f"missrb={rb_str} rounds={rounds_str} diff={diff_all:04x} V={verdict}")
    print("=================================")
    return ok


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Characterize the mini_dice chip CSR WRITE path "
                    "(diagnoses 'CSRs read back 0x0000 after write').")
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
            ("CSRX7", md.REG_CSRX_BASE + 4 * 7),
        ]
        names = [n for n, _ in offsets]
        per_off, per_round, npats = selftest(md, offsets, args.rounds)
    finally:
        md.close()

    ok = summarize(per_off, per_round, npats, names)
    # Legend so the fingerprint is self-explanatory when typed back.
    print("legend: land=landed-per-offset[SP=STARTPC TC=THREAD_COUNT X0=CSRX0 X7=CSRX7];"
          " missrb=readback value(s) on a miss; rounds=landed-per-round; diff=ever-differing bits.")
    print("verdicts: HARD-readback0=all writes vanish->read 0 | HARD-drop-garbage=all drop, junk back |"
          " OFFSET-addr-decode=some offsets ok some dead | INTERMITTENT-cdc-race=varies by round |"
          " BIT-data-lane=specific bits drop | PASS-write-ok=healthy.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
