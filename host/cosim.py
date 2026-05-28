"""
Co-simulation backend for xdma.py.

Bridges the Python host driver to a running VCS sim over a Unix-domain
socket.  The SV side (sim/cosim_bridge.cpp + tb_mini_dice_alveo_cosim.sv)
pulls commands off the socket and dispatches them to the existing
sim_axil / sim_axi_dma driver tasks, so the same Python code that talks
to /dev/xdma0_* can drive the chip's real RTL in simulation — without
ever touching an FPGA.

Wire protocol (matches sim/cosim_bridge.cpp):

  Request : [opcode:u8] [addr:u64-le] [len:u32-le] [payload:len bytes]
  Response: [status:u8] [resp_len:u32-le]          [payload:resp_len bytes]

  opcode  semantics                                  payload   resp
  ------  -----------------------------------------  --------  --------
  0x01    WR32   AXI-Lite write 32-bit              4 B       0 B
  0x02    RD32   AXI-Lite read  32-bit              0 B       4 B
  0x03    DMA_WR write `len` bytes via h2c           len B     0 B
  0x04    DMA_RD read  `len` bytes via c2h           0 B       len B
  0xFF    QUIT   terminate sim                       0 B       0 B (no resp)

`len` is the transaction byte count — request payload size for WR ops,
response payload size for RD ops.  AXI-Lite ops always carry len=4.
DMA ops require len % 64 == 0 (sim_axi_dma is 512-bit wide; the high-
level callers round their byte counts up and ignore trailing bytes).
"""

from __future__ import annotations

import os
import socket
import struct
from typing import Optional, Tuple


# Opcodes (must match cosim_bridge.cpp).
OPC_WR32   = 0x01
OPC_RD32   = 0x02
OPC_DMA_WR = 0x03
OPC_DMA_RD = 0x04
OPC_QUIT   = 0xFF

# DMA beat size — sim_axi_dma is 512-bit wide.
DMA_BEAT_BYTES = 64

DEFAULT_SOCK_PATH = "/tmp/mda_cosim.sock"
DEFAULT_TIMEOUT_S = 60.0


class CosimError(IOError):
    pass


class CosimSocket:
    """Framed binary channel to the SV cosim bridge."""

    def __init__(
        self,
        path: str = DEFAULT_SOCK_PATH,
        timeout: float = DEFAULT_TIMEOUT_S,
        sock: Optional[socket.socket] = None,
    ):
        self.path = path
        self.timeout = timeout
        # When `sock` is provided (e.g. one end of socketpair() in tests),
        # skip the connect() phase entirely.  CosimSocket takes ownership
        # either way — the caller hands the socket off and shouldn't
        # touch it after the constructor.
        self._sock = sock

    # -- connection lifecycle ---------------------------------------------

    def connect(self) -> "CosimSocket":
        """Connect to the SV side.  Idempotent if a preset socket was passed."""
        if self._sock is not None:
            return self
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.path)
        self._sock = s
        return self

    def close(self) -> None:
        if self._sock is None:
            return
        try:
            self._sock.close()
        finally:
            self._sock = None

    def __enter__(self) -> "CosimSocket":
        return self.connect()

    def __exit__(self, *_exc) -> None:
        self.close()

    # -- framed wire I/O --------------------------------------------------

    def send_cmd(self, opcode: int, addr: int, length: int,
                 payload: bytes = b"") -> None:
        """Send a request frame.

        `length` is the transaction byte count.  For WR opcodes, payload
        must be `length` bytes.  For RD opcodes, payload should be empty
        (the SV side reads `length` bytes from the device and returns
        them in the response payload).
        """
        if self._sock is None:
            raise CosimError("send_cmd before connect()")
        hdr = struct.pack("<BQI", opcode & 0xFF, addr & 0xFFFFFFFFFFFFFFFF,
                          length & 0xFFFFFFFF)
        # Validate payload length matches header.
        if opcode in (OPC_WR32, OPC_DMA_WR) and len(payload) != length:
            raise CosimError(
                f"send_cmd opcode=0x{opcode:02x} length={length} but "
                f"payload is {len(payload)} bytes"
            )
        if opcode in (OPC_RD32, OPC_DMA_RD) and payload:
            raise CosimError(
                f"send_cmd opcode=0x{opcode:02x} should have empty payload"
            )
        self._sendall(hdr + payload)

    def recv_resp(self) -> Tuple[int, bytes]:
        """Receive a response frame.  Returns (status, payload bytes)."""
        if self._sock is None:
            raise CosimError("recv_resp before connect()")
        hdr = self._recv_exact(5)
        status, resp_len = struct.unpack("<BI", hdr)
        payload = self._recv_exact(resp_len) if resp_len else b""
        return status, payload

    def quit(self) -> None:
        """Send QUIT to terminate the sim.  No response expected."""
        if self._sock is None:
            return
        try:
            self.send_cmd(OPC_QUIT, 0, 0, b"")
        except (OSError, CosimError):
            # If the sim already exited, the socket may be closed.  Best-effort.
            pass
        self.close()

    # -- low-level helpers ------------------------------------------------

    def _sendall(self, data: bytes) -> None:
        self._sock.sendall(data)

    def _recv_exact(self, n: int) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise CosimError(
                    f"peer closed mid-frame ({len(buf)}/{n} bytes received)"
                )
            buf.extend(chunk)
        return bytes(buf)


# ---------------------------------------------------------------------------
# Xdma-shaped wrappers sharing one CosimSocket
# ---------------------------------------------------------------------------

class _XdmaCosimBase:
    """Common no-op lifecycle — the shared socket is owned upstream."""

    def __init__(self, sock: CosimSocket):
        self._sock = sock

    def open(self):
        return self  # socket is opened separately by the owner

    def close(self) -> None:
        pass  # shared; the parent CosimSocket.close() handles teardown

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        pass


class XdmaCosimBar(_XdmaCosimBase):
    """Drop-in replacement for XdmaUserBar using a cosim socket."""

    def read32(self, offset: int) -> int:
        self._sock.send_cmd(OPC_RD32, offset, 4, b"")
        status, payload = self._sock.recv_resp()
        if status != 0:
            raise CosimError(f"RD32 @0x{offset:x} status=0x{status:02x}")
        if len(payload) != 4:
            raise CosimError(
                f"RD32 @0x{offset:x} unexpected resp len {len(payload)}"
            )
        return struct.unpack("<I", payload)[0]

    def write32(self, offset: int, value: int) -> None:
        payload = struct.pack("<I", value & 0xFFFFFFFF)
        self._sock.send_cmd(OPC_WR32, offset, 4, payload)
        status, _ = self._sock.recv_resp()
        if status != 0:
            raise CosimError(f"WR32 @0x{offset:x} status=0x{status:02x}")


def _pad_up(n: int, block: int) -> int:
    """Round `n` up to the next multiple of `block`."""
    return ((n + block - 1) // block) * block


class XdmaCosimH2C(_XdmaCosimBase):
    """Drop-in replacement for XdmaH2C using a cosim socket."""

    def write(self, addr: int, data: bytes) -> None:
        # Split into single-beat (64 B) bursts.  sim_axi_dma is 512 b
        # wide but the downstream axi_dma_switch M02 is 256 b — multi-
        # beat bursts get mangled by the implicit 512→256 width
        # downconversion (addresses skip by 64 B but only 32 B of data
        # land per output beat, so write N ends up at byte N*64 of an
        # alternating gap pattern).  Single-beat bursts avoid this
        # because the downconverter just splits one 512-bit beat into
        # two 256-bit beats at consecutive addresses, which works.
        for offset in range(0, len(data), DMA_BEAT_BYTES):
            chunk = data[offset:offset + DMA_BEAT_BYTES]
            if len(chunk) < DMA_BEAT_BYTES:
                chunk = chunk + b"\x00" * (DMA_BEAT_BYTES - len(chunk))
            self._sock.send_cmd(OPC_DMA_WR, addr + offset, DMA_BEAT_BYTES, chunk)
            status, _ = self._sock.recv_resp()
            if status != 0:
                raise CosimError(
                    f"DMA_WR @0x{addr + offset:x} status=0x{status:02x}"
                )


class XdmaCosimC2H(_XdmaCosimBase):
    """Drop-in replacement for XdmaC2H using a cosim socket."""

    def read(self, addr: int, nbytes: int) -> bytes:
        # sim_axi_dma is 512-bit wide and AXI4 ARSIZE_64B requires a
        # 64-byte-aligned address (otherwise the BRAM controller
        # silently rounds down → all reads in the same 64 B line
        # return the same data).  Round the request DOWN to the line
        # start, read enough beats to cover [addr, addr+nbytes), then
        # extract the unaligned slice from the response.
        line_addr     = addr & ~(DMA_BEAT_BYTES - 1)
        offset_in_line = addr - line_addr
        padded_len    = _pad_up(offset_in_line + nbytes, DMA_BEAT_BYTES)
        self._sock.send_cmd(OPC_DMA_RD, line_addr, padded_len, b"")
        status, payload = self._sock.recv_resp()
        if status != 0:
            raise CosimError(f"DMA_RD @0x{addr:x} status=0x{status:02x}")
        if len(payload) != padded_len:
            raise CosimError(
                f"DMA_RD @0x{addr:x} unexpected resp len "
                f"{len(payload)} (expected {padded_len})"
            )
        return payload[offset_in_line:offset_in_line + nbytes]
