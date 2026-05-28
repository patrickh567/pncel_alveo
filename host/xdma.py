"""
Low-level Xilinx XDMA character-device wrappers.

The xdma.ko driver exposes three classes of device per PCIe function:

    /dev/xdma{id}_user     — BAR-1 AXI-Lite window (mmap-able, ~2 MB)
    /dev/xdma{id}_h2c_{N}  — host→card DMA (write at AXI byte offset)
    /dev/xdma{id}_c2h_{N}  — card→host DMA (read at AXI byte offset)

Each class here wraps one of those.  All addresses are AXI byte addresses
on the FPGA side — the driver maps lseek/pwrite/pread offsets to device
AXI master accesses transparently.

A `mock=True` backend swaps the OS calls for an in-memory dict so the
higher layers (mini_dice.py, run_kernel.py) can be exercised end-to-end
on a machine without the FPGA installed.
"""

from __future__ import annotations

import mmap
import os
import struct
from typing import Dict, Optional


# ---------------------------------------------------------------------------
# XdmaUserBar — mmap'd AXI-Lite control window
# ---------------------------------------------------------------------------

class XdmaUserBar:
    """Memory-mapped wrapper around `/dev/xdma{id}_user` (BAR-1).

    The user BAR is a small (~2 MB) AXI-Lite window mapped into host
    address space.  Reads/writes here go to the FPGA's m_axil port,
    which in our design routes through axil_host_switch to the dynamic
    region (CSR FIFO at 0x10_0000, regmap at 0x11_0000).
    """

    DEFAULT_SIZE = 0x20_0000  # 2 MB — matches axil_host_switch coverage

    def __init__(
        self,
        path: str = "/dev/xdma0_user",
        size: int = DEFAULT_SIZE,
        mock: bool = False,
    ):
        self.path = path
        self.size = size
        self.mock = mock
        self._fd: Optional[int] = None
        self._mm: Optional[mmap.mmap] = None
        self._mock_mem: Dict[int, int] = {}

    def open(self) -> "XdmaUserBar":
        if self.mock:
            return self
        self._fd = os.open(self.path, os.O_RDWR | os.O_SYNC)
        self._mm = mmap.mmap(self._fd, self.size,
                             flags=mmap.MAP_SHARED,
                             prot=mmap.PROT_READ | mmap.PROT_WRITE)
        return self

    def close(self) -> None:
        if self._mm is not None:
            self._mm.close()
            self._mm = None
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> "XdmaUserBar":
        return self.open()

    def __exit__(self, *_exc) -> None:
        self.close()

    def read32(self, offset: int) -> int:
        if not 0 <= offset <= self.size - 4:
            raise ValueError(f"BAR offset 0x{offset:x} out of range [0,0x{self.size:x})")
        if self.mock:
            return self._mock_mem.get(offset & ~0x3, 0) & 0xFFFF_FFFF
        return struct.unpack("<I", self._mm[offset:offset + 4])[0]

    def write32(self, offset: int, value: int) -> None:
        if not 0 <= offset <= self.size - 4:
            raise ValueError(f"BAR offset 0x{offset:x} out of range [0,0x{self.size:x})")
        if self.mock:
            self._mock_mem[offset & ~0x3] = value & 0xFFFF_FFFF
            return
        self._mm[offset:offset + 4] = struct.pack("<I", value & 0xFFFF_FFFF)


# ---------------------------------------------------------------------------
# XdmaH2C / XdmaC2H — bulk DMA character devices
# ---------------------------------------------------------------------------

class XdmaH2C:
    """Host→card DMA channel.  Each write() targets an AXI byte address."""

    def __init__(self, path: str = "/dev/xdma0_h2c_0", mock: bool = False,
                 mock_mem: Optional[Dict[int, int]] = None):
        self.path = path
        self.mock = mock
        self._fd: Optional[int] = None
        # Shared with c2h for round-trip in mock mode.
        self._mock_mem: Dict[int, int] = mock_mem if mock_mem is not None else {}

    def open(self) -> "XdmaH2C":
        if self.mock:
            return self
        self._fd = os.open(self.path, os.O_WRONLY)
        return self

    def close(self) -> None:
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> "XdmaH2C":
        return self.open()

    def __exit__(self, *_exc) -> None:
        self.close()

    def write(self, addr: int, data: bytes) -> None:
        """DMA `data` to AXI byte address `addr`."""
        if self.mock:
            for i, b in enumerate(data):
                self._mock_mem[addr + i] = b
            return
        os.pwrite(self._fd, data, addr)


class XdmaC2H:
    """Card→host DMA channel.  Each read() pulls from an AXI byte address."""

    def __init__(self, path: str = "/dev/xdma0_c2h_0", mock: bool = False,
                 mock_mem: Optional[Dict[int, int]] = None):
        self.path = path
        self.mock = mock
        self._fd: Optional[int] = None
        self._mock_mem: Dict[int, int] = mock_mem if mock_mem is not None else {}

    def open(self) -> "XdmaC2H":
        if self.mock:
            return self
        self._fd = os.open(self.path, os.O_RDONLY)
        return self

    def close(self) -> None:
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None

    def __enter__(self) -> "XdmaC2H":
        return self.open()

    def __exit__(self, *_exc) -> None:
        self.close()

    def read(self, addr: int, nbytes: int) -> bytes:
        """DMA `nbytes` from AXI byte address `addr`."""
        if self.mock:
            return bytes(self._mock_mem.get(addr + i, 0) & 0xFF for i in range(nbytes))
        return os.pread(self._fd, nbytes, addr)
