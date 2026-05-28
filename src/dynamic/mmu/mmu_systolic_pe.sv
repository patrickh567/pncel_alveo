// *************************************************************************
//
// MMU systolic processing element (PE).
//
// Single int8 × int8 → int32 multiply-accumulate cell, weight-stationary,
// to be tiled into the systolic array.
//
// Dataflow contract (one cell):
//
//   ┌──────────┐       a_in (signed int8)
//   │  a_in ──►│──►──► a_out  (registered, 1-cycle delay — = A1)
//   │          │
//   │  w_reg   │       weight is loaded once per matmul via w_we / w_in
//   │          │       and held for the entire compute phase (= B1)
//   │          │
//   │  psum_in │
//   │     │    │
//   │     ▼    │       psum_out = psum_in + a_in_prev * w_reg
//   │   ┌──┐   │       (registered into P — 1 cycle from psum_in to
//   │   │+ │   │        psum_out, 2 cycles from a_in to psum_out)
//   │   └──┘   │
//   │     │    │
//   │     ▼    │
//   └──psum_out┘
//
// Implementation:
//   * One explicit DSP48E2 primitive per PE.
//   * Activation register absorbed into the DSP via AREG=1, ACASCREG=1
//     — A1 holds a_in; ACOUT (= A1) drives a_out.  Multiplier sees A1,
//     so its input is the previous cycle's a_in.
//   * Weight register absorbed into the DSP via BREG=1 + CEB1=w_we
//     — B1 latches w_in only when w_we is asserted, and holds it
//     otherwise.  RSTB is tied off so the weight survives reset
//     (matches the original behaviour).
//   * Output register: PREG=1.  Every other internal register stage
//     (CREG, MREG, DREG, ADREG, ALUMODEREG, OPMODEREG, INMODEREG, …)
//     is set to 0 — psum_in flows through combinationally so the
//     1-cycle south-edge latency per row stays unchanged.
//
// Latency:
//   * a_in → a_out         : 1 cycle (A1 register)
//   * a_in → psum_out      : 2 cycles (A1 + P registers)
//   * psum_in → psum_out   : 1 cycle (combinational C, P register)
//
// The 2-cycle a_in → psum_out path shifts every column-bottom result
// by exactly one cycle versus the original (a*b)+c inference template.
// `mmu_systolic_array.sv` accounts for this with one extra stage on
// the c_valid pipe — the input/output skew chains are unchanged
// because the per-PE eastbound delay (a_in → a_out) is still 1 cycle.
//
// Reset behaviour:
//   * rst clears a_out / A1 (RSTA) and psum_out / P (RSTP).
//   * w_reg / B1 is NOT reset — software relies on the last-loaded
//     weight surviving a re-arm of the engine.
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_systolic_pe
  import mmu_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst,        // synchronous, active-high

  // Weight load (single-cycle pulse during LOAD_B)
  input  logic                    w_we,
  input  logic signed [IN_W-1:0]  w_in,

  // Activation pass-through
  input  logic signed [IN_W-1:0]  a_in,
  output logic signed [IN_W-1:0]  a_out,

  // Partial-sum accumulator pass-through (top → bottom)
  input  logic signed [ACC_W-1:0] psum_in,
  output logic signed [ACC_W-1:0] psum_out
);

  // -----------------------------------------------------------------
  // Operand sign-extension to the DSP input widths.
  //   a_in  ( IN_W bits) → A  (30 bits)
  //   w_in  ( IN_W bits) → B  (18 bits)
  //   psum_in (ACC_W b)  → C  (48 bits)
  // -----------------------------------------------------------------
  wire [29:0] dsp_a = {{(30-IN_W){a_in[IN_W-1]}},     a_in};
  wire [17:0] dsp_b = {{(18-IN_W){w_in[IN_W-1]}},     w_in};
  wire [47:0] dsp_c = {{(48-ACC_W){psum_in[ACC_W-1]}}, psum_in};
  wire [47:0] dsp_p;
  wire [29:0] dsp_acout;

  DSP48E2 #(
    // Pipeline configuration:
    //   AREG=1, ACASCREG=1  — input flop on a_in; ACOUT exposes A1 as a_out.
    //   BREG=1, BCASCREG=1  — weight register inside the DSP, gated by CEB1.
    //   PREG=1              — output flop on psum_out.
    // Everything else is 0 (no MREG, no CREG, no INMODEREG, etc.).
    .ACASCREG          (1),
    .ADREG             (0),
    .ALUMODEREG        (0),
    .AREG              (1),
    .BCASCREG          (1),
    .BREG              (1),
    .CARRYINREG        (0),
    .CARRYINSELREG     (0),
    .CREG              (0),
    .DREG              (0),
    .INMODEREG         (0),
    .MREG              (0),
    .OPMODEREG         (0),
    .PREG              (1),

    .A_INPUT           ("DIRECT"),
    .B_INPUT           ("DIRECT"),
    .AMULTSEL          ("A"),
    .BMULTSEL          ("B"),
    .PREADDINSEL       ("A"),

    .USE_MULT          ("MULTIPLY"),
    .USE_SIMD          ("ONE48"),
    .USE_WIDEXOR       ("FALSE"),
    .XORSIMD           ("XOR24_48_96"),
    .USE_PATTERN_DETECT  ("NO_PATDET"),
    .AUTORESET_PATDET    ("NO_RESET"),
    .AUTORESET_PRIORITY  ("RESET"),
    .MASK              (48'h3FFFFFFFFFFF),
    .PATTERN           (48'h0),
    .SEL_MASK          ("MASK"),
    .SEL_PATTERN       ("PATTERN"),
    .RND               (48'h0)
  ) u_dsp (
    // Operand inputs
    .A                 (dsp_a),
    .B                 (dsp_b),
    .C                 (dsp_c),
    .D                 (27'b0),

    // Cascade inputs (unused — A_INPUT/B_INPUT = "DIRECT")
    .ACIN              (30'b0),
    .BCIN              (18'b0),
    .PCIN              (48'b0),
    .CARRYCASCIN       (1'b0),
    .MULTSIGNIN        (1'b0),

    // Carry chain unused
    .CARRYIN           (1'b0),
    .CARRYINSEL        (3'b000),

    // Control: post-adder = X + Y + Z + W + CIN  (ALUMODE = 0)
    //   X=M, Y=M  → full 45-bit multiplier output spans X/Y
    //   Z=C       → adds psum_in (sign-extended)
    //   W=0
    // INMODE = 0: A1 → multiplier, B1 → multiplier, no pre-adder.
    .OPMODE            (9'b00_011_01_01),
    .ALUMODE           (4'b0000),
    .INMODE            (5'b00000),

    // Clock and clock enables.  Only CEA1, CEB1 (gated), and CEP are
    // live — every other CE drives an internal register configured to
    // 0 stages, so the tied-off value is harmless.
    .CLK               (clk),
    .CEA1              (1'b1),    // A1 captures a_in every cycle
    .CEA2              (1'b0),
    .CEAD              (1'b0),
    .CEALUMODE         (1'b0),
    .CEB1              (w_we),    // B1 (weight register) updates only on w_we
    .CEB2              (1'b0),
    .CEC               (1'b0),
    .CECARRYIN         (1'b0),
    .CECTRL            (1'b0),
    .CED               (1'b0),
    .CEINMODE          (1'b0),
    .CEM               (1'b0),
    .CEP               (1'b1),

    // Resets — A1 and P reset on `rst`; B1 (the weight) does NOT reset
    // so software can rely on the last-loaded weight surviving a
    // re-arm of the engine.
    .RSTA              (rst),
    .RSTALLCARRYIN     (1'b0),
    .RSTALUMODE        (1'b0),
    .RSTB              (1'b0),
    .RSTC              (1'b0),
    .RSTCTRL           (1'b0),
    .RSTD              (1'b0),
    .RSTINMODE         (1'b0),
    .RSTM              (1'b0),
    .RSTP              (rst),

    // Outputs
    .P                 (dsp_p),
    .ACOUT             (dsp_acout),

    // Unused outputs (cascades / status / XOR)
    .BCOUT             (),
    .CARRYCASCOUT      (),
    .CARRYOUT          (),
    .MULTSIGNOUT       (),
    .OVERFLOW          (),
    .PATTERNBDETECT    (),
    .PATTERNDETECT     (),
    .PCOUT             (),
    .UNDERFLOW         (),
    .XOROUT            ()
  );

  // ACOUT = A1 register output (full 30 bits); the low IN_W bits are
  // the registered a_in — sign-extension above doesn't disturb them.
  assign a_out    = dsp_acout[IN_W-1:0];
  assign psum_out = dsp_p[ACC_W-1:0];

endmodule : mmu_systolic_pe
