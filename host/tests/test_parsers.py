"""
Unit tests for test_vector.py.

Cross-checks the pure-Python parsers against:
  - hand-computed extract_hex_word_lsb_first cases (DPI boundary behavior)
  - actual sim-trace observations (the bitstream/meta data values the chip
    received during the full_mul_array_test_vector sim run that PASSED).
  - the four bundled runtime.json files (csr counts, expected_writes counts,
    per-CTA override structure for multi-CTA vectors).

No FPGA needed — pure Python.  Run:
    cd /data2/pdh4/pncel_alveo/host && python3 -m unittest discover tests
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

# Allow `import test_vector` when invoked from host/.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from test_vector import (  # noqa: E402
    RuntimeSpec,
    bitstream_read32,
    effective_csrs,
    extract_hex_word_lsb_first,
    load_cta_desc,
    load_memfile_map,
    load_runtime_json,
    meta_read32,
    num_ctas,
)

VECTORS = Path(__file__).resolve().parent.parent / "test_vectors"


# ---------------------------------------------------------------------------
# extract_hex_word_lsb_first — boundary cases the DPI handles
# ---------------------------------------------------------------------------

class TestExtractHexWordLsbFirst(unittest.TestCase):

    def test_rightmost_word(self):
        # "abcdef1234567890" — rightmost 8 chars are "34567890".
        self.assertEqual(extract_hex_word_lsb_first("abcdef1234567890", 0, 8), 0x34567890)

    def test_second_word_from_right(self):
        # Next 8 chars to the left of "34567890" are "abcdef12".
        self.assertEqual(extract_hex_word_lsb_first("abcdef1234567890", 1, 8), 0xabcdef12)

    def test_past_left_edge_returns_zero(self):
        # DPI line 180-182: word_idx * hex_chars_per_word >= total_chars → 0
        self.assertEqual(extract_hex_word_lsb_first("12345678", 1, 8), 0)
        self.assertEqual(extract_hex_word_lsb_first("12345678", 2, 8), 0)

    def test_partial_word_at_left(self):
        # DPI line 184-186: begin = max(0, end - hex_chars_per_word)
        # so the leftmost slice may be shorter than 8 chars.
        self.assertEqual(extract_hex_word_lsb_first("abc12345678", 1, 8), 0xabc)

    def test_empty_string(self):
        self.assertEqual(extract_hex_word_lsb_first("", 0, 8), 0)

    def test_strips_0x_prefix(self):
        self.assertEqual(extract_hex_word_lsb_first("0xdeadbeef", 0, 8), 0xdeadbeef)

    def test_16_bit_word_size(self):
        # For meta_read16-style 4-char extraction.
        self.assertEqual(extract_hex_word_lsb_first("abcd1234", 0, 4), 0x1234)
        self.assertEqual(extract_hex_word_lsb_first("abcd1234", 1, 4), 0xabcd)


# ---------------------------------------------------------------------------
# load_memfile_map — round-trip parsing
# ---------------------------------------------------------------------------

class TestLoadMemfileMap(unittest.TestCase):

    def test_bitstream_full_mul_array(self):
        path = VECTORS / "full_mul_array_test_vector_bitstream.mem"
        m = load_memfile_map(path)
        # First populated bitstream word.
        self.assertIn(0, m)
        self.assertEqual(m[0], "08a60000")

    def test_meta_full_mul_array(self):
        path = VECTORS / "full_mul_array_test_vector_meta.mem"
        m = load_memfile_map(path)
        # First populated meta line is 0x10 (= chip mfetch addr 0x1000 / 256).
        self.assertIn(0x10, m)
        # 512 hex chars per line = 2048 bits = 256 bytes.
        self.assertEqual(len(m[0x10]), 512)

    def test_skips_comments_and_blanks(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".mem", delete=False) as fp:
            fp.write(
                "// header comment\n"
                "\n"
                "@00000005 deadbeef\n"
                "// another\n"
                "@0000000a cafebabe\n"
            )
            p = fp.name
        try:
            self.assertEqual(load_memfile_map(p), {0x5: "deadbeef", 0xa: "cafebabe"})
        finally:
            Path(p).unlink()


# ---------------------------------------------------------------------------
# meta_read32 / bitstream_read32 — vs sim-trace observations
# ---------------------------------------------------------------------------

class TestMetaAndBitstreamReads(unittest.TestCase):
    """Cross-check the Python readers against values we recorded in
    simulation when full_mul_array_test_vector PASSED end-to-end.  Each
    value below is what the chip received for the corresponding
    chip_addr → BRAM byte mapping.
    """

    @classmethod
    def setUpClass(cls):
        cls.meta = load_memfile_map(VECTORS / "full_mul_array_test_vector_meta.mem")
        cls.bs   = load_memfile_map(VECTORS / "full_mul_array_test_vector_bitstream.mem")

    def test_bitstream_first_beats(self):
        # Observed in sim: first bsfetch (addr=0x0000) burst, beats 0..7
        # match these bitstream words exactly.
        self.assertEqual(bitstream_read32(self.bs, 0),  0x08a60000)
        self.assertEqual(bitstream_read32(self.bs, 12), 0x000f2000)
        self.assertEqual(bitstream_read32(self.bs, 16), 0x00b50b7a)
        self.assertEqual(bitstream_read32(self.bs, 28), 0x000800a0)

    def test_bitstream_second_burst(self):
        # Observed in sim: bsfetch addr=0x0200 beat 0 = 0x08a60000
        # (bitstream word index 0x80, byte_addr 0x200)
        self.assertEqual(bitstream_read32(self.bs, 0x200), 0x08a60000)
        # beat 4 of that burst was 0x00b58b7a (word 0x84, byte 0x210)
        self.assertEqual(bitstream_read32(self.bs, 0x210), 0x00b58b7a)

    def test_bitstream_missing_returns_zero(self):
        # Byte addresses past the populated bitstream return 0.
        self.assertEqual(bitstream_read32(self.bs, 0x100000), 0)

    def test_meta_first_entry(self):
        # Observed in sim: first mfetch (addr=0x1000) burst, beats 0..2.
        self.assertEqual(meta_read32(self.meta, 0x1000), 0x82000000)
        self.assertEqual(meta_read32(self.meta, 0x1004), 0x00000018)
        self.assertEqual(meta_read32(self.meta, 0x1008), 0x00006000)

    def test_meta_unmapped_line_returns_zero(self):
        # Meta entries live at line addrs 0x10..0x14; byte 0 (line 0)
        # is unpopulated → 0.
        self.assertEqual(meta_read32(self.meta, 0x0), 0)
        self.assertEqual(meta_read32(self.meta, 0x500), 0)


# ---------------------------------------------------------------------------
# load_runtime_json — all 4 bundled vectors
# ---------------------------------------------------------------------------

class TestLoadRuntimeJson(unittest.TestCase):

    def test_parses_all_four(self):
        for stem, subdir, num_ctas_expected, num_writes_expected in [
            ("full_mul_array_test_vector",   "",        0, 64),
            ("simple_branching_test_vector", "",        0, 64),
            ("gemm",                          "gemm/",   4, 64),
            ("nn_cuda",                       "nn_cuda/", 4, 64),
        ]:
            with self.subTest(stem=stem):
                path = VECTORS / f"{subdir}{stem}_runtime.json"
                rt = load_runtime_json(path)
                self.assertEqual(len(rt.csr_values), 8)
                self.assertTrue(all(isinstance(v, int) for v in rt.csr_values))
                self.assertEqual(len(rt.expected_writes), num_writes_expected)
                self.assertEqual(len(rt.per_cta_csr_overrides), num_ctas_expected)
                for w in rt.expected_writes:
                    self.assertGreaterEqual(w.data, 0)
                    self.assertLessEqual(w.data, 0xFFFF)
                    self.assertIn(w.strb, (0x0, 0x1, 0x2, 0x3))

    def test_full_mul_array_csrs(self):
        rt = load_runtime_json(VECTORS / "full_mul_array_test_vector_runtime.json")
        self.assertEqual(rt.csr_values[0], 1)
        self.assertEqual(rt.csr_values[1], 128)
        self.assertEqual(rt.csr_values[2], 256)
        self.assertEqual(rt.csr_values[3], 4)

    def test_full_mul_array_first_write(self):
        rt = load_runtime_json(VECTORS / "full_mul_array_test_vector_runtime.json")
        w0 = rt.expected_writes[0]
        self.assertEqual(w0.addr, 256)
        self.assertEqual(w0.data, 128)
        self.assertEqual(w0.strb, 3)

    def test_gemm_per_cta_overrides(self):
        rt = load_runtime_json(VECTORS / "gemm" / "gemm_runtime.json")
        self.assertEqual(len(rt.per_cta_csr_overrides), 4)
        ovr0 = rt.per_cta_csr_overrides[0]
        # gemm CTA 0 overrides csrX0..2 → {16, 272, 528}
        self.assertEqual(ovr0[0], 16)
        self.assertEqual(ovr0[1], 272)
        self.assertEqual(ovr0[2], 528)


# ---------------------------------------------------------------------------
# effective_csrs — apply per-CTA overrides
# ---------------------------------------------------------------------------

class TestEffectiveCsrs(unittest.TestCase):

    def test_no_overrides_returns_kernel_wide(self):
        rt = RuntimeSpec(csr_values=[10, 20, 30, 40, 50, 60, 70, 80])
        self.assertEqual(effective_csrs(rt, 0), [10, 20, 30, 40, 50, 60, 70, 80])

    def test_partial_override_keeps_unlisted_csrs(self):
        rt = RuntimeSpec(
            csr_values=[10, 20, 30, 40, 50, 60, 70, 80],
            per_cta_csr_overrides=[{1: 999, 5: 555}],
        )
        self.assertEqual(effective_csrs(rt, 0), [10, 999, 30, 40, 50, 555, 70, 80])

    def test_cta_idx_past_overrides_returns_kernel_wide(self):
        rt = RuntimeSpec(
            csr_values=[10, 20, 30, 40, 50, 60, 70, 80],
            per_cta_csr_overrides=[{0: 1}],
        )
        self.assertEqual(effective_csrs(rt, 5), [10, 20, 30, 40, 50, 60, 70, 80])


# ---------------------------------------------------------------------------
# load_cta_desc + num_ctas
# ---------------------------------------------------------------------------

class TestLoadCtaDesc(unittest.TestCase):

    def test_parses_all_four(self):
        for stem, subdir, start_pc, tc, grid in [
            ("full_mul_array_test_vector",   "",        4096, 16, (1, 1, 1)),
            ("simple_branching_test_vector", "",        4096, 16, (1, 1, 1)),
            ("gemm",                          "gemm/",   4096, 16, (4, 1, 1)),
            ("nn_cuda",                       "nn_cuda/", 4096, 16, (4, 1, 1)),
        ]:
            with self.subTest(stem=stem):
                path = VECTORS / f"{subdir}{stem}_cta_desc.mem"
                desc = load_cta_desc(path)
                self.assertEqual(desc.start_pc,     start_pc)
                self.assertEqual(desc.thread_count, tc)
                self.assertEqual(desc.grid_size,    grid)
                self.assertEqual(num_ctas(desc),    grid[0] * grid[1] * grid[2])


if __name__ == "__main__":
    unittest.main()
