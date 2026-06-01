#!/usr/bin/env bash
# =============================================================================
# reload_xdma.sh — re-enumerate the Xilinx FPGA on PCIe and rebind the
# xdma driver.  Run after JTAG/QSPI-programming a new bitstream so the
# host picks up the new BAR sizes / device ID / register layout without
# a host reboot.
#
# What it does:
#   1. Locate the Xilinx Corp. PCIe device (vendor 10ee:).
#   2. Tell the kernel to drop it via /sys/bus/pci/devices/.../remove.
#   3. Trigger a PCIe rescan via /sys/bus/pci/rescan (re-reads BAR sizes
#      from Config Space, re-assigns memory regions).
#   4. rmmod + modprobe the xdma kernel module so /dev/xdma{N}_* point at
#      the newly-enumerated device.
#   5. Print the post-rescan Region/LnkSta lines so you can sanity-check
#      the BAR0 size at a glance.
#
# Why "host reboot" alternatives don't always work:
#   * Warm reboot — motherboard ACPI often skips PCIe re-enumeration,
#     so the host keeps its stale BAR layout AND the FPGA's QSPI boot
#     may not retrigger.
#   * Cold power cycle — works, but slow (BIOS POST, OS bring-up).
#   * This script — ~2 seconds, no boot menu.
#
# Usage:
#   sudo ./host/reload_xdma.sh                       # auto-detect device
#   sudo ./host/reload_xdma.sh -d 0000:81:00.0       # explicit BDF
#   sudo ./host/reload_xdma.sh --skip-driver          # rescan only, leave xdma loaded
#   sudo ./host/reload_xdma.sh --verbose              # show the lspci Region/LnkSta diff
#
# Exit status: 0 if a Xilinx device is present and /dev/xdma0_user exists
# after the rebind; 1 otherwise.
# =============================================================================

set -u
set -o pipefail

PROG="$(basename "$0")"
VERBOSE=0
SKIP_DRIVER=0
EXPLICIT_BDF=""
XDMA_MODULE="${XDMA_MODULE:-xdma}"

die()  { echo "[$PROG] ERROR: $*" >&2; exit 1; }
info() { echo "[$PROG] $*"; }
verb() { [ "$VERBOSE" = 1 ] && echo "[$PROG] $*"; return 0; }

usage() {
    sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--device)       EXPLICIT_BDF="${2:-}"; shift 2 ;;
        --skip-driver)     SKIP_DRIVER=1; shift ;;
        -v|--verbose)      VERBOSE=1; shift ;;
        -h|--help)         usage 0 ;;
        *)                 echo "[$PROG] unknown arg: $1" >&2; usage 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo).  /sys/bus/pci/devices/*/remove and modprobe both need it."

# -----------------------------------------------------------------------------
# 1. Find the Xilinx device.  Xilinx Corp. vendor id = 10ee.
# -----------------------------------------------------------------------------
if [ -n "$EXPLICIT_BDF" ]; then
    BDF="$EXPLICIT_BDF"
    # Normalize to the kernel's "0000:bb:dd.f" form if the user passed just "bb:dd.f".
    case "$BDF" in
        ????:*) : ;;
        *)      BDF="0000:$BDF" ;;
    esac
    [ -d "/sys/bus/pci/devices/$BDF" ] || die "no PCI device at $BDF (check 'lspci -d 10ee:')"
else
    mapfile -t XILINX_BDFS < <(lspci -d 10ee: -D 2>/dev/null | awk '{print $1}')
    [ "${#XILINX_BDFS[@]}" -ge 1 ] || die "no Xilinx device (vendor 10ee:) found on PCIe.  Is the FPGA powered and the bitstream loaded?"
    if [ "${#XILINX_BDFS[@]}" -gt 1 ]; then
        echo "[$PROG] multiple Xilinx devices found:" >&2
        printf '    %s\n' "${XILINX_BDFS[@]}" >&2
        die "pass one explicitly with -d <BDF>"
    fi
    BDF="${XILINX_BDFS[0]}"
fi
info "Xilinx device     = $BDF"

# -----------------------------------------------------------------------------
# 2. Snapshot pre-rescan BAR info if verbose, so we can show the delta.
# -----------------------------------------------------------------------------
if [ "$VERBOSE" = 1 ]; then
    echo "[$PROG] --- pre-rescan lspci (Region/LnkSta) ---"
    lspci -vv -s "$BDF" 2>/dev/null | grep -E 'Region|LnkSta' || true
fi

# -----------------------------------------------------------------------------
# 3. Drop the existing PCI device, then trigger a full bus rescan.
# -----------------------------------------------------------------------------
info "Removing $BDF from PCI bus..."
if [ -w "/sys/bus/pci/devices/$BDF/remove" ]; then
    echo 1 > "/sys/bus/pci/devices/$BDF/remove"
else
    die "/sys/bus/pci/devices/$BDF/remove not writable (kernel may not support hot remove for this device)"
fi

# Give the kernel a moment to fully tear down before re-scanning.  Without
# this, the rescan occasionally races the remove and the device shows up
# without its driver re-bound.
sleep 1

info "Triggering PCI rescan..."
echo 1 > /sys/bus/pci/rescan

# After rescan the kernel re-creates /sys/bus/pci/devices/$BDF if the
# device's Config Space is still answering at the same BDF.  Different
# bitstreams can have different vendor/device IDs, but for the Alveo U50
# XDMA build the BDF is stable across re-enumerations on the same slot.
sleep 1
[ -d "/sys/bus/pci/devices/$BDF" ] || die "$BDF did NOT re-appear after rescan.  FPGA bitstream may not be loaded, or the device crashed mid-config.  Check 'dmesg | tail'."
info "Device $BDF is back."

# -----------------------------------------------------------------------------
# 4. rmmod + modprobe xdma so /dev/xdma*_* point at the newly-enumerated dev.
# -----------------------------------------------------------------------------
if [ "$SKIP_DRIVER" = 0 ]; then
    if lsmod | awk '{print $1}' | grep -qx "$XDMA_MODULE"; then
        info "Unloading $XDMA_MODULE module..."
        rmmod "$XDMA_MODULE" || die "rmmod $XDMA_MODULE failed (in use? lsof /dev/xdma*?)"
    else
        verb "$XDMA_MODULE not currently loaded; skipping rmmod"
    fi

    info "Loading $XDMA_MODULE module..."
    modprobe "$XDMA_MODULE" || die "modprobe $XDMA_MODULE failed (module not installed? check /lib/modules/$(uname -r))"

    # Wait briefly for udev to create the character devices.  Without this,
    # callers that race to open /dev/xdma0_user may see ENOENT.
    for _ in 1 2 3 4 5; do
        [ -e /dev/xdma0_user ] && break
        sleep 0.5
    done
    [ -e /dev/xdma0_user ] || die "/dev/xdma0_user did not appear after modprobe.  Check 'dmesg | grep -i xdma' for probe errors."
    info "Character devices: $(ls -1 /dev/xdma0_* | tr '\n' ' ')"
else
    info "--skip-driver set; leaving $XDMA_MODULE alone"
fi

# -----------------------------------------------------------------------------
# 5. Sanity check + summary.
# -----------------------------------------------------------------------------
echo "[$PROG] --- post-rescan lspci (Region/LnkSta) ---"
lspci -vv -s "$BDF" 2>/dev/null | grep -E 'Region|LnkSta:' || true

info "Done.  Try 'python3 host/read_bitstream_info.py' to confirm BUILD_TIMESTAMP."
exit 0
