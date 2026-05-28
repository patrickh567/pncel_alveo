// *************************************************************************
//
// MMU package — shared parameters for the TPU-style int8 systolic
// matrix-multiply unit that lives in the PR partition.
//
// Tile size is M = N = K = 32 with an int8 × int8 → int32 MAC.  Two
// MMU instances run in parallel inside the RM, each owning 6 HBM
// ports (1 A + 1 B + 4 C), for a total of 12 HBM ports — same budget
// as the earlier monolithic 64×64 array, but distributed across two
// floorplan-friendly 32×32 tiles.  Everything is parameterized so the
// array can be resized later without touching the per-block source
// files.
//
// *************************************************************************
`timescale 1ns/1ps
package mmu_pkg;

  // ---------------------------------------------------------------
  // Tile dimensions
  //   C[M][N] = A[M][K] * B[K][N]
  //
  // All three are fixed at 32 to match the 32×32 systolic array per
  // MMU instance.  Software can still program M / N / K via the
  // AXI-Lite control register file but the engine ignores any value
  // that doesn't match these (it just runs a 32×32×32 tile).
  // ---------------------------------------------------------------
  localparam int MMU_M = 32;
  localparam int MMU_N = 32;
  localparam int MMU_K = 32;

  // ---------------------------------------------------------------
  // Datapath widths
  //   IN_W  — operand width for both A and B (signed two's complement)
  //   ACC_W — accumulator width inside a column of PEs and in the C buf
  //
  // int8 × int8 needs 16 bits to hold the product, plus log2(K) more
  // for the accumulation across K = 32 lanes → 16 + 5 = 21.  We round
  // up to 32 because (a) it costs us nothing on a Xilinx DSP48 slice
  // and (b) software wants a clean int32 result element.
  // ---------------------------------------------------------------
  localparam int IN_W  = 8;
  localparam int ACC_W = 32;

  // ---------------------------------------------------------------
  // HBM port shape (matches the design-wide axi_if widths used at the
  // PR boundary — see src/utility/axi_if.sv and the comments in
  // src/alveo_u50_static.sv where axi_hbm_mux is declared).
  // ---------------------------------------------------------------
  localparam int HBM_ADDR_W = 64;
  localparam int HBM_DATA_W = 256;
  localparam int HBM_ID_W   = 6;
  localparam int HBM_LEN_W  = 4;   // AXI3, max 16-beat bursts

  // Bytes per HBM beat → how many lanes of the systolic array a
  // single HBM beat can fill (32 for int8).  At MMU_K = 32 lanes each
  // A or B row is exactly 32 bytes — one HBM beat per row.
  localparam int HBM_BYTES_PER_BEAT  = HBM_DATA_W / 8;
  localparam int HBM_BEATS_PER_ROW_A = MMU_K / HBM_BYTES_PER_BEAT;
  localparam int HBM_BEATS_PER_ROW_B = MMU_N / HBM_BYTES_PER_BEAT;

  // C is 32-bit per element, so each row is MMU_N * 4 bytes.
  localparam int HBM_BEATS_PER_ROW_C =
                  (MMU_N * (ACC_W/8)) / HBM_BYTES_PER_BEAT;

  // ---------------------------------------------------------------
  // Total beats per matrix (assuming a contiguous row-major layout
  // in HBM).  Used by the load / store engines to size their burst
  // counters.
  // ---------------------------------------------------------------
  localparam int HBM_BEATS_A = MMU_M * HBM_BEATS_PER_ROW_A;
  localparam int HBM_BEATS_B = MMU_K * HBM_BEATS_PER_ROW_B;
  localparam int HBM_BEATS_C = MMU_M * HBM_BEATS_PER_ROW_C;

endpackage : mmu_pkg
