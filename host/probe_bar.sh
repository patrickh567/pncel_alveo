#!/usr/bin/env bash
# =============================================================================
# probe_bar.sh — dump raw 32-bit reads from a battery of BAR offsets so
# you can see at a glance what the FPGA is responding with (and from
# where).  Bypasses host/xdma.py's hardcoded 1-MB size assumption — uses
# `dd` directly against /dev/xdma{N}_user so any "your script's
# DEFAULT_SIZE is wrong" issues are eliminated.
#
# Each row prints:
#   addr           the BAR byte offset being read
#   region         which IP/slave the addr should land in per the
#                  post-shrink axil_host_switch + sysconfig + chip-side
#                  axi_lite_switch_xbar address map
#   value          the four bytes read back (little-endian)
#   interp         best guess at what the value means
#
# Read interpretation:
#   ffffffff       PCIe completion timeout OR Linux PCI UR → 0 path is dead
#                  somewhere upstream of the live AXI fabric.
#   dec0de??       Xilinx axi_switch default-DECERR slave — request reached
#                  an xbar but no MI port matches the address.
#   01010000       BUILD_TIMESTAMP default sentinel (set_property generic
#                  in script/*build.tcl wasn't applied; bitstream is from
#                  before the BUILD_TIMESTAMP stamp was added).
#   <epoch hex>    BUILD_TIMESTAMP from a recent build (decodes as a UTC
#                  datetime — see host/read_bitstream_info.py).
#   00000000       slave responded with valid 0 (e.g. cleared regmap reg).
#   other          slave responded with real data.
#
# Usage:
#   sudo ./host/probe_bar.sh                  # /dev/xdma0_user
#   sudo ./host/probe_bar.sh -d 1             # /dev/xdma1_user
# =============================================================================
set -u
set -o pipefail

DEV_INDEX=0
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--device) DEV_INDEX="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo) — /dev/xdma0_user is root-only on most installs." >&2; exit 1; }

DEV="/dev/xdma${DEV_INDEX}_user"
[ -e "$DEV" ] || { echo "$DEV not found.  Is xdma loaded?  Try: sudo /data2/pdh4/pncel_alveo/host/reload_xdma.sh -v" >&2; exit 1; }

read32() {
    # $1 = offset in hex, prints the 4 bytes as 8 hex chars (little-endian
    # native — same as a host AXI-Lite read).
    dd if="$DEV" bs=4 count=1 skip=$(( ${1} / 4 )) status=none 2>/dev/null | \
        od -An -tx4 -N4 | tr -d ' \n'
}

probe() {
    local off=$1 region=$2
    local v=$(read32 "$off" || echo "READ_FAILED")
    local interp=""
    case "$v" in
        ffffffff)            interp="PCIe completion timeout / unmapped" ;;
        dec0de??)            interp="axi_switch default DECERR slave" ;;
        01010000)            interp="BUILD_TIMESTAMP default sentinel" ;;
        00000000)            interp="zero (valid?  or untriggered)" ;;
        deadbeef)            interp="scfg_reg default-case readback" ;;
        READ_FAILED)         interp="dd read errored — BAR too small?" ;;
        *)                   interp="real data (or epoch-stamp BUILD_TIMESTAMP)" ;;
    esac
    printf "  %-12s  %-32s  0x%s   %s\n" "$off" "$region" "$v" "$interp"
}

echo "=== BAR probe via $DEV ==="
echo "  $(printf '%-12s  %-32s  %-12s   %s' addr region value interp)"
echo "  ------------------------------------------------------------------------------------"

# Sysconfig BAR (axil_host_switch.M00, 0x00000-0x7FFFF).
probe 0x00000000 "sysconfig:CMS subsystem"
probe 0x00040000 "sysconfig:QSPI flash (if mapped)"
probe 0x00050000 "scfg:REG_BUILD_TIMESTAMP"
probe 0x00050004 "scfg:REG_SYSTEM_RST"
probe 0x00050008 "scfg:REG_SYSTEM_STATUS"
probe 0x0005001C "scfg:REG_PR_CTRL"
probe 0x00060000 "sysconfig:SYSMON"
probe 0x00070000 "sysconfig:HBICAP"

# axil_host_switch M02 — dynamic region (chip CSR FIFO + regmap).
probe 0x00080000 "dyn:chip CSR FIFO base (write-only)"
probe 0x00090000 "dyn:regmap reg #0"
probe 0x0009000C "dyn:regmap reg #3 (R/W scratch)"

# axil_host_switch M01/M03 — both tied off in pncel_static.
probe 0x000A0000 "static_reg_map (tied off → DECERR expected)"
probe 0x000B0000 "HBM APB stub (tied off → DECERR expected)"

# Outside any mapped region.
probe 0x000C0000 "unmapped within BAR (expect DEC0DE_XX)"
probe 0x000F0000 "unmapped within BAR (expect DEC0DE_XX)"

echo ""
echo "Interpretation cheatsheet:"
echo "  * If 0x00050000 returns a non-FFFFFFFF value (epoch hex or 01010000),"
echo "    the BAR + xdma m_axil + axil_host_switch + sysconfig internal xbar"
echo "    are all working — your bitstream is healthy and the BAR reads were"
echo "    failing for some other reason (stale driver / cached mmap)."
echo "  * If ALL rows return ffffffff, XDMA's AXI-Lite master isn't"
echo "    issuing transactions despite the fabric being healthy.  Use the"
echo "    u_ila_xdma_axil ILA with trigger arvalid==1, then read 0x00050000"
echo "    and see if the AR fires.  No AR = PCIe→AXI translation dead."
echo "  * If 0x00050000 returns dec0de00 but 0x00080000 returns dec0de00 too,"
echo "    the OUTER axil_host_switch is dropping the request — the inner"
echo "    sysconfig xbar isn't the culprit."
echo "  * If 0x00050000 works but 0x00090000 returns ffffffff, the dynamic"
echo "    region's decoupler is gating or its cache_clk-bridged xbar is dead."
