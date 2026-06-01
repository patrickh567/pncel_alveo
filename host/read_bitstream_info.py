#!/usr/bin/env python3
"""
Read the loaded bitstream's identification registers via XDMA.

Use this to confirm which bitstream is actually running on the FPGA — in
particular, whether a freshly-flashed image has taken effect after
`program_hw_cfgmem` (the on-board QSPI boot only happens at cold
power-on or `boot_hw_device`; warm reboot may not retrigger it).

Reads the four scfg_reg fields exposed by system_config_register.v:

    +0x00  REG_BUILD_TIMESTAMP   compile-time 32-bit constant from the
                                 BUILD_TIMESTAMP parameter on the top
                                 module.  script/mini_dice_alveo_build.tcl
                                 + script/pncel_build.tcl stamp it with
                                 the current epoch time at project-create
                                 (see `set_property generic` near the
                                 top_module assignment), so each rebuild
                                 produces a unique value.  Default if the
                                 generic isn't applied = 0x01010000.
    +0x08  REG_SYSTEM_STATUS     bit 0 = system_rst_done sticky.
    +0x18  REG_USER_STATUS       user_rst status word.
    +0x1C  REG_PR_CTRL           bit 0 = pr_decouple, bit 1 = pr_dyn_reset.

scfg_reg lives behind the sysconfig internal crossbar.  Its host BAR
offset depends on which bitstream is loaded:

    post-shrink (commit 98cedc1+):  scfg @ host BAR 0x00050000
    pre-shrink  (initial commit):   scfg @ host BAR 0x00350000
                                    (outside the 1 MB BAR if the bitstream
                                     also shrank XDMA's axilite_master_size)

The script probes the post-shrink address first; if that returns 0xFFFFFFFF
or 0xDEC0DE_XX (axi_switch default-DECERR slave) it falls back to the
pre-shrink address via a raw /dev/xdma0_user mmap that doesn't enforce
the 1 MB size check.

Usage:
    python3 read_bitstream_info.py                 # /dev/xdma0_*
    python3 read_bitstream_info.py --device-id 1   # /dev/xdma1_*

Exit status:
    0 if both probes return a plausible BUILD_TIMESTAMP (anything that
      isn't 0xFFFFFFFF / 0xDEC0DE_XX).
    1 otherwise — indicates the bitstream isn't reachable.
"""

from __future__ import annotations

import argparse
import datetime
import mmap
import os
import struct
import sys


def _decode_timestamp(value: int) -> str:
    """Render the BUILD_TIMESTAMP register as a human-readable UTC time.

    The build TCL stamps `[clock seconds]` (Unix epoch) at project-create
    time, so every fresh build produces a unique value that decodes to
    the time it was generated.  0x01010000 is the parameter default and
    indicates the `set_property generic` block in the build TCL was
    skipped (e.g. building against an older version of the TCL)."""
    if value == 0x0101_0000:
        return "default sentinel (set_property generic was NOT applied)"
    try:
        return datetime.datetime.utcfromtimestamp(value).strftime(
            "UTC %Y-%m-%d %H:%M:%S"
        )
    except (OSError, ValueError, OverflowError):
        return "(not a valid epoch-seconds value)"

# scfg_reg base in the *new* (post-shrink) host BAR layout.  Inside
# axil_host_switch.M00 (sysconfig 0x00000-0x7FFFF), the inner
# system_config_axi_crossbar routes M00 → scfg_reg at +0x50000.
SCFG_BASE_NEW = 0x0005_0000

# scfg_reg base in the *old* (pre-shrink) host BAR layout — exists only
# in bitstreams built before commit 98cedc1.  Falls inside what was a
# 16 MB BAR; the post-shrink driver mmap's 1 MB so we'd hit the
# XdmaUserBar range check before issuing the read.
SCFG_BASE_OLD = 0x0035_0000

# Register offsets inside scfg_reg (12-bit aperture, 4 KB).  See
# src/system_config/system_config_register.v lines 89-96.
REG_BUILD_TIMESTAMP = 0x000
REG_SYSTEM_STATUS   = 0x008
REG_USER_STATUS     = 0x018
REG_PR_CTRL         = 0x01C


def _looks_like_decerr(value: int) -> bool:
    """Return True if `value` looks like a DECERR / no-completion sentinel.

    Linux PCI returns 0xFFFFFFFF on Unsupported Request / completion
    timeout.  Xilinx axi_switch's default DECERR slave returns
    0xDEC0DE_<addr[7:0]>.  Either signals "your read didn't reach a
    real slave" rather than valid register data.
    """
    if value == 0xFFFF_FFFF:
        return True
    if (value & 0xFFFF_FF00) == 0xDEC0_DE00:
        return True
    return False


def _read_via_xdma_user(path: str, addr: int) -> int:
    """Raw mmap read32 from /dev/xdma0_user, sized large enough to reach
    the pre-shrink scfg addresses (16 MB)."""
    size = 0x100_0000  # 16 MB — covers both BAR layouts
    fd = os.open(path, os.O_RDWR | os.O_SYNC)
    try:
        try:
            mm = mmap.mmap(fd, size, flags=mmap.MAP_SHARED,
                           prot=mmap.PROT_READ | mmap.PROT_WRITE)
        except (ValueError, OSError):
            # BAR is actually smaller — fall back to 1 MB.
            mm = mmap.mmap(fd, 0x10_0000, flags=mmap.MAP_SHARED,
                           prot=mmap.PROT_READ | mmap.PROT_WRITE)
            if addr >= mm.size():
                mm.close()
                return None  # caller treats as "BAR too small for this addr"
        try:
            return struct.unpack("<I", mm[addr:addr + 4])[0]
        finally:
            mm.close()
    finally:
        os.close(fd)


def _probe(label: str, path: str, base: int) -> dict | None:
    """Read the four scfg_reg fields at `base` and return them, or None
    if BUILD_TIMESTAMP comes back as a DECERR sentinel (= bitstream
    doesn't have scfg_reg at this address)."""
    print(f"\n=== {label}: scfg_reg @ host BAR 0x{base:08x} ===")
    try:
        ts = _read_via_xdma_user(path, base + REG_BUILD_TIMESTAMP)
    except Exception as exc:
        print(f"  [error] {exc!r}")
        return None
    if ts is None:
        print(f"  [skip] 0x{base + REG_BUILD_TIMESTAMP:08x} is past the BAR's "
              "actual size on this device.")
        return None
    print(f"  BUILD_TIMESTAMP  (+0x000) = 0x{ts:08x}  → {_decode_timestamp(ts)}")
    if _looks_like_decerr(ts):
        print(f"  [DECERR-like response: bitstream's scfg_reg is NOT at this address]")
        return None
    st = _read_via_xdma_user(path, base + REG_SYSTEM_STATUS)
    us = _read_via_xdma_user(path, base + REG_USER_STATUS)
    pr = _read_via_xdma_user(path, base + REG_PR_CTRL)
    print(f"  REG_SYSTEM_STATUS(+0x008) = 0x{st:08x}  (bit 0 = system_rst_done)")
    print(f"  REG_USER_STATUS  (+0x018) = 0x{us:08x}")
    print(f"  REG_PR_CTRL      (+0x01C) = 0x{pr:08x}  "
          f"(decouple={pr & 1}, dyn_reset={(pr >> 1) & 1})")
    return {
        "scfg_base":        base,
        "build_timestamp":  ts,
        "system_status":    st,
        "user_status":      us,
        "pr_ctrl":          pr,
    }


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device-id", type=int, default=0,
                   help="XDMA device index (default: 0 → /dev/xdma0_user)")
    args = p.parse_args(argv)

    path = f"/dev/xdma{args.device_id}_user"
    if not os.path.exists(path):
        print(f"ERROR: {path} not found.  Is the xdma module loaded and the "
              "FPGA enumerated on PCIe?")
        return 1

    print(f"Probing {path} for the loaded bitstream's scfg_reg fields.")
    print(f"BUILD_TIMESTAMP is stamped by script/*build.tcl with the current")
    print(f"epoch time at project-create.  This script decodes it as a UTC")
    print(f"datetime so you can tell at a glance whether the on-board image")
    print(f"matches your most-recent build.  Default (if the generic wasn't")
    print(f"applied) = 0x01010000.")

    new = _probe("post-shrink layout", path, SCFG_BASE_NEW)
    if new is not None:
        print(f"\n[VERDICT] post-shrink bitstream is loaded.")
        print(f"          BUILD_TIMESTAMP = 0x{new['build_timestamp']:08x}"
              f"  → {_decode_timestamp(new['build_timestamp'])}")
        print(f"          PR_CTRL         = 0x{new['pr_ctrl']:08x} "
              f"(expect 0x00000000 after commit 0311371)")
        return 0

    print(f"\n[note] scfg_reg is not at the post-shrink address; trying old layout...")
    old = _probe("pre-shrink layout", path, SCFG_BASE_OLD)
    if old is not None:
        print(f"\n[VERDICT] pre-shrink bitstream is loaded.")
        print(f"          BUILD_TIMESTAMP = 0x{old['build_timestamp']:08x}"
              f"  → {_decode_timestamp(old['build_timestamp'])}")
        print(f"          The freshly-built MCS is NOT on silicon yet.")
        print(f"          Re-flash via Vivado HW Manager + boot_hw_device,")
        print(f"          or cold-power-cycle the host for the QSPI to take.")
        return 1

    print(f"\n[VERDICT] scfg_reg is not reachable at either address.")
    print(f"          The bitstream either isn't loaded or PCIe isn't enumerated.")
    print(f"          Check: lspci -d 10ee: ; dmesg | tail; ls /dev/xdma*")
    return 1


if __name__ == "__main__":
    sys.exit(main())
