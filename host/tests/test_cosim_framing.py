"""
Unit tests for cosim.py — verify the wire framing without VCS.

Uses socket.socketpair() to give us both ends in-process; one end is
fed to CosimSocket (Python-driver side), the other simulates the SV
bridge by manually reading/writing the framed bytes.
"""

from __future__ import annotations

import socket
import struct
import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cosim import (  # noqa: E402
    CosimError,
    CosimSocket,
    OPC_DMA_RD,
    OPC_DMA_WR,
    OPC_QUIT,
    OPC_RD32,
    OPC_WR32,
    XdmaCosimBar,
    XdmaCosimC2H,
    XdmaCosimH2C,
)


def _recv_exact(s: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise IOError(f"peer closed at {len(buf)}/{n}")
        buf.extend(chunk)
    return bytes(buf)


def _read_request(server_sock: socket.socket):
    """Read one request frame.  Returns (opcode, addr, length, payload)."""
    hdr = _recv_exact(server_sock, 1 + 8 + 4)
    opcode, addr, length = struct.unpack("<BQI", hdr)
    if opcode in (OPC_WR32, OPC_DMA_WR):
        payload = _recv_exact(server_sock, length)
    else:
        payload = b""
    return opcode, addr, length, payload


def _send_response(server_sock: socket.socket, status: int, payload: bytes) -> None:
    server_sock.sendall(struct.pack("<BI", status, len(payload)) + payload)


# ---------------------------------------------------------------------------
# Raw CosimSocket — exercise the framing directly
# ---------------------------------------------------------------------------

class TestCosimSocketFraming(unittest.TestCase):

    def setUp(self):
        # socketpair gives us (client_end, server_end) connected back-to-back.
        client_end, self.server = socket.socketpair(socket.AF_UNIX)
        self.cs = CosimSocket(sock=client_end)

    def tearDown(self):
        self.server.close()
        self.cs.close()

    def test_wr32_frame_layout(self):
        self.cs.send_cmd(OPC_WR32, addr=0x0010_FF00, length=4,
                         payload=struct.pack("<I", 0x1234))
        opc, addr, length, payload = _read_request(self.server)
        self.assertEqual(opc, OPC_WR32)
        self.assertEqual(addr, 0x0010_FF00)
        self.assertEqual(length, 4)
        self.assertEqual(payload, struct.pack("<I", 0x1234))

    def test_rd32_no_payload(self):
        self.cs.send_cmd(OPC_RD32, addr=0x0010_FF04, length=4, payload=b"")
        opc, addr, length, payload = _read_request(self.server)
        self.assertEqual(opc, OPC_RD32)
        self.assertEqual(addr, 0x0010_FF04)
        self.assertEqual(length, 4)
        self.assertEqual(payload, b"")

    def test_dma_wr_payload_length_matches_header(self):
        data = bytes(range(64))
        self.cs.send_cmd(OPC_DMA_WR, addr=0x4_0000_8000, length=64, payload=data)
        opc, addr, length, payload = _read_request(self.server)
        self.assertEqual(opc, OPC_DMA_WR)
        self.assertEqual(length, 64)
        self.assertEqual(payload, data)

    def test_dma_rd_request_then_response(self):
        # Client sends request; we simulate the SV side responding with N bytes.
        def respond():
            opc, _addr, length, _payload = _read_request(self.server)
            assert opc == OPC_DMA_RD
            _send_response(self.server, 0, b"\xab" * length)
        t = threading.Thread(target=respond)
        t.start()
        self.cs.send_cmd(OPC_DMA_RD, addr=0x4_0000_9000, length=64, payload=b"")
        status, payload = self.cs.recv_resp()
        t.join()
        self.assertEqual(status, 0)
        self.assertEqual(payload, b"\xab" * 64)

    def test_quit_sends_correct_opcode(self):
        # quit() sends OPC_QUIT and closes.  We don't expect a response.
        # Drain the request to make sure the frame went out.
        with self.assertRaises((IOError, OSError)):
            # After client quit, the next recv on the server side should
            # see the QUIT frame then EOF.
            self.cs.quit()
            opc, _addr, _length, _payload = _read_request(self.server)
            self.assertEqual(opc, OPC_QUIT)
            # Next recv should return empty (peer closed).
            tail = self.server.recv(1)
            self.assertEqual(tail, b"")
            raise IOError("expected")

    def test_send_cmd_rejects_bad_payload_for_wr(self):
        with self.assertRaises(CosimError):
            self.cs.send_cmd(OPC_WR32, addr=0, length=4, payload=b"\x00")

    def test_send_cmd_rejects_payload_on_rd(self):
        with self.assertRaises(CosimError):
            self.cs.send_cmd(OPC_RD32, addr=0, length=4, payload=b"\x00\x00\x00\x00")


# ---------------------------------------------------------------------------
# XdmaCosim{Bar,H2C,C2H} — verify the high-level wrappers issue right cmds
# ---------------------------------------------------------------------------

class TestXdmaCosimWrappers(unittest.TestCase):

    def setUp(self):
        client_end, self.server = socket.socketpair(socket.AF_UNIX)
        self.cs = CosimSocket(sock=client_end)
        self.bar = XdmaCosimBar(self.cs)
        self.h2c = XdmaCosimH2C(self.cs)
        self.c2h = XdmaCosimC2H(self.cs)

    def tearDown(self):
        self.server.close()
        self.cs.close()

    def test_bar_write32_then_ack(self):
        # Run the wrapper in a thread; meanwhile, on the "SV" side, read
        # the request and send the ack.
        results = []
        def driver():
            try:
                self.bar.write32(0x0010_FF02, 0xDEAD)
                results.append("ok")
            except Exception as exc:
                results.append(exc)
        t = threading.Thread(target=driver)
        t.start()
        opc, addr, length, payload = _read_request(self.server)
        _send_response(self.server, 0, b"")
        t.join()
        self.assertEqual(opc, OPC_WR32)
        self.assertEqual(addr, 0x0010_FF02)
        self.assertEqual(length, 4)
        self.assertEqual(payload, struct.pack("<I", 0xDEAD))
        self.assertEqual(results, ["ok"])

    def test_bar_read32_round_trip(self):
        results = []
        def driver():
            try:
                results.append(self.bar.read32(0x0010_FF04))
            except Exception as exc:
                results.append(exc)
        t = threading.Thread(target=driver)
        t.start()
        opc, addr, _length, _payload = _read_request(self.server)
        self.assertEqual(opc, OPC_RD32)
        self.assertEqual(addr, 0x0010_FF04)
        _send_response(self.server, 0, struct.pack("<I", 0x12345678))
        t.join()
        self.assertEqual(results, [0x12345678])

    def test_h2c_write_pads_to_64_bytes(self):
        results = []
        def driver():
            try:
                # Write only 5 bytes — should be padded to 64.
                self.h2c.write(0x4_0000_0000, b"\x01\x02\x03\x04\x05")
                results.append("ok")
            except Exception as exc:
                results.append(exc)
        t = threading.Thread(target=driver)
        t.start()
        opc, addr, length, payload = _read_request(self.server)
        _send_response(self.server, 0, b"")
        t.join()
        self.assertEqual(opc, OPC_DMA_WR)
        self.assertEqual(addr, 0x4_0000_0000)
        self.assertEqual(length, 64)
        self.assertEqual(len(payload), 64)
        self.assertEqual(payload[:5], b"\x01\x02\x03\x04\x05")
        self.assertEqual(payload[5:], b"\x00" * 59)
        self.assertEqual(results, ["ok"])

    def test_c2h_read_truncates_response_to_requested(self):
        results = []
        def driver():
            try:
                results.append(self.c2h.read(0x4_0000_8000, 4))
            except Exception as exc:
                results.append(exc)
        t = threading.Thread(target=driver)
        t.start()
        opc, addr, length, _payload = _read_request(self.server)
        # Send back the full 64 B beat — wrapper should slice to 4 B.
        _send_response(self.server, 0, b"\xde\xad\xbe\xef" + b"\xff" * 60)
        t.join()
        self.assertEqual(opc, OPC_DMA_RD)
        self.assertEqual(addr, 0x4_0000_8000)   # already aligned
        self.assertEqual(length, 64)
        self.assertEqual(results, [b"\xde\xad\xbe\xef"])

    def test_c2h_read_aligns_unaligned_address(self):
        # AXI4 ARSIZE_64B requires a 64-byte-aligned addr; the wrapper
        # rounds down to the line, asks for the full line, then extracts
        # the requested slice.
        results = []
        def driver():
            try:
                results.append(self.c2h.read(0x4_0000_8008, 4))
            except Exception as exc:
                results.append(exc)
        t = threading.Thread(target=driver)
        t.start()
        opc, addr, length, _payload = _read_request(self.server)
        # Send back a 64 B beat where bytes 8..11 hold the "real" value
        # — the wrapper should extract those.
        line = bytearray(64)
        line[8:12] = b"\xca\xfe\xba\xbe"
        _send_response(self.server, 0, bytes(line))
        t.join()
        self.assertEqual(opc, OPC_DMA_RD)
        self.assertEqual(addr, 0x4_0000_8000)   # rounded down to line
        self.assertEqual(length, 64)
        self.assertEqual(results, [b"\xca\xfe\xba\xbe"])


if __name__ == "__main__":
    unittest.main()
