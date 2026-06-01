#!/usr/bin/env bash
# =============================================================================
# probe_bar.sh — DEPRECATED.  Use host/probe_bar.py instead.
#
# This shell version uses `dd` for each read.  On /dev/xdma{N}_user,
# dd's `skip=N` falls back to forward read-and-discard when its lseek
# isn't honored as a "real" seek by the xdma char device — meaning a
# `dd ... skip=$((0x50000/4))` issues reads at offsets 0, 4, 8, ...,
# 0x4FFFC, 0x50000, in sequence.  Every one of those reads becomes an
# AXI-Lite TLP.  If the first one (offset 0 → CMS subsystem) doesn't
# get an RVALID back, XDMA waits forever, the PCIe completion timer
# trips, AER raises fatal, and the host kernel hangs.
#
# This was observed in the field: even with the CMS probe commented out
# of the script, dd's read-up-to-skip pattern hit offset 0 first and
# wedged the host.
#
# host/probe_bar.py uses mmap-based reads — each `struct.unpack(mm[off:off+4])`
# generates exactly one TLP at exactly the requested BAR offset, no
# incidental reads.  Functionally identical output, no host-hang risk.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/probe_bar.py"

cat >&2 <<EOF
[probe_bar.sh] DEPRECATED — this script's dd-based reads can hang the
[probe_bar.sh] host on uninitialized AXI slaves (CMS, SYSMON, HBICAP)
[probe_bar.sh] because dd does forward read-and-discard for skip=N
[probe_bar.sh] when the xdma user-char device isn't fully seekable.
[probe_bar.sh]
[probe_bar.sh] Redirecting to host/probe_bar.py (mmap-based, safe)...
[probe_bar.sh]
EOF

if [ ! -x "$PY_SCRIPT" ]; then
    echo "[probe_bar.sh] ERROR: $PY_SCRIPT not found or not executable." >&2
    echo "[probe_bar.sh]        Run: chmod +x $PY_SCRIPT" >&2
    exit 1
fi

exec python3 "$PY_SCRIPT" "$@"
