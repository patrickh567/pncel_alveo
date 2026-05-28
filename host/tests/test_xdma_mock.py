"""
Unit tests for the mock backend of xdma.py.

Exercises XdmaUserBar / XdmaH2C / XdmaC2H with mock=True so the wrapper's
control-flow is verified on a machine without an FPGA.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from xdma import XdmaC2H, XdmaH2C, XdmaUserBar  # noqa: E402


class TestXdmaUserBarMock(unittest.TestCase):

    def test_write_then_read(self):
        with XdmaUserBar(mock=True) as bar:
            bar.write32(0x1000, 0xDEADBEEF)
            self.assertEqual(bar.read32(0x1000), 0xDEADBEEF)

    def test_unwritten_reads_zero(self):
        with XdmaUserBar(mock=True) as bar:
            self.assertEqual(bar.read32(0x2000), 0)

    def test_out_of_range_raises(self):
        with XdmaUserBar(mock=True, size=0x1000) as bar:
            with self.assertRaises(ValueError):
                bar.write32(0x1000, 0x1)


class TestXdmaH2CC2HMock(unittest.TestCase):

    def test_h2c_then_c2h_round_trip(self):
        shared = {}
        with XdmaH2C(mock=True, mock_mem=shared) as h2c, \
             XdmaC2H(mock=True, mock_mem=shared) as c2h:
            h2c.write(0x4_0000_0000, b"\xde\xad\xbe\xef")
            got = c2h.read(0x4_0000_0000, 4)
            self.assertEqual(got, b"\xde\xad\xbe\xef")

    def test_c2h_unwritten_reads_zeros(self):
        with XdmaC2H(mock=True) as c2h:
            self.assertEqual(c2h.read(0x4_0000_1000, 8), b"\x00" * 8)


if __name__ == "__main__":
    unittest.main()
