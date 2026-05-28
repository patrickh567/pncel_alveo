#!/usr/bin/env python3
"""
Entry point for running Mini_Dice kernels on the mini_dice_alveo FPGA.

Ties together xdma + mini_dice + test_vector + verifier:

  1. Open XDMA char devices (or in-memory mock).
  2. Parse a test vector's meta.mem / bitstream.mem / cta_desc.mem /
     runtime.json.
  3. DMA the meta and bitstream into the partitioned BRAM regions; seed
     the dfetch DATA region with the address-echo pattern the bundled
     vectors expect.
  4. For each CTA in the grid: program REG_STARTPC / REG_THREAD_COUNT
     / REG_CSRX0..7 with the per-CTA effective csrs, pulse CTRL.START,
     and poll REG_STATUS until complete.
  5. Read back the chip writes from the DATA BRAM region and diff
     against runtime.json's expected_writes.

Usage:
    python3 run_kernel.py                       # run all 4 bundled vectors
    python3 run_kernel.py --test gemm           # one vector
    python3 run_kernel.py --mock                # no FPGA — control-flow smoke
    python3 run_kernel.py --verbose             # print every CSR write
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence

from mini_dice import MiniDice
from test_vector import (
    CtaDescriptor,
    ExpectedWrite,
    RuntimeSpec,
    bitstream_read32,
    effective_csrs,
    load_cta_desc,
    load_memfile_map,
    load_runtime_json,
    meta_read32,
    num_ctas,
)
from verifier import check


# ---------------------------------------------------------------------------
# Test vector registry
# ---------------------------------------------------------------------------

# Bundled test vectors live alongside this script under host/test_vectors/.
# Override at runtime with --vectors-dir if you have a different generator
# output directory (e.g. a freshly regenerated Mini_Dice_Backend tree).
DEFAULT_VECTORS_DIR = Path(__file__).resolve().parent / "test_vectors"


@dataclass
class TestVectorPaths:
    stem: str            # e.g. "gemm"
    meta:      Path
    bitstream: Path
    cta_desc:  Path
    runtime:   Path

    @classmethod
    def resolve(cls, name: str, vectors_dir: Path) -> "TestVectorPaths":
        """Locate the four files for a vector.  Accepts:
             "full_mul_array_test_vector"  → files in vectors_dir/
             "gemm"                          → files in vectors_dir/gemm/gemm_*
             "nn_cuda"                       → files in vectors_dir/nn_cuda/nn_cuda_*
             "gemm/gemm"                     → same as "gemm"
        """
        # Strip a leading subdir prefix if the user used "gemm/gemm" form.
        if "/" in name:
            parent, base = name.rsplit("/", 1)
            stem_dir = vectors_dir / parent
            stem = base
        elif (vectors_dir / name / f"{name}_runtime.json").exists():
            stem_dir = vectors_dir / name
            stem = name
        else:
            stem_dir = vectors_dir
            stem = name
        return cls(
            stem=stem,
            meta=stem_dir / f"{stem}_meta.mem",
            bitstream=stem_dir / f"{stem}_bitstream.mem",
            cta_desc=stem_dir / f"{stem}_cta_desc.mem",
            runtime=stem_dir / f"{stem}_runtime.json",
        )


# Default sweep — mirrors the four-vector sim suite.
DEFAULT_TESTS = [
    "full_mul_array_test_vector",
    "simple_branching_test_vector",
    "gemm",
    "nn_cuda",
]


# ---------------------------------------------------------------------------
# Preload helpers
# ---------------------------------------------------------------------------

def preload_meta(md: MiniDice, meta_words: dict, max_byte: int = 0x4000) -> None:
    """DMA the meta image into BRAM at the META region offsets.

    Walks the populated meta-line byte range; missing bytes stay 0 in
    BRAM (matches the DPI's "return 0 for unpopulated" behavior).
    """
    if not meta_words:
        return
    # Build a contiguous buffer covering all populated lines.
    buf = bytearray()
    end_byte = (max(meta_words.keys()) + 1) * 256  # one line = 256 bytes
    end_byte = min(end_byte, max_byte)
    for byte_addr in range(0, end_byte, 4):
        word = meta_read32(meta_words, byte_addr)
        buf += word.to_bytes(4, "little")
    md.bram_write_meta(chip_addr=0, data=bytes(buf))


def preload_bs(md: MiniDice, bs_words: dict, max_byte: int = 0x4000) -> None:
    """DMA the bitstream image into BRAM at the BS region offsets."""
    if not bs_words:
        return
    buf = bytearray()
    end_byte = (max(bs_words.keys()) + 1) * 4
    end_byte = min(end_byte, max_byte)
    for byte_addr in range(0, end_byte, 4):
        word = bitstream_read32(bs_words, byte_addr)
        buf += word.to_bytes(4, "little")
    md.bram_write_bs(chip_addr=0, data=bytes(buf))


def read_back_writes(md: MiniDice, expected: Iterable[ExpectedWrite]) -> List[ExpectedWrite]:
    """Recover the chip's writes by reading the DATA BRAM region.

    On real silicon this gives us the equivalent of the sim's
    `dice_core_tb_record_axi_write` snoop, but observed after the fact.
    We only look up the expected chip_addrs (the runtime's
    expected_writes); any unexpected scribbles outside that set go
    undetected by this approach.  For full coverage, snoop on the live
    AXI bus instead (out of scope for this script).
    """
    actual: List[ExpectedWrite] = []
    for e in expected:
        v = md.bram_read_data_word(e.addr) & 0xFFFF
        actual.append(ExpectedWrite(addr=e.addr, data=v, strb=e.strb))
    return actual


# ---------------------------------------------------------------------------
# Per-vector runner
# ---------------------------------------------------------------------------

def run_test(
    name: str,
    *,
    vectors_dir: Path = DEFAULT_VECTORS_DIR,
    device_id: int = 0,
    mock: bool = False,
    cosim: bool = False,
    cosim_sock_path: str = "/tmp/mda_cosim.sock",
    cosim_timeout_s: float = 60.0,
    verbose: bool = False,
    per_cta_timeout_s: float = 5.0,
    md: Optional[MiniDice] = None,
) -> bool:
    """Run one test vector.

    If `md` is provided (cosim sweep mode), use it directly and don't
    close it on exit — the caller owns the device handle.  Otherwise
    open a fresh MiniDice for just this test and close it at the end.
    """
    paths = TestVectorPaths.resolve(name, vectors_dir)
    print(f"\n=== {paths.stem} ===")

    # Phase 1: parse test vector.
    meta = load_memfile_map(paths.meta)
    bs   = load_memfile_map(paths.bitstream)
    rt   = load_runtime_json(paths.runtime)
    desc = load_cta_desc(paths.cta_desc)
    n_ctas = num_ctas(desc)
    print(f"  start_pc=0x{desc.start_pc:04x}  thread_count={desc.thread_count}  "
          f"grid={desc.grid_size}  num_ctas={n_ctas}  "
          f"expected_writes={len(rt.expected_writes)}")

    # Phase 2: open device (if not handed in), preload, launch, verify.
    owns_md = md is None
    if md is None:
        md_kwargs = dict(device_id=device_id, mock=mock, cosim=cosim,
                         verbose=verbose)
        if cosim:
            md_kwargs["cosim_sock_path"] = cosim_sock_path
            md_kwargs["cosim_timeout_s"] = cosim_timeout_s
        md = MiniDice.from_env(**md_kwargs)
    try:
        # Reset the chip between tests so leftover CTA-scheduler / CGRA
        # state from a prior vector doesn't bleed into this one (matters
        # for cosim sweeps and real-HW back-to-back invocations).
        md.reset_chip()
        if verbose:
            print(f"  preloading meta ({len(meta)} lines), bs ({len(bs)} words), "
                  "data echo (0x400 chip addrs)")
        preload_meta(md, meta)
        preload_bs(md, bs)
        md.preload_data_echo(max_chip_addr=0x400)

        if verbose:
            # Cosim/HW sanity: read back a few words of the echo preload
            # to confirm BRAM holds what we just wrote (catches addr-
            # space-translation bugs before they manifest as diff
            # failures after the CTA runs).
            for x in [0, 1, 0x100, 0x101, 0x300]:
                got = md.bram_read_data_word(x) & 0xFFFF
                tag = "OK" if got == x else "MISMATCH"
                print(f"  [preload-sanity] chip_addr=0x{x:04x} echo expected=0x{x:04x} actual=0x{got:04x}  {tag}")

        # In mock mode we'd be writing the echo pattern into a dict that
        # already holds the chip writes from prior CTAs (since launch is
        # a no-op).  Skip the read-back in mock mode and just confirm the
        # control-flow succeeded.
        for cta_idx in range(n_ctas):
            csrs = effective_csrs(rt, cta_idx)
            if verbose:
                print(f"  CTA {cta_idx}: launching with csrs={csrs}")
            md.launch_cta(desc.start_pc, desc.thread_count, csrs)
            elapsed_s = md.wait_for_cta_done(timeout_s=per_cta_timeout_s)
            print(f"  CTA {cta_idx} complete in {elapsed_s * 1e3:.2f} ms")

        if mock:
            # Mock can't reproduce real chip outputs.  We've verified
            # all DMA byte offsets, all CSR writes, and the CTA polling
            # loops — that's the smoke this is meant to cover.
            print("  [mock] skipping read-back diff (no real chip writes)")
            return True

        actual = read_back_writes(md, rt.expected_writes)
        result = check(actual, rt.expected_writes)
        if verbose or not result.ok:
            print(result.report)
        else:
            print(f"[HOST] PASS: {result.matched}/{result.expected_total} expected "
                  "writes matched")
        return result.ok
    finally:
        if owns_md:
            md.close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Run Mini_Dice kernels on the mini_dice_alveo FPGA.")
    p.add_argument("--test", action="append", default=None,
                   help=f"Test vector name (one of: {', '.join(DEFAULT_TESTS)}). "
                        "Repeatable.  Default: run all four.")
    p.add_argument("--vectors-dir", type=Path, default=DEFAULT_VECTORS_DIR,
                   help=f"Directory containing the *_test_vector_*.mem/json files "
                        f"(default: {DEFAULT_VECTORS_DIR}).")
    p.add_argument("--device-id", type=int, default=0,
                   help="XDMA device index (default: 0 → /dev/xdma0_*).")
    p.add_argument("--mock", action="store_true",
                   help="Don't touch the FPGA — exercise the host control-flow "
                        "against an in-memory mock of the XDMA char devices.")
    p.add_argument("--cosim", action="store_true",
                   help="Drive a running VCS sim instead of /dev/xdma0_* — "
                        "talks to the SV cosim bridge over a Unix socket.")
    p.add_argument("--cosim-sock", type=str, default="/tmp/mda_cosim.sock",
                   help="Path of the cosim socket (default: /tmp/mda_cosim.sock).")
    p.add_argument("--cosim-timeout-s", type=float, default=60.0,
                   help="Cosim socket recv timeout in seconds (default: 60.0).")
    p.add_argument("--verbose", action="store_true",
                   help="Print every CSR write, every CTA launch, and the full diff "
                        "report.")
    p.add_argument("--per-cta-timeout-s", type=float, default=300.0,
                   help="Per-CTA wait_for_cta_done timeout in seconds "
                        "(default: 300.0 — cosim wall time can be slow).")
    args = p.parse_args(argv)

    if args.mock and args.cosim:
        p.error("--mock and --cosim are mutually exclusive")
    tests = args.test or DEFAULT_TESTS
    summary = []
    # Cosim mode: open one MiniDice handle and reuse it for every test.
    # The SV sim listens on a single Unix socket and exits on QUIT (which
    # MiniDice.close() sends); reconnecting per-test would require
    # restarting the whole sim, which is prohibitively slow.
    shared_md: Optional[MiniDice] = None
    if args.cosim:
        shared_md = MiniDice.from_env(
            cosim=True,
            cosim_sock_path=args.cosim_sock,
            cosim_timeout_s=args.cosim_timeout_s,
            verbose=args.verbose,
        )

    try:
        for name in tests:
            try:
                ok = run_test(
                    name,
                    vectors_dir=args.vectors_dir,
                    device_id=args.device_id,
                    mock=args.mock,
                    cosim=args.cosim,
                    cosim_sock_path=args.cosim_sock,
                    cosim_timeout_s=args.cosim_timeout_s,
                    verbose=args.verbose,
                    per_cta_timeout_s=args.per_cta_timeout_s,
                    md=shared_md,
                )
            except Exception as exc:
                print(f"[HOST] {name}: EXCEPTION {exc!r}")
                ok = False
            summary.append((name, ok))
    finally:
        if shared_md is not None:
            shared_md.close()

    print("\n========== SUMMARY ==========")
    for name, ok in summary:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    n_pass = sum(1 for _, ok in summary if ok)
    n_total = len(summary)
    print(f"  {n_pass}/{n_total} PASS\n")
    return 0 if n_pass == n_total else 1


if __name__ == "__main__":
    sys.exit(main())
