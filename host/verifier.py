"""
Actual-vs-expected write verifier.

Pure-Python port of dice_core_tb_check_done (dpi_dice_core_runtime.cpp:541-647).
Compares observed AXI writes against the runtime.json expected_writes list
by (addr, data, strb) triple, producing a sorted PASS/FAIL diff report.

On real silicon, the "actual writes" are recovered by reading back the DATA
BRAM region after each CTA finishes (mini_dice.py.bram_read_data_word), not
by snooping live AXI traffic — but the comparison logic is identical.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, List, Tuple

from test_vector import ExpectedWrite


@dataclass
class CheckResult:
    ok: bool
    matched: int
    expected_total: int
    missing: List[ExpectedWrite]
    unexpected: List[ExpectedWrite]
    report: str


def check(
    actual: Iterable[ExpectedWrite],
    expected: Iterable[ExpectedWrite],
) -> CheckResult:
    """Diff actual writes against expected_writes by (addr, data, strb).

    Mirrors dpi_dice_core_runtime.cpp:541-647:
      - For each actual write, find the first unmatched expected entry whose
        (addr, data, strb) matches exactly; mark that expected entry matched.
      - Any actual write with no match → unexpected.
      - Any expected entry still unmatched → missing.

    Returns a CheckResult with the counts, the unmatched lists, and a
    pretty-printed report (one line per address, sorted by chip_addr).
    """
    expected_list = list(expected)
    actual_list   = list(actual)

    matched_idx: List[bool] = [False] * len(expected_list)
    unexpected: List[ExpectedWrite] = []

    for a in actual_list:
        found = False
        for i, e in enumerate(expected_list):
            if matched_idx[i]:
                continue
            if e.addr == a.addr and e.data == a.data and e.strb == a.strb:
                matched_idx[i] = True
                found = True
                break
        if not found:
            unexpected.append(a)

    missing = [e for e, m in zip(expected_list, matched_idx) if not m]
    matched_count = sum(matched_idx)
    ok = (matched_count == len(expected_list)) and not unexpected

    # Pretty-printed report (mirrors the sorted-by-addr table from
    # dice_core_tb_check_done's pretty-print at lines 595-644).
    report = _format_report(actual_list, expected_list, matched_idx,
                            missing, unexpected, ok)

    return CheckResult(
        ok=ok,
        matched=matched_count,
        expected_total=len(expected_list),
        missing=missing,
        unexpected=unexpected,
        report=report,
    )


def _format_report(
    actual_list: List[ExpectedWrite],
    expected_list: List[ExpectedWrite],
    matched_idx: List[bool],
    missing: List[ExpectedWrite],
    unexpected: List[ExpectedWrite],
    ok: bool,
) -> str:
    lines: List[str] = []
    lines.append("=" * 51)
    lines.append(f"AXI write verifier — {len(actual_list)} actual / "
                 f"{len(expected_list)} expected")
    lines.append("=" * 51)
    lines.append(f"{'addr':>6} | {'expected':>12} | {'actual':>12} | {'status':>10}")
    lines.append("-" * 51)

    # Merge by addr for pretty display.
    by_addr_exp: dict = {}
    for e in expected_list:
        by_addr_exp.setdefault(e.addr, []).append(e)
    by_addr_act: dict = {}
    for a in actual_list:
        by_addr_act.setdefault(a.addr, []).append(a)
    matched_set = {id(e) for e, m in zip(expected_list, matched_idx) if m}

    all_addrs = sorted(set(by_addr_exp) | set(by_addr_act))
    for addr in all_addrs:
        exps = by_addr_exp.get(addr, [])
        acts = by_addr_act.get(addr, [])
        n = max(len(exps), len(acts))
        for i in range(n):
            e = exps[i] if i < len(exps) else None
            a = acts[i] if i < len(acts) else None
            if e is not None and a is not None and id(e) in matched_set:
                status = "OK"
                e_str = f"0x{e.data:04x}"
                a_str = f"0x{a.data:04x}"
            elif e is not None and id(e) not in matched_set:
                status = "MISSING"
                e_str = f"0x{e.data:04x}"
                a_str = "---" if a is None else f"0x{a.data:04x}"
            elif a is not None:
                status = "UNEXPECTED"
                e_str = "---"
                a_str = f"0x{a.data:04x}"
            else:
                continue
            lines.append(f"0x{addr:04x} | {e_str:>12} | {a_str:>12} | {status:>10}")

    lines.append("")
    matched_count = sum(matched_idx)
    lines.append(f"{matched_count}/{len(expected_list)} addresses match, "
                 f"{len(missing)} missing, {len(unexpected)} unexpected")
    lines.append("=" * 51)
    lines.append("[HOST] " + ("PASS" if ok else "FAIL") +
                 f": {matched_count}/{len(expected_list)} expected writes matched")
    return "\n".join(lines)
