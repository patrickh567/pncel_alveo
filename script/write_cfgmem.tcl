# write_cfgmem.tcl — wrap `write_cfgmem` to package the impl_1 .bit into a
# flash-ready .mcs for the Alveo U50's onboard QSPI configuration memory.
#
# U50-specific defaults, matching AMD UG1371 (Alveo U50 User Guide,
# "MCS File Generation and Alveo Card Programming") + UG908 (Vivado
# Programming and Debugging):
#
#   - Flash device: Micron MT25QU01G (1 Gbit / 128 MByte single QSPI).
#     The U50 has ONE flash chip; SPIx8 (dual stacked) is NOT supported.
#   - Interface:    SPIx4
#   - SIZE:         128 (MByte — Vivado -size unit; matches the physical
#                   capacity so the MCS End Address lands at the last
#                   physical byte (0x07FFFFFF) and the programmer doesn't
#                   walk past the device).  AMD's own examples sometimes
#                   show `-size 1024`; that's a long-standing doc quirk
#                   (Mbit semantics in an old Vivado version).  128 is
#                   the literal correct MByte count for MT25QU01G.
#   - OFFSET:       0x01002000  (the customer-programmable region).
#                   0x00000000..0x01001FFF is the factory "gold" image
#                   region and is write-protected on stock U50s — flashing
#                   there fails by default, and disabling protection
#                   risks bricking the card.  See UG1371 for the full
#                   partition layout.
#
# Override any of these via env vars:
#
#   BIT           absolute path to the input .bit              (required)
#   MCS           absolute path to the output .mcs             (required)
#   INTERFACE     SPIx1 | SPIx2 | SPIx4 | BPIx16 | …           (default SPIx4)
#   SIZE          flash device size in MByte                   (default 128)
#   OFFSET        byte offset where the bitstream is loaded    (default 0x01002000)
#
# `FLASH_PART` is intentionally NOT a parameter here — it's not a
# write_cfgmem argument.  When you flash via the hw_manager, select
# `mt25qu01g-spi-x1_x2_x4` for the U50 in `create_hw_cfgmem`.
#
# Usage:
#   vivado -mode batch -source script/write_cfgmem.tcl
#   (preferred entry point: `make mcs`)

# NOTE: do NOT use `expr {... ? ... : "0x01002000"}` here — `expr` evaluates
# the hex literal to its integer, which Vivado then prints back as hex,
# giving the wrong address (e.g. 0x01002000 → 16785408 → printed as
# 0x16785408 and treated as hex, blowing past the flash size).  Keep the
# offset as a plain string so write_cfgmem's parser sees the `0x` prefix
# and interprets it as hex.
proc env_or_default {var default} {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        return $::env($var)
    }
    return $default
}

set bit_path [env_or_default BIT       ""]
set mcs_path [env_or_default MCS       ""]
set iface    [env_or_default INTERFACE "SPIx4"]
set size_mb  [env_or_default SIZE      128]
set offset   [env_or_default OFFSET    "0x01002000"]

if {$bit_path eq ""} {
    puts "ERROR: BIT env var is required (path to the input .bit)"
    exit 1
}
if {$mcs_path eq ""} {
    puts "ERROR: MCS env var is required (path to the output .mcs)"
    exit 1
}
if {![file exists $bit_path]} {
    puts "ERROR: input bit not found: $bit_path"
    exit 1
}

# Make sure the destination directory exists; Vivado errors if it doesn't.
file mkdir [file dirname $mcs_path]

puts "================================================================"
puts " write_cfgmem.tcl"
puts "   BIT       = $bit_path"
puts "   MCS       = $mcs_path"
puts "   INTERFACE = $iface"
puts "   SIZE      = $size_mb MByte"
puts "   OFFSET    = $offset"
puts "================================================================"

# `up` direction is the standard for SPI bitstream-up-first layout the
# Alveo bootrom expects; Vivado will 0xFF-pad addresses outside the
# loaded bit's range.
if {[catch {
    write_cfgmem -force \
        -format mcs \
        -size $size_mb \
        -interface $iface \
        -loadbit "up $offset $bit_path" \
        -file $mcs_path
} err]} {
    puts "ERROR: write_cfgmem failed: $err"
    exit 1
}

# Vivado writes the .mcs + an adjacent .prm (text descriptor).  Print both
# sizes so a `make mcs` log shows exactly what landed.
set mcs_size [expr {[file size $mcs_path] / (1024.0 * 1024.0)}]
puts [format "MCS OK: %s (%.2f MB)" $mcs_path $mcs_size]
set prm_path "[file rootname $mcs_path].prm"
if {[file exists $prm_path]} {
    puts "PRM:    $prm_path ([file size $prm_path] B)"
}
