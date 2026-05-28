// *************************************************************************
//
// Aurora 64b/66b user-side stream interface.
//
// Carries one Aurora 64b/66b user-data channel (4 lanes @ 10.3125 Gb/s
// → 256-bit / 32-byte words) plus link status across the PR boundary.
//
// All signals are synchronous to `user_clk`, the aurora-generated clock
// (typically 156.25 MHz for a 4-lane @ 10.3125 Gb/s configuration —
// 4 × 64 b parallel words at the line rate / 64 b per beat).
// `user_aresetn` is the active-low reset in the same domain.
//
// `st` modport — used by the static side (the side that hosts the
//                 aurora_64b66b_0 IP).  Drives the RX channels and the
//                 status outputs; consumes the TX channels.
// `rm` modport — used by the dynamic / RM side.  Drives the TX channels;
//                 consumes the RX channels and status.
//
// Two stream pairs cross the boundary:
//   * tx_* / rx_*                   — the framed user-data channel.
//                                     256-bit, with tlast and tkeep.
//   * user_k_tx_* / user_k_rx_*     — the user-K side channel.  Same
//                                     256-bit width but no framing
//                                     (no tlast, no tkeep) — used for
//                                     short fixed-size messages.
//
// No tready on either RX channel — Aurora 64b/66b doesn't expose
// backpressure on the RX side (data arrives at line rate; the consumer
// must sink it).
//
// *************************************************************************
`timescale 1ns/1ps
interface aurora_if (
  input logic user_clk,
  input logic user_aresetn
);

  // TX (RM → aurora)
  logic [255:0] tx_tdata;
  logic  [31:0] tx_tkeep;
  logic         tx_tlast;
  logic         tx_tvalid;
  logic         tx_tready;

  // RX (aurora → RM)
  logic [255:0] rx_tdata;
  logic  [31:0] rx_tkeep;
  logic         rx_tlast;
  logic         rx_tvalid;

  // User-K TX (RM → aurora) — no framing
  logic [255:0] user_k_tx_tdata;
  logic         user_k_tx_tvalid;
  logic         user_k_tx_tready;

  // User-K RX (aurora → RM) — no framing
  logic [255:0] user_k_rx_tdata;
  logic         user_k_rx_tvalid;

  // Status
  logic        channel_up;

  modport st (
    input  user_clk, user_aresetn,
    input  tx_tdata, tx_tkeep, tx_tlast, tx_tvalid,
    output tx_tready,
    output rx_tdata, rx_tkeep, rx_tlast, rx_tvalid,
    input  user_k_tx_tdata, user_k_tx_tvalid,
    output user_k_tx_tready,
    output user_k_rx_tdata, user_k_rx_tvalid,
    output channel_up
  );

  modport rm (
    input  user_clk, user_aresetn,
    output tx_tdata, tx_tkeep, tx_tlast, tx_tvalid,
    input  tx_tready,
    input  rx_tdata, rx_tkeep, rx_tlast, rx_tvalid,
    output user_k_tx_tdata, user_k_tx_tvalid,
    input  user_k_tx_tready,
    input  user_k_rx_tdata, user_k_rx_tvalid,
    input  channel_up
  );

endinterface: aurora_if
