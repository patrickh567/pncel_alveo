#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Raw BAR probe via mmap'd /dev/xdma{N}_user.

Replacement for probe_bar.sh.  Uses mmap-based 32-bit reads so each
host-side read translates to exactly one PCIe TLP at the requested BAR
offset — no forward read-and-discard side effects (which dd does on
non-seekable fds, and which wedged the host when it hit CMS at offset 0
before reaching the intended scfg target).

Each row prints:
  addr           BAR byte offset
  region         which slave/IP the addr should land in
  value          the 4 bytes read back, hex
  interp         best guess at what the value means

Read interpretation:
  ffffffff       PCIe completion timeout OR Linux PCI Unsupported Request.
                 The path is dead somewhere upstream of any live AXI fabric.
  dec0de??       Xilinx axi_switch default-DECERR slave — request reached
                 an xbar but no MI port matched the address.
  01010000       BUILD_TIMESTAMP default sentinel (parameter default,
                 `set_property generic` in script/*build.tcl was not
                 applied on this bitstream).
  <epoch hex>    BUILD_TIMESTAMP from a recent build (decodes as a UTC
                 datetime — see host/read_bitstream_info.py).
  deadbeef       scfg_reg default-case readback for an unmapped offset.
  00000000       slave responded with valid 0.
  other          real data.

DANGER MAP — these regions can hang the host if their sub-IPs aren't
fully initialized / clocked.  AR fires on m_axil, no RVALID comes back,
PCIe completion timer fires, AER raises a fatal error, kernel hangs:

    0x00000–0x3FFFF   sysconfig:CMS subsystem
    0x40000–0x40FFF   sysconfig:QSPI flash
    0x60000–0x61FFF   sysconfig:SYSMON
    0x70000–0x70FFF   sysconfig:HBICAP

By default the script skips ALL of these.  Pass --dangerous (-x) to
include them — only do this once the safe set works and you have a way
to recover from a wedged host (BMC remote-reset, IPMI, etc.).

Usage:
    sudo python3 host/probe_bar.py                # safe set only
    sudo python3 host/probe_bar.py -d 1           # /dev/xdma1_user
    sudo python3 host/probe_bar.py --dangerous    # include CMS et al
    sudo python3 host/probe_bar.py --addr 0x90004 # one-shot read
"""

from __future__ import annotations

import argparse
import mmap
import os
import struct
import sys
from typing import Optional


# --------------------------------------------------------------------------
# BAR access — mmap so each read32() generates exactly one TLP.
# --------------------------------------------------------------------------

class BAR:
    def __init__(self, path: str, size: int = 0x10_0000):
        self.path = path
        self.size = size
        self._fd: Optional[int] = None
        self._mm: Optional[mmap.mmap] = None

    def __enter__(self) -> "BAR":
        self._fd = os.open(self.path, os.O_RDWR | os.O_SYNC)
        try:
            self._mm = mmap.mmap(
                self._fd, self.size,
                flags=mmap.MAP_SHARED,
                prot=mmap.PROT_READ | mmap.PROT_WRITE,
            )
        except (ValueError, OSError) as exc:
            os.close(self._fd)
            self._fd = None
            raise RuntimeError(
                f"mmap({self.path}, size=0x{self.size:x}) failed: {exc}.  "
                "BAR may be smaller than requested; pass --bar-size."
            ) from exc
        return self

    def __exit__(self, *_exc) -> None:
        if self._mm is not None:
            self._mm.close()
        if self._fd is not None:
            os.close(self._fd)

    def read32(self, offset: int) -> int:
        if not 0 <= offset <= self.size - 4:
            raise ValueError(
                f"offset 0x{offset:x} out of mmap range [0, 0x{self.size:x})"
            )
        return struct.unpack("<I", self._mm[offset:offset + 4])[0]


# --------------------------------------------------------------------------
# Interpretation table.
# --------------------------------------------------------------------------

def interp(v: int) -> str:
    if v == 0xFFFF_FFFF:
        return "PCIe completion timeout / Linux PCI UR (path dead)"
    if (v & 0xFFFF_FF00) == 0xDEC0_DE00:
        return "axi_switch default DECERR slave"
    if v == 0x0101_0000:
        return "BUILD_TIMESTAMP default sentinel"
    if v == 0xDEAD_BEEF:
        return "scfg_reg default-case readback"
    if v == 0x0000_0000:
        return "zero (valid response, untriggered, or cleared reg)"
    if 0x6000_0000 <= v <= 0x7FFF_FFFF:
        # Loose check for "looks like an epoch second around 2021-2038"
        return "looks like a BUILD_TIMESTAMP epoch (UTC %Y-%m-%d %H:%M:%S)"
    return "real data"


# --------------------------------------------------------------------------
# Address map.  Tuples of (offset, region_label, danger_bool).
# danger_bool=True means the read is known to potentially hang the host.
# --------------------------------------------------------------------------

PROBES = [
    # ------------------------------------------------------------------
    # Sysconfig sub-IPs (axil_host_switch.M00 → system_config →
    # internal xbar).  These need firmware/clock init before
    # responding; hitting one cold-booted hangs the AXI bus, which
    # surfaces to the host as PCIe completion timeout → AER fatal →
    # kernel panic.  Gated by --dangerous.
    # ------------------------------------------------------------------
    (0x0000_0000, "sysconfig:CMS subsystem",          True),
    (0x0004_0000, "sysconfig:QSPI flash",             True),
    (0x0006_0000, "sysconfig:SYSMON",                 True),
    (0x0007_0000, "sysconfig:HBICAP",                 True),

    # ------------------------------------------------------------------
    # scfg_reg (axil_host_switch.M00 → system_config_axi_crossbar M00).
    # Pure AXI-Lite register file with no internal CDC — always safe.
    # ------------------------------------------------------------------
    (0x0005_0000, "scfg:REG_BUILD_TIMESTAMP",         False),
    (0x0005_0004, "scfg:REG_SYSTEM_RST",              False),
    (0x0005_0008, "scfg:REG_SYSTEM_STATUS",           False),
    (0x0005_001C, "scfg:REG_PR_CTRL",                 False),

    # ------------------------------------------------------------------
    # Dynamic-region regmap (axil_host_switch.M01 →
    # axi_lite_clock_converter_chip → axi_lite_switch_xbar.M01 →
    # axi_lite_regmap).  Pure AXI-Lite register file behind the CDC,
    # always responds (returns 0 for untouched regs, current value
    # otherwise).
    # ------------------------------------------------------------------
    (0x0009_0000, "dyn:regmap reg #0 (default 0)",    False),
    (0x0009_0008, "dyn:regmap reg #2 (SOFT_RESET)",   False),
    (0x0009_000C, "dyn:regmap reg #3 (R/W scratch)",  False),

    # ------------------------------------------------------------------
    # Chip CSR via FIFO (axil_host_switch.M01 →
    # axi_lite_clock_converter_chip → axi_lite_switch_xbar.M00 →
    # axi_lite_fifo → chip rx_cdc → chip cgra_io_csr).
    #
    # ONLY hits a CSR offset that the chip actually responds to —
    # `0x80FF04` is REG_STATUS, populated regardless of kernel state.
    # Other offsets in the FIFO aperture (0x80000-0x8FFFF) reach the
    # chip but the chip won't respond to addresses without a CSR
    # registered there → host AR hangs → PCIe completion timeout.
    #
    # The base offset `0x80000` (FIFO_BASE itself) is NOT a probe
    # target: chip CSR offset 0x0000 has no register registered, so a
    # read at 0x80000 hangs by design.  Use `0x80FF04` to exercise
    # the FIFO/chip-CSR path.
    # ------------------------------------------------------------------
    (0x0008_FF04, "dyn:chip REG_STATUS via FIFO",     False),

    # ------------------------------------------------------------------
    # Outside any mapped SEG of axil_host_switch (now 1S→2M with
    # M00=0x00000-0x7FFFF and M01=0x80000-0x9FFFF).  Reads hit the
    # IP's internal default-slave → DECERR with rdata = 0xDEC0DE??.
    # ------------------------------------------------------------------
    (0x000A_0000, "unmapped (expect DECERR from axi_switch)", False),
    (0x000C_0000, "unmapped (expect DECERR from axi_switch)", False),
    (0x000F_0000, "unmapped (expect DECERR from axi_switch)", False),
]


def cheatsheet() -> str:
    return """
Interpretation cheatsheet (axil_host_switch is 1S→2M:
  M00 0x00000-0x7FFFF → system_config (sysconfig regs + sub-IPs)
  M01 0x80000-0x9FFFF → dynamic region (FIFO + regmap)
  anything else      → IP default-slave → DECERR (rdata = 0xDEC0DE??)):

  * 0x00050000 (scfg:REG_BUILD_TIMESTAMP) — returns the epoch second of
    the bitstream's most recent `make project`.  Anything that looks
    like a 2021-2038 epoch means the BAR + xdma m_axil + host xbar M00
    + sysconfig internal xbar are all healthy.  0xFFFFFFFF means the
    M00 path is dead.

  * 0x00090000 (dyn:regmap reg #0) — returns 0 by default.  If it
    returns 0 the host xbar M01 + axi_lite_clock_converter_chip + chip-
    side switch + regmap are all healthy.  0xFFFFFFFF means the M01
    path is dead somewhere — capture ila_axil_xbar.probe5 to see if
    arvalid even fires; if it does, then the CDC or chip-side switch is
    the culprit.

  * 0x0008FF04 (dyn:chip REG_STATUS via FIFO) — returns the chip's
    current REG_STATUS value (usually 0 unless a kernel ran).  Tests
    the full host → FIFO → chip rx_cdc → chip cgra_io_csr → chip
    tx_cdc → host path.  0xFFFFFFFF means the chip-CSR packet
    round-trip is broken (the chip is in reset, the rx/tx CDCs are
    dead, or cgra_io_csr isn't responding).

  * Any DECERR (rdata = 0xDEC0DE??) — the AR reached the host xbar
    but no SEG matched, so the IP's internal default-slave answered
    cleanly.  This is the GOOD failure mode for unmapped addresses;
    it means the xbar is alive and routing.

  * PR_CTRL at 0x0005001C should read 0x00000000 (commit 0311371).
    If [1] is set (0x2), software has held the dynamic region in
    reset; M01 reads will still complete via the regmap/FIFO IPs
    (those are static-clock fabric) but the chip itself is frozen.
"""


# --------------------------------------------------------------------------
# Driver.
# --------------------------------------------------------------------------

def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("-d", "--device-id", type=int, default=0,
                   help="XDMA device index (default 0 → /dev/xdma0_user)")
    p.add_argument("-x", "--dangerous", action="store_true",
                   help="Include CMS / SYSMON / HBICAP / QSPI probes that "
                        "can hang the host if uninitialized.")
    p.add_argument("--addr", type=lambda s: int(s, 0), default=None,
                   help="One-shot read at the given hex offset; "
                        "ignore the built-in probe list.")
    p.add_argument("--bar-size", type=lambda s: int(s, 0), default=0x10_0000,
                   help="mmap size in bytes (default 0x100000 = 1 MB).")
    args = p.parse_args(argv)

    path = f"/dev/xdma{args.device_id}_user"
    if not os.path.exists(path):
        print(f"[probe_bar] ERROR: {path} not found.  "
              "Load xdma + run host/reload_xdma.sh first.", file=sys.stderr)
        return 1

    with BAR(path, size=args.bar_size) as bar:
        if args.addr is not None:
            v = bar.read32(args.addr)
            print(f"  0x{args.addr:08x}  ->  0x{v:08x}   {interp(v)}")
            return 0

        print(f"=== BAR probe via {path}  (size=0x{args.bar_size:x}) ===")
        header = f"  {'addr':<12}  {'region':<40}  {'value':<12}   interp"
        print(header)
        print("  " + "-" * (len(header) - 2))
        for off, region, dangerous in PROBES:
            if dangerous and not args.dangerous:
                continue
            label = region + ("  [DANGEROUS]" if dangerous else "")
            try:
                v = bar.read32(off)
                print(f"  0x{off:08x}  {label:<40}  0x{v:08x}   {interp(v)}")
            except Exception as exc:
                print(f"  0x{off:08x}  {label:<40}  READ_FAILED   {exc!r}")
        print(cheatsheet())
    return 0


if __name__ == "__main__":
    sys.exit(main())
