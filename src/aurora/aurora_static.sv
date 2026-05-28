// *************************************************************************
//
// Static-region wrapper for the Aurora 64b/66b core.
//
// Lives in the static region (alveo_u50_static).  Instantiates the GT
// primitives once for the whole build (so the dynamic-region partition
// doesn't have to satisfy GT-pad placement on every RM) and exposes the
// user-side AXI-Stream interfaces, the aurora-generated `user_clk`, and
// the channel-up status to whatever consumes them.
//
// Aurora 64b/66b config (from build/ip_tcl/aurora_64b66b_0.tcl):
//   * 4 lanes @ 10.3125 Gb/s (256-bit user data, 32-byte tkeep)
//   * GTYE4_CHANNEL_X0Y28..X0Y31 — the full QSFP28 quad on the U50
//   * GT refclk: MGTREFCLK0 of Quad_X0Y7 = 156.25 MHz on the QSFP
//                refclk pads (N36/N37)
//   * Init clock: 100 MHz (passed in here)
//
// Per-lane AXI-Lite DRP slaves and most of the GT debug / control ports
// are tied off here (no per-lane DRP traffic, no eyescan, no PRBS, no
// txdiff overrides).  Hook them up through new module-level ports
// when those features are needed.
//
// Reset / power inputs are deasserted so the support layer drives its
// own resets from `init_clk`.
//
// *************************************************************************
`timescale 1ns/1ps
module aurora_static (
  input  wire        init_clk,

  input  wire        gt_refclk1_p,
  input  wire        gt_refclk1_n,

  // GT serial pins — full 4-lane quad
  input  wire [0:3]  rxp,
  input  wire [0:3]  rxn,
  output wire [0:3]  txp,
  output wire [0:3]  txn,

  // User-side outputs
  output wire        user_clk,
  output wire        user_aresetn,
  output wire        channel_up,

  // TX stream (master to aurora) — 256-bit data, 32-byte tkeep
  input  wire [255:0] tx_tdata,
  input  wire  [31:0] tx_tkeep,
  input  wire         tx_tlast,
  input  wire         tx_tvalid,
  output wire         tx_tready,

  // RX stream (aurora to slave) — 256-bit data, 32-byte tkeep
  output wire [255:0] rx_tdata,
  output wire  [31:0] rx_tkeep,
  output wire         rx_tlast,
  output wire         rx_tvalid,

  // User-K TX (master to aurora) — 256-bit, no framing
  input  wire [255:0] user_k_tx_tdata,
  input  wire         user_k_tx_tvalid,
  output wire         user_k_tx_tready,

  // User-K RX (aurora to slave) — 256-bit, no framing
  output wire [255:0] user_k_rx_tdata,
  output wire         user_k_rx_tvalid
);

  // Aurora-internal sys_reset_out is active high; convert to active low
  // for downstream consumers that follow the project's aresetn convention.
  wire sys_reset_out_int;
  assign user_aresetn = ~sys_reset_out_int;

  aurora_64b66b_0 u_aurora (
    // ---- GT serial side ----
    .rxp           (rxp),
    .rxn           (rxn),
    .txp           (txp),
    .txn           (txn),

    // ---- GT reference clock ----
    .gt_refclk1_p  (gt_refclk1_p),
    .gt_refclk1_n  (gt_refclk1_n),
    .gt_refclk1_out(),

    // ---- Init clock ----
    .init_clk      (init_clk),

    // ---- Reset / power / control — let the support layer manage init ----
    .reset_pb      (1'b0),
    .pma_init      (1'b0),
    .power_down    (1'b0),
    .loopback      (3'b000),

    // ---- Status / done outputs ----
    .channel_up    (channel_up),
    .lane_up       (),
    .hard_err      (),
    .soft_err      (),
    .gt_pll_lock   (),
    .gt_powergood  (),
    .mmcm_not_locked_out (),
    .link_reset_out(),
    .sys_reset_out (sys_reset_out_int),
    .gt_reset_out  (),

    // ---- Generated clocks ----
    .tx_out_clk    (),
    .user_clk_out  (user_clk),
    .sync_clk_out  (),
    .gt_rxusrclk_out(),

    // ---- QPLL / refclk fan-out (dangling) ----
    .gt_qpllclk_quad1_out        (),
    .gt_qpllrefclk_quad1_out     (),
    .gt_qpllrefclklost_quad1_out (),
    .gt_qplllock_quad1_out       (),
    .gt_qplllock                 (),

    // ---- CRC indicators (dangling) ----
    .crc_pass_fail_n (),
    .crc_valid       (),

    // ---- GT control extras ----
    .gt_rxcdrovrden_in (1'b0),

    // ---- USER SIDE: data TX AXI-Stream (256-bit) ----
    .s_axi_tx_tdata   (tx_tdata),
    .s_axi_tx_tkeep   (tx_tkeep),
    .s_axi_tx_tlast   (tx_tlast),
    .s_axi_tx_tvalid  (tx_tvalid),
    .s_axi_tx_tready  (tx_tready),

    // ---- USER SIDE: data RX AXI-Stream (256-bit) ----
    .m_axi_rx_tdata   (rx_tdata),
    .m_axi_rx_tkeep   (rx_tkeep),
    .m_axi_rx_tlast   (rx_tlast),
    .m_axi_rx_tvalid  (rx_tvalid),

    // ---- USER SIDE: user-K AXI-Stream (256-bit) ----
    .s_axi_user_k_tx_tdata   (user_k_tx_tdata),
    .s_axi_user_k_tx_tvalid  (user_k_tx_tvalid),
    .s_axi_user_k_tx_tready  (user_k_tx_tready),
    .m_axi_rx_user_k_tdata   (user_k_rx_tdata),
    .m_axi_rx_user_k_tvalid  (user_k_rx_tvalid),

    // ---- USER SIDE: per-lane AXI-Lite DRP control (tied off / dangling) ----
    .s_axi_awaddr        (32'h0),
    .s_axi_awaddr_lane1  (32'h0),
    .s_axi_awaddr_lane2  (32'h0),
    .s_axi_awaddr_lane3  (32'h0),
    .s_axi_awvalid       (1'b0),
    .s_axi_awvalid_lane1 (1'b0),
    .s_axi_awvalid_lane2 (1'b0),
    .s_axi_awvalid_lane3 (1'b0),
    .s_axi_awready       (),
    .s_axi_awready_lane1 (),
    .s_axi_awready_lane2 (),
    .s_axi_awready_lane3 (),
    .s_axi_wdata         (32'h0),
    .s_axi_wdata_lane1   (32'h0),
    .s_axi_wdata_lane2   (32'h0),
    .s_axi_wdata_lane3   (32'h0),
    .s_axi_wstrb         (4'h0),
    .s_axi_wstrb_lane1   (4'h0),
    .s_axi_wstrb_lane2   (4'h0),
    .s_axi_wstrb_lane3   (4'h0),
    .s_axi_wvalid        (1'b0),
    .s_axi_wvalid_lane1  (1'b0),
    .s_axi_wvalid_lane2  (1'b0),
    .s_axi_wvalid_lane3  (1'b0),
    .s_axi_wready        (),
    .s_axi_wready_lane1  (),
    .s_axi_wready_lane2  (),
    .s_axi_wready_lane3  (),
    .s_axi_bresp         (),
    .s_axi_bresp_lane1   (),
    .s_axi_bresp_lane2   (),
    .s_axi_bresp_lane3   (),
    .s_axi_bvalid        (),
    .s_axi_bvalid_lane1  (),
    .s_axi_bvalid_lane2  (),
    .s_axi_bvalid_lane3  (),
    .s_axi_bready        (1'b1),
    .s_axi_bready_lane1  (1'b1),
    .s_axi_bready_lane2  (1'b1),
    .s_axi_bready_lane3  (1'b1),
    .s_axi_araddr        (32'h0),
    .s_axi_araddr_lane1  (32'h0),
    .s_axi_araddr_lane2  (32'h0),
    .s_axi_araddr_lane3  (32'h0),
    .s_axi_arvalid       (1'b0),
    .s_axi_arvalid_lane1 (1'b0),
    .s_axi_arvalid_lane2 (1'b0),
    .s_axi_arvalid_lane3 (1'b0),
    .s_axi_arready       (),
    .s_axi_arready_lane1 (),
    .s_axi_arready_lane2 (),
    .s_axi_arready_lane3 (),
    .s_axi_rdata         (),
    .s_axi_rdata_lane1   (),
    .s_axi_rdata_lane2   (),
    .s_axi_rdata_lane3   (),
    .s_axi_rresp         (),
    .s_axi_rresp_lane1   (),
    .s_axi_rresp_lane2   (),
    .s_axi_rresp_lane3   (),
    .s_axi_rvalid        (),
    .s_axi_rvalid_lane1  (),
    .s_axi_rvalid_lane2  (),
    .s_axi_rvalid_lane3  (),
    .s_axi_rready        (1'b1),
    .s_axi_rready_lane1  (1'b1),
    .s_axi_rready_lane2  (1'b1),
    .s_axi_rready_lane3  (1'b1),

    // ---- GT debug / per-lane control (tied to safe defaults) ----
    .gt_eyescanreset     (4'h0),
    .gt_eyescandataerror (),
    .gt_rxlpmen          (4'hF),  // LPM RX equalisation enabled (matches IP default)
    .gt_eyescantrigger   (4'h0),
    .gt_rxcdrhold        (4'h0),
    .gt_rxdfelpmreset    (4'h0),
    .gt_rxpmareset       (4'h0),
    .gt_rxpcsreset       (4'h0),
    .gt_rxbufreset       (4'h0),
    .gt_rxpmaresetdone   (),
    .gt_rxprbssel        (16'h0),
    .gt_rxprbserr        (),
    .gt_rxprbscntreset   (4'h0),
    .gt_rxresetdone      (),
    .gt_rxbufstatus      (),
    .gt_txpostcursor     (20'h0),
    .gt_txdiffctrl       (20'h0),
    .gt_txinhibit        (4'h0),
    .gt_pcsrsvdin        (64'h0),
    .gt_txprecursor      (20'h0),
    .gt_txpolarity       (4'h0),
    .gt_txpmareset       (4'h0),
    .gt_txpcsreset       (4'h0),
    .gt_txprbssel        (16'h0),
    .gt_txprbsforceerr   (4'h0),
    .gt_txbufstatus      (),
    .gt_txresetdone      (),
    .gt_dmonitorout      (),
    .gt_cplllock         (),
    .gt_rxrate           (12'h0)
  );

endmodule : aurora_static
