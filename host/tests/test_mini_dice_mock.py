"""
Mock-mode tests for MiniDice.

These exercise the host control-flow (address calculations, polling
phases, BRAM round-trips) without an FPGA.
"""

from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mini_dice import MiniDice  # noqa: E402


class TestMiniDiceMock(unittest.TestCase):

    def _open(self) -> MiniDice:
        return MiniDice.from_env(mock=True)

    def test_csr_write_then_read(self):
        with self._open() as md:
            md.csr_write(MiniDice.REG_STARTPC, 0x1234)
            self.assertEqual(md.csr_read(MiniDice.REG_STARTPC), 0x1234)

    def test_bram_data_word_round_trip(self):
        with self._open() as md:
            md.bram_write_data_word(chip_addr=0x40, value=0xCAFE)
            v = md.bram_read_data_word(chip_addr=0x40)
            # Lower 16 bits should match what we wrote.
            self.assertEqual(v & 0xFFFF, 0xCAFE)

    def test_preload_data_echo(self):
        with self._open() as md:
            md.preload_data_echo(max_chip_addr=0x10)
            for x in range(0x10):
                self.assertEqual(md.bram_read_data_word(x) & 0xFFFF, x)

    def test_launch_cta_and_wait(self):
        # End-to-end mock: CSRs written, launch, wait_for_cta_done returns
        # within timeout (mock helper auto-toggles complete_sticky).
        with self._open() as md:
            md.launch_cta(start_pc=0x1000, thread_count=16,
                          csr_values=[1, 128, 256, 4, 0, 1, 2, 3])
            elapsed = md.wait_for_cta_done(timeout_s=1.0)
            self.assertLess(elapsed, 1.0)
            # STATUS should read back as "complete" (bit 0 set).
            self.assertEqual(md.csr_read(MiniDice.REG_STATUS) & 1, 1)


if __name__ == "__main__":
    unittest.main()
