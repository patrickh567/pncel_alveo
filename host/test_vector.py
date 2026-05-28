"""
Mini_Dice test-vector parsers.

Pure-Python port of dpi_dice_core_runtime.cpp.  Lets a host-side script
read the same meta.mem / bitstream.mem / runtime.json / cta_desc.mem files
the simulation TB / DPI verifier consumes, so the on-FPGA flow can replay
exactly what we already proved in sim.

Ported functions (with their DPI source lines for cross-reference):
  - load_memfile_map               (dpi_dice_core_runtime.cpp:189-219)
  - extract_hex_word_lsb_first     (dpi_dice_core_runtime.cpp:170-187)
  - meta_read32 / bitstream_read32 (dpi_dice_core_runtime.cpp:369-406)
  - load_runtime_json              (dpi_dice_core_runtime.cpp:331-367)
  - load_cta_desc                  (dpi_dice_core_runtime.cpp:221-249)
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

# Matches kMetaWordBytes from dpi_dice_core_runtime.cpp:20.  Each meta line
# holds 2048 bits (256 bytes) packed right-to-left.
META_LINE_BYTES = 256


@dataclass
class ExpectedWrite:
    addr: int
    data: int
    strb: int = 0x3


@dataclass
class RuntimeSpec:
    """Parsed view of a `<test_vector>_runtime.json` file."""
    csr_values: List[int] = field(default_factory=lambda: [0] * 8)
    # per_cta_csr_overrides[cta_idx] = {csrX_index: value} for present overrides only.
    # An empty dict means "use kernel-wide csr_values for every csrX".
    per_cta_csr_overrides: List[Dict[int, int]] = field(default_factory=list)
    expected_writes: List[ExpectedWrite] = field(default_factory=list)


@dataclass
class CtaDescriptor:
    """Parsed view of a `<test_vector>_cta_desc.mem` file."""
    start_pc: int
    thread_count: int
    grid_size: tuple  # (x, y, z); num_ctas = product


# ---------------------------------------------------------------------------
# Memfile parser
# ---------------------------------------------------------------------------

_MEMFILE_LINE_RE = re.compile(r"^@([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s*$")


def load_memfile_map(path: Path | str) -> Dict[int, str]:
    """Parse a `@ADDR HEX_DATA` mem file into {addr: hex_string}.

    Comments (// or # prefix) and blank lines are skipped.  Matches the DPI's
    load_memfile_map (dpi_dice_core_runtime.cpp:189-219) — addr is parsed as
    base-16 and the hex data string is stored verbatim for later LSB-first
    extraction by meta_read32 / bitstream_read32.
    """
    out: Dict[int, str] = {}
    with open(path) as fp:
        for raw in fp:
            line = raw.strip()
            if not line or line.startswith("/") or line.startswith("#"):
                continue
            if not line.startswith("@"):
                continue
            m = _MEMFILE_LINE_RE.match(line)
            if not m:
                continue
            addr = int(m.group(1), 16)
            out[addr] = m.group(2)
    return out


# ---------------------------------------------------------------------------
# LSB-first hex word extraction
# ---------------------------------------------------------------------------

def extract_hex_word_lsb_first(
    hex_string: str,
    word_idx: int,
    hex_chars_per_word: int = 8,
) -> int:
    """Extract a word from a hex string, counted from the right (LSB).

    Mirrors dpi_dice_core_runtime.cpp:170-187.  The 0th word is the
    rightmost `hex_chars_per_word` chars; the 1st word is the next slice to
    the left; etc.  Reading past the left end returns 0 (matches DPI).

    Examples:
      extract_hex_word_lsb_first("abcdef1234567890", 0, 8) -> 0x12345678
      extract_hex_word_lsb_first("abcdef1234567890", 1, 8) -> 0xabcdef90  # wrong example
    """
    s = hex_string.strip()
    if s.lower().startswith("0x"):
        s = s[2:]
    if not s:
        return 0
    total = len(s)
    end = total - word_idx * hex_chars_per_word
    if end <= 0:
        return 0
    begin = max(0, end - hex_chars_per_word)
    return int(s[begin:end], 16)


def meta_read32(meta_words: Dict[int, str], byte_addr: int) -> int:
    """Return the 32-bit word at `byte_addr` of the meta image.

    Matches dpi_dice_core_runtime.cpp:379-387.  Out-of-range / missing lines
    return 0 (the chip's bsfetch / mfetch reads see zero-padding past the
    end of the populated image).
    """
    line_addr = byte_addr // META_LINE_BYTES
    beat_idx = (byte_addr % META_LINE_BYTES) // 4
    hex_str = meta_words.get(line_addr)
    if hex_str is None:
        return 0
    return extract_hex_word_lsb_first(hex_str, beat_idx, 8)


def bitstream_read32(bs_words: Dict[int, str], byte_addr: int) -> int:
    """Return the 32-bit word at `byte_addr` of the bitstream image.

    Matches dpi_dice_core_runtime.cpp:399-406.  bitstream.mem stores one
    32-bit word per @-addressed entry, so byte_addr → word_addr=byte_addr/4
    selects the entry directly and we extract its rightmost 32 bits.
    """
    word_addr = byte_addr // 4
    hex_str = bs_words.get(word_addr)
    if hex_str is None:
        return 0
    return extract_hex_word_lsb_first(hex_str, 0, 8)


# ---------------------------------------------------------------------------
# runtime.json parser
# ---------------------------------------------------------------------------

def load_runtime_json(path: Path | str) -> RuntimeSpec:
    """Parse `<test_vector>_runtime.json` into a RuntimeSpec.

    Uses stdlib json — these files are well-formed JSON; the DPI uses regex
    only because it lacked a JSON library in scope.

    Schema (top-level keys, observed in all 4 bundled vectors):
      "csr_values":            {"csrX0": int, ..., "csrX7": int}        (required)
      "axi": {"expected_writes": [{"addr": int, "data": int, "strb": int}]}
      "per_cta_csr_overrides": [                                         (optional, multi-CTA only)
        {"cta_id": {"x": N, "y": 0, "z": 0},
         "csr_values": {"csrXk": V, ...}}, ...
      ]
    """
    with open(path) as fp:
        rt = json.load(fp)

    spec = RuntimeSpec()

    csr_block = rt.get("csr_values", {})
    for i in range(8):
        key = f"csrX{i}"
        if key not in csr_block:
            raise ValueError(f"runtime JSON missing required {key}")
        spec.csr_values[i] = int(csr_block[key])

    writes = rt.get("axi", {}).get("expected_writes", [])
    for w in writes:
        spec.expected_writes.append(
            ExpectedWrite(
                addr=int(w["addr"]),
                data=int(w["data"]),
                strb=int(w.get("strb", 0x3)),
            )
        )

    overrides = rt.get("per_cta_csr_overrides", [])
    if overrides:
        # Build sparse list indexed by cta_id.x — multi-CTA tests in the
        # bundled vectors only vary along x, matching the DPI's
        # g_per_cta_csr[cta_x] indexing (kMaxCTAs cap at line 310).
        max_cta = max(int(o.get("cta_id", {}).get("x", 0)) for o in overrides) + 1
        spec.per_cta_csr_overrides = [dict() for _ in range(max_cta)]
        for o in overrides:
            cta_x = int(o.get("cta_id", {}).get("x", 0))
            cvals = o.get("csr_values", {})
            spec.per_cta_csr_overrides[cta_x] = {
                int(k.removeprefix("csrX")): int(v) for k, v in cvals.items()
            }

    return spec


def effective_csrs(rt: RuntimeSpec, cta_idx: int) -> List[int]:
    """Resolve the 8 csrX values for `cta_idx`, applying per-CTA overrides.

    Mirrors dice_core_tb_get_per_cta_csr (dpi_dice_core_runtime.cpp:474-488):
    if the CTA has an override entry and that entry has csrX_k present, use
    it; otherwise fall back to the kernel-wide csr_values[k].
    """
    out = list(rt.csr_values)
    if cta_idx < len(rt.per_cta_csr_overrides):
        for k, v in rt.per_cta_csr_overrides[cta_idx].items():
            out[k] = v
    return out


# ---------------------------------------------------------------------------
# cta_desc.mem parser
# ---------------------------------------------------------------------------

# The cta_desc.mem comment header carries the human-readable form, e.g.:
#   // grid_size=(1,1,1), thread_count=16, start_pc=4096
#   // cta_id=(0,0,0)
# The DPI parses the packed hex blob instead (load_cta_desc_hex), but the
# header is unambiguous and dramatically simpler for a host-side script.
_GRID_RE   = re.compile(r"grid_size\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)")
_TC_RE     = re.compile(r"thread_count\s*=\s*(\d+)")
_STARTPC_RE = re.compile(r"start_pc\s*=\s*(\d+)")


def load_cta_desc(path: Path | str) -> CtaDescriptor:
    """Extract start_pc / thread_count / grid_size from a CTA descriptor mem.

    The descriptor files all begin with a `// grid_size=(X,Y,Z),
    thread_count=N, start_pc=PC` comment that we parse directly — no need to
    decode the packed 120-bit binary blob below it.
    """
    text = Path(path).read_text()
    g = _GRID_RE.search(text)
    t = _TC_RE.search(text)
    p = _STARTPC_RE.search(text)
    if not (g and t and p):
        raise ValueError(
            f"CTA descriptor '{path}' missing one of: grid_size, thread_count, start_pc "
            "(expected in a // comment header)"
        )
    return CtaDescriptor(
        start_pc=int(p.group(1)),
        thread_count=int(t.group(1)),
        grid_size=(int(g.group(1)), int(g.group(2)), int(g.group(3))),
    )


def num_ctas(desc: CtaDescriptor) -> int:
    return desc.grid_size[0] * desc.grid_size[1] * desc.grid_size[2]
