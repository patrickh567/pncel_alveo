"""
Unit tests for verifier.py — checks the actual-vs-expected diff logic.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test_vector import ExpectedWrite  # noqa: E402
from verifier import check  # noqa: E402


class TestCheck(unittest.TestCase):

    def test_all_match(self):
        exp = [ExpectedWrite(addr=0x100, data=0x11, strb=3),
               ExpectedWrite(addr=0x101, data=0x22, strb=3)]
        act = list(exp)
        r = check(act, exp)
        self.assertTrue(r.ok)
        self.assertEqual(r.matched, 2)
        self.assertEqual(r.missing, [])
        self.assertEqual(r.unexpected, [])

    def test_missing_one(self):
        exp = [ExpectedWrite(addr=0x100, data=0x11, strb=3),
               ExpectedWrite(addr=0x101, data=0x22, strb=3)]
        act = [ExpectedWrite(addr=0x100, data=0x11, strb=3)]
        r = check(act, exp)
        self.assertFalse(r.ok)
        self.assertEqual(r.matched, 1)
        self.assertEqual(len(r.missing), 1)
        self.assertEqual(r.missing[0].addr, 0x101)
        self.assertEqual(r.unexpected, [])

    def test_unexpected_one(self):
        exp = [ExpectedWrite(addr=0x100, data=0x11, strb=3)]
        act = [ExpectedWrite(addr=0x100, data=0x11, strb=3),
               ExpectedWrite(addr=0x999, data=0xff, strb=3)]
        r = check(act, exp)
        self.assertFalse(r.ok)
        self.assertEqual(r.matched, 1)
        self.assertEqual(r.missing, [])
        self.assertEqual(len(r.unexpected), 1)
        self.assertEqual(r.unexpected[0].addr, 0x999)

    def test_wrong_data_counts_as_both_missing_and_unexpected(self):
        # An actual write with the right addr but wrong data shouldn't match
        # the expected entry — it should land as UNEXPECTED, and the
        # expected entry should remain MISSING.
        exp = [ExpectedWrite(addr=0x100, data=0x11, strb=3)]
        act = [ExpectedWrite(addr=0x100, data=0x22, strb=3)]
        r = check(act, exp)
        self.assertFalse(r.ok)
        self.assertEqual(len(r.missing), 1)
        self.assertEqual(len(r.unexpected), 1)


if __name__ == "__main__":
    unittest.main()
