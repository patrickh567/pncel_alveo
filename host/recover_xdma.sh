#!/usr/bin/env bash
# =============================================================================
# recover_xdma.sh — unwedge XDMA / the FPGA's AXI-Lite fabric after a stuck
# read locked it up, without reflashing the bitstream.
#
# Scenario:
#   * Some host-side read landed on an AXI slave that doesn't respond
#     (CMS subsystem at offset 0x0 is the well-known one on this design).
#   * The Xilinx axi_switch IP has no built-in watchdog; it waits
#     forever for the missing RVALID, locking the SI port.
#   * Every subsequent host read queues behind the stuck one and times
#     out as 0xFFFFFFFF.
#
# Recovery: pulse a PCIe-level reset that toggles XDMA's axi_aresetn
# low briefly, propagating downstream and clearing the xbar's stuck
# state machine.  Three options, picked automatically based on what
# the kernel says the device supports:
#
#   1. FLR  — Function-Level Reset.  Cleanest, only resets this device.
#             Requires the XDMA IP to advertise FLReset+ in PCIe Device
#             Capabilities.  Check current bitstream with:
#                 sudo lspci -vv -s $BDF | grep -i FLReset
#   2. Bus  — Secondary Bus Reset.  Pulses PERST# on the upstream
#             PCIe port; resets every device on the same switch port.
#             Verify the FPGA is alone on its port with `lspci -t` to
#             avoid disturbing NVMe / GPUs.
#   3. PM   — D3hot → D0 power-state transition.  Doesn't actually
#             reset XDMA's AXI side on most configs; included as a
#             last fallback but usually won't unwedge things.
#
# After the reset the script does a sanity probe of scfg_reg's
# BUILD_TIMESTAMP at 0x50000 (the same safe single read used by
# probe_bar.py --addr 0x00050000) to confirm recovery worked.
#
# Usage:
#   sudo ./host/recover_xdma.sh                          # auto-pick method
#   sudo ./host/recover_xdma.sh --method bus             # force SBR
#   sudo ./host/recover_xdma.sh --no-sanity              # skip post-reset probe
#   sudo ./host/recover_xdma.sh -d 0000:81:00.0          # explicit BDF
#
# Exit status: 0 if the reset completed and (when --no-sanity is not
# set) the post-reset probe returned a non-FF value.
# =============================================================================

set -u
set -o pipefail

PROG="$(basename "$0")"
EXPLICIT_BDF=""
FORCED_METHOD=""
DO_SANITY=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo "[$PROG] ERROR: $*" >&2; exit 1; }
info() { echo "[$PROG] $*"; }
warn() { echo "[$PROG] WARNING: $*" >&2; }

usage() {
    sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--device)   EXPLICIT_BDF="${2:-}"; shift 2 ;;
        -m|--method)   FORCED_METHOD="${2:-}"; shift 2 ;;
        --no-sanity)   DO_SANITY=0; shift ;;
        -h|--help)     usage 0 ;;
        *) echo "[$PROG] unknown arg: $1" >&2; usage 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo).  /sys/.../reset and reset_method need it."

# -----------------------------------------------------------------------------
# 1. Find the Xilinx device.
# -----------------------------------------------------------------------------
if [ -n "$EXPLICIT_BDF" ]; then
    BDF="$EXPLICIT_BDF"
    case "$BDF" in
        ????:*) : ;;
        *)      BDF="0000:$BDF" ;;
    esac
    [ -d "/sys/bus/pci/devices/$BDF" ] || die "no PCI device at $BDF"
else
    mapfile -t XILINX_BDFS < <(lspci -d 10ee: -D 2>/dev/null | awk '{print $1}')
    [ "${#XILINX_BDFS[@]}" -ge 1 ] || die "no Xilinx device (vendor 10ee:) found on PCIe."
    if [ "${#XILINX_BDFS[@]}" -gt 1 ]; then
        echo "[$PROG] multiple Xilinx devices found:" >&2
        printf '    %s\n' "${XILINX_BDFS[@]}" >&2
        die "pass one explicitly with -d <BDF>"
    fi
    BDF="${XILINX_BDFS[0]}"
fi
info "Xilinx device     = $BDF"

# -----------------------------------------------------------------------------
# 2. Pick a reset method.  Prefer FLR > SBR > PM.
# -----------------------------------------------------------------------------
METHOD_FILE="/sys/bus/pci/devices/$BDF/reset_method"
AVAILABLE="(unknown)"
if [ -r "$METHOD_FILE" ]; then
    AVAILABLE=$(cat "$METHOD_FILE" 2>/dev/null || echo "")
fi
info "Available methods = ${AVAILABLE:-<none / older kernel>}"

if [ -n "$FORCED_METHOD" ]; then
    METHOD="$FORCED_METHOD"
    info "Forced method     = $METHOD  (via -m flag)"
else
    if   echo "$AVAILABLE" | grep -qw flr; then  METHOD=flr
    elif echo "$AVAILABLE" | grep -qw bus; then  METHOD=bus
    elif echo "$AVAILABLE" | grep -qw pm;  then  METHOD=pm
    elif [ -z "$AVAILABLE" ] || [ "$AVAILABLE" = "(unknown)" ]; then
        METHOD=default
        info "Kernel doesn't expose reset_method; using default 'echo 1 > .../reset'"
    else
        die "no usable reset method (reset_method = '$AVAILABLE')"
    fi
    info "Chosen method     = $METHOD"
fi

case "$METHOD" in
    flr)
        info "FLR is the cleanest path — resets only this function."
        ;;
    bus)
        # Show what else lives behind the same port so the user knows
        # what's about to get reset alongside the FPGA.
        UPSTREAM=$(readlink -f /sys/bus/pci/devices/$BDF | sed 's|/[^/]*$||')
        SIBLINGS=$(ls "$UPSTREAM" 2>/dev/null | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$' | grep -v "^${BDF#0000:}\$" || true)
        warn "Secondary Bus Reset will reset EVERY device on this PCIe port."
        if [ -n "$SIBLINGS" ]; then
            warn "Sibling devices on the same port:"
            for s in $SIBLINGS; do
                desc=$(lspci -s "$s" 2>/dev/null || true)
                warn "    $desc"
            done
            warn "If any of these matter (NVMe, GPU, etc.), re-flash with FLR enabled instead."
        else
            info "No siblings detected on this PCIe port — SBR scope is just the FPGA."
        fi
        ;;
    pm)
        warn "PM D3→D0 transition often doesn't actually reset XDMA's AXI side."
        warn "If recovery fails, force --method bus."
        ;;
    default)
        ;;
    *)
        die "unknown --method '$METHOD' (expected flr|bus|pm)"
        ;;
esac

# -----------------------------------------------------------------------------
# 3. Apply the chosen method and trigger the reset.
# -----------------------------------------------------------------------------
if [ "$METHOD" != "default" ] && [ -w "$METHOD_FILE" ]; then
    echo "$METHOD" > "$METHOD_FILE" || die "failed to write reset_method=$METHOD"
fi

info "Pulsing reset on $BDF (method=$METHOD)..."
if ! echo 1 > "/sys/bus/pci/devices/$BDF/reset" 2>/tmp/reset_err.$$; then
    cat /tmp/reset_err.$$ >&2
    rm -f /tmp/reset_err.$$
    die "reset write failed.  Try a different --method or reboot."
fi
rm -f /tmp/reset_err.$$
info "Reset issued.  Waiting for the device to settle..."

# After reset the kernel needs a moment to re-enumerate / rebind.  The
# /dev/xdma0_user node may briefly disappear if the driver re-probes,
# even though the BDF stays the same.
sleep 1

# -----------------------------------------------------------------------------
# 4. Sanity check: single safe BAR read via probe_bar.py.
# -----------------------------------------------------------------------------
if [ "$DO_SANITY" = 0 ]; then
    info "--no-sanity set; skipping post-reset BAR probe."
    info "Recovery sequence complete (unverified)."
    exit 0
fi

PROBE="$SCRIPT_DIR/probe_bar.py"
if [ ! -x "$PROBE" ]; then
    warn "$PROBE not found / not executable; skipping sanity check."
    info "Recovery sequence complete (unverified)."
    exit 0
fi

# Give udev one more brief window if the driver re-bound and is
# re-creating /dev/xdma{N}_user nodes.
for _ in 1 2 3 4 5; do
    [ -e /dev/xdma0_user ] && break
    sleep 0.5
done

if [ ! -e /dev/xdma0_user ]; then
    warn "/dev/xdma0_user not present.  If you had --skip-driver earlier, modprobe xdma now."
    warn "Sanity check skipped."
    exit 0
fi

info "Sanity probe: reading scfg:BUILD_TIMESTAMP at 0x00050000..."
if python3 "$PROBE" --addr 0x00050000 2>&1; then
    info "Recovery verified — BAR is reachable again."
    exit 0
else
    warn "Sanity probe failed.  The xbar may still be wedged."
    warn "Try a more aggressive reset (--method bus) or reflash the bitstream."
    exit 1
fi
