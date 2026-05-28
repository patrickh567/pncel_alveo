// *************************************************************************
//
// MMU systolic array — MMU_K × MMU_N grid of weight-stationary int8
// MAC PEs (32×32 with the current package params).
//
// Dataflow (TPU v1 style):
//
//   * Weights B[i][j] are loaded once into PE(i,j) at the start of the
//     compute phase (LOAD_B), one row of B per cycle, K cycles total.
//   * Activations stream in from the LEFT edge.  The user delivers ONE
//     row of A (K elements) per cycle on `a_row_in` for M cycles.  Inside
//     the array, each row r has a triangular delay chain of r flip-flops
//     so that A[m][r] arrives at PE(r, 0) at cycle (m + r), giving the
//     classic systolic skew pattern.
//   * Each PE computes psum_out = psum_in + a_in × w_reg.  Partial sums
//     accumulate top → bottom along each column.  After K cycles of
//     downward propagation a column's bottom-edge psum is the dot
//     product C[m][j] for whichever A row is currently traversing column
//     j (plus the corresponding j-cycle horizontal latency).
//   * The bottom edge feeds an output triangular chain that delays
//     column j by (N-1-j) cycles, undoing the horizontal skew so all
//     columns of one row of C appear simultaneously on `c_row_out`.
//   * `c_valid` is a delayed copy of `a_valid` shifted by the full
//     pipeline latency so the consumer can latch C rows into the C
//     buffer one per cycle.
//
// Pipeline latency (a_valid → first c_valid) is 2K + 2N − 2 cycles for
// a square array, derived from the same flow as the inferred-MAC
// version (2K + 2N − 3) plus one extra cycle introduced by the PE's
// absorbed A-input register (AREG=1 inside the DSP48E2): the
// multiplier now sees A1, the registered a_in, so every column-bottom
// result lands one cycle later than it would with combinational A.
// The eastbound a_out chain is unchanged (1 cycle per PE, sourced
// from ACOUT = A1), so the input/output skew chains keep their
// original length.  For K = N = 32 this is 126 cycles.
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_systolic_array
  import mmu_pkg::*;
(
  input  logic                                 clk,
  input  logic                                 rst,        // sync, active high

  // -----------------------------------------------------------------
  // Weight load interface (active during LOAD_B; one row per cycle)
  // -----------------------------------------------------------------
  input  logic                                 w_load_en,
  input  logic [$clog2(MMU_K)-1:0]             w_load_row,
  input  logic signed [MMU_N-1:0][IN_W-1:0]    w_load_data,

  // -----------------------------------------------------------------
  // Activation streaming (active during COMPUTE; one A row per cycle)
  // -----------------------------------------------------------------
  input  logic                                 a_valid,
  input  logic signed [MMU_K-1:0][IN_W-1:0]    a_row_in,

  // -----------------------------------------------------------------
  // C row stream (one row of int32 partial sums per cycle once latency
  // has been absorbed)
  // -----------------------------------------------------------------
  output logic                                 c_valid,
  output logic signed [MMU_N-1:0][ACC_W-1:0]   c_row_out
);

  localparam int K = MMU_K;
  localparam int N = MMU_N;
  localparam int LATENCY = 2*K + 2*N - 2;   // a_valid → first c_valid
                                            // (+1 vs the original because
                                            // each PE has AREG=1 inside
                                            // its DSP48E2 now)

  // -----------------------------------------------------------------
  // Input triangular skew
  //
  // a_skew[r][s] = activation for array row r, after s pipeline stages.
  // Row r needs r delay stages, so only a_skew[r][0..r] are meaningful;
  // synthesis will DCE the rest.
  // -----------------------------------------------------------------
  logic signed [IN_W-1:0] a_skew [K][K];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int r = 0; r < K; r++) begin
        for (int s = 0; s < K; s++) a_skew[r][s] <= '0;
      end
    end else begin
      for (int r = 0; r < K; r++) begin
        a_skew[r][0] <= a_valid ? a_row_in[r] : '0;
        for (int s = 1; s < K; s++) begin
          a_skew[r][s] <= a_skew[r][s-1];
        end
      end
    end
  end

  // -----------------------------------------------------------------
  // PE mesh
  //
  // pe_a[r][c]    = activation feeding PE(r, c) — for c == 0 driven by
  //                 the skew chain, for c > 0 driven by PE(r, c-1).a_out.
  // pe_psum[r][c] = partial sum feeding PE(r, c) — for r == 0 forced to
  //                 zero, for r > 0 driven by PE(r-1, c).psum_out.
  // -----------------------------------------------------------------
  logic signed [IN_W-1:0]  pe_a    [K][N+1];
  logic signed [ACC_W-1:0] pe_psum [K+1][N];

  // Top edge of every column is psum = 0
  for (genvar c = 0; c < N; c++) begin : g_psum_top
    assign pe_psum[0][c] = '0;
  end

  // Left edge of every row is the output of its skew chain
  for (genvar r = 0; r < K; r++) begin : g_a_left
    assign pe_a[r][0] = a_skew[r][r];
  end

  // The PE grid itself
  for (genvar r = 0; r < K; r++) begin : g_row
    for (genvar c = 0; c < N; c++) begin : g_col
      mmu_systolic_pe u_pe (
        .clk      (clk),
        .rst      (rst),
        .w_we     (w_load_en && (w_load_row == r[$clog2(K)-1:0])),
        .w_in     (w_load_data[c]),
        .a_in     (pe_a[r][c]),
        .a_out    (pe_a[r][c+1]),
        .psum_in  (pe_psum[r][c]),
        .psum_out (pe_psum[r+1][c])
      );
    end
  end

  // -----------------------------------------------------------------
  // Output triangular skew
  //
  // Column j has (N-1-j) delay stages so that the bottom-edge psum from
  // every column of one row of C lines up on the same cycle.  Column 0
  // (deepest) has N-1 delays; column N-1 has none.
  // -----------------------------------------------------------------
  logic signed [ACC_W-1:0] c_skew [N][N];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int c = 0; c < N; c++) begin
        for (int s = 0; s < N; s++) c_skew[c][s] <= '0;
      end
    end else begin
      for (int c = 0; c < N; c++) begin
        c_skew[c][0] <= pe_psum[K][c];
        for (int s = 1; s < N; s++) begin
          c_skew[c][s] <= c_skew[c][s-1];
        end
      end
    end
  end

  // c_row_out[c] = column c's value after (N-1-c) skew stages
  for (genvar c = 0; c < N; c++) begin : g_c_out
    assign c_row_out[c] = c_skew[c][N-1-c];
  end

  // -----------------------------------------------------------------
  // c_valid = a_valid shifted by the full pipeline latency
  // -----------------------------------------------------------------
  logic [LATENCY-1:0] valid_pipe;
  always_ff @(posedge clk) begin
    if (rst)
      valid_pipe <= '0;
    else
      valid_pipe <= {valid_pipe[LATENCY-2:0], a_valid};
  end
  assign c_valid = valid_pipe[LATENCY-1];

endmodule : mmu_systolic_array
