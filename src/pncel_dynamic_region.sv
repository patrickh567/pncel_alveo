// *************************************************************************
//
// pncel-alveo dynamic region — PR partition (Aurora-bridge default RM).
//
// Flat Verilog ports.  Partition boundary now carries Aurora's physical
// GT pins (refclk + 4 lanes) in addition to the AXI buses that come
// through the static-side decouplers.  This RM hosts:
//
//   * clk_wiz_hbm           — derives 100 MHz init_clk from aclk
//                             (Aurora's reset state machine).  Re-used
//                             from the original alveo_u50_host IP TCL.
//   * aurora_64b66b_0       — 4-lane × 10.3125 Gb/s link to the
//                             far-end ZCU102 board.  Uses the QSFP28
//                             quad (GTYE4_CHANNEL_X0Y28..X0Y31) and
//                             MGTREFCLK0_of_Quad_X0Y7 (the U50's
//                             user-programmable QSFP refclk pads at
//                             N36/N37).  Outputs user_clk (~156.25 MHz)
//                             — every other block downstream of Aurora
//                             runs on this user_clk.
//   * axi_clock_converter_data — 256 b AXI4 CDC from aclk (250 MHz)
//                                to aurora_user_clk.
//   * axi_lite_clock_converter — 32 b AXI-Lite CDC, same direction.
//   * axi_aurora_bridge_inv — host-side bridge.  Takes XDMA AXI4 +
//                             AXI-Lite slaves on user_clk and packetizes
//                             them onto Aurora's data + user-K TX
//                             streams; demultiplexes Aurora's RX
//                             streams back into the slave responses.
//                             Its own AXI4 master port (`m_*`) is for
//                             far-end-initiated reads into host memory;
//                             not used here, tied off.
//
// Boundary to the static side stays the same as the scratchpad RM:
//   aclk         — 250 MHz from XDMA (through pncel_top, not decoupled)
//   aresetn      — dynamic-region reset, active low
//   s_axi_data   — 256 b AXI4 slave (XDMA m_axi)
//   s_axil_ctrl  — 32 b AXI-Lite slave (XDMA m_axil)
// New for Aurora:
//   gt_refclk1_p/n  — QSFP28 user refclk diff pair (board pads N36/N37)
//   rxp[3:0]/rxn[3:0] — 4-lane RX serial pairs
//   txp[3:0]/txn[3:0] — 4-lane TX serial pairs
//
// *************************************************************************
`timescale 1ns/1ps

`define AXI_SLAVE_FLAT_PORTS(PFX, AW, DW, IW, LW)     \
  input  wire [IW-1:0]     PFX``_awid,                \
  input  wire [AW-1:0]     PFX``_awaddr,              \
  input  wire [LW-1:0]     PFX``_awlen,               \
  input  wire [2:0]        PFX``_awsize,              \
  input  wire [1:0]        PFX``_awburst,             \
  input  wire              PFX``_awlock,              \
  input  wire [3:0]        PFX``_awcache,             \
  input  wire [2:0]        PFX``_awprot,              \
  input  wire [3:0]        PFX``_awqos,               \
  input  wire [3:0]        PFX``_awregion,            \
  input  wire              PFX``_awvalid,             \
  output wire              PFX``_awready,             \
  input  wire [DW-1:0]     PFX``_wdata,               \
  input  wire [(DW/8)-1:0] PFX``_wstrb,               \
  input  wire              PFX``_wlast,               \
  input  wire              PFX``_wvalid,              \
  output wire              PFX``_wready,              \
  output wire [IW-1:0]     PFX``_bid,                 \
  output wire [1:0]        PFX``_bresp,               \
  output wire              PFX``_bvalid,              \
  input  wire              PFX``_bready,              \
  input  wire [IW-1:0]     PFX``_arid,                \
  input  wire [AW-1:0]     PFX``_araddr,              \
  input  wire [LW-1:0]     PFX``_arlen,               \
  input  wire [2:0]        PFX``_arsize,              \
  input  wire [1:0]        PFX``_arburst,             \
  input  wire              PFX``_arlock,              \
  input  wire [3:0]        PFX``_arcache,             \
  input  wire [2:0]        PFX``_arprot,              \
  input  wire [3:0]        PFX``_arqos,               \
  input  wire [3:0]        PFX``_arregion,            \
  input  wire              PFX``_arvalid,             \
  output wire              PFX``_arready,             \
  output wire [IW-1:0]     PFX``_rid,                 \
  output wire [DW-1:0]     PFX``_rdata,               \
  output wire [1:0]        PFX``_rresp,               \
  output wire              PFX``_rlast,               \
  output wire              PFX``_rvalid,              \
  input  wire              PFX``_rready

`define AXI_SLAVE_TIEOFF(PFX)           \
  assign PFX``_awready = 1'b0;          \
  assign PFX``_wready  = 1'b0;          \
  assign PFX``_bid     = '0;            \
  assign PFX``_bresp   = 2'b00;         \
  assign PFX``_bvalid  = 1'b0;          \
  assign PFX``_arready = 1'b0;          \
  assign PFX``_rid     = '0;            \
  assign PFX``_rdata   = '0;            \
  assign PFX``_rresp   = 2'b00;         \
  assign PFX``_rlast   = 1'b0;          \
  assign PFX``_rvalid  = 1'b0

module pncel_dynamic_region (
  input wire aclk,
  input wire aresetn,

`ifndef SIMULATION
  // ---- GT physical pins (cross the PR boundary; tied to QSFP28 cage) -----
  input  wire        gt_refclk1_p,
  input  wire        gt_refclk1_n,
  input  wire [3:0]  rxp,
  input  wire [3:0]  rxn,
  output wire [3:0]  txp,
  output wire [3:0]  txn,
`else
  // ---- Simulation sim-aurora stub interface --------------------------
  // The Aurora IP + clk_wiz_init are removed under SIMULATION; the
  // testbench supplies the user clock and the link-up status, and
  // drives / observes the user-side streams directly.
  input  wire         sim_aurora_user_clk,
  input  wire         sim_aurora_channel_up,
  // TX direction: bridge → testbench (TB observes what gets shipped).
  output wire [255:0] sim_aurora_tx_tdata,
  output wire  [31:0] sim_aurora_tx_tkeep,
  output wire         sim_aurora_tx_tlast,
  output wire         sim_aurora_tx_tvalid,
  input  wire         sim_aurora_tx_tready,
  // RX direction: testbench → bridge (TB injects "far-end" traffic).
  input  wire [255:0] sim_aurora_rx_tdata,
  input  wire  [31:0] sim_aurora_rx_tkeep,
  input  wire         sim_aurora_rx_tlast,
  input  wire         sim_aurora_rx_tvalid,
  // User-K direction (same convention).
  output wire [255:0] sim_aurora_userk_tx_tdata,
  output wire         sim_aurora_userk_tx_tvalid,
  input  wire         sim_aurora_userk_tx_tready,
  input  wire [255:0] sim_aurora_userk_rx_tdata,
  input  wire         sim_aurora_userk_rx_tvalid,
`endif

  // 256-bit AXI4 high-bandwidth data slave (from XDMA via decoupler) —
  // goes to the aurora bridge's s_full input (ships off-chip over Aurora).
  `AXI_SLAVE_FLAT_PORTS (s_axi_data,  64, 256, 4, 8),

  // 256-bit AXI4 high-bandwidth data slave (from XDMA via decoupler) —
  // direct path to axi_crossbar_bram.SI[1] (aclk domain, no protocol
  // conversion).  Address window 0x4_0000_0000-0x4_0FFF_FFFF per
  // axi_dma_switch.tcl M02.
  `AXI_SLAVE_FLAT_PORTS (s_axi_hbm,   64, 256, 4, 8),

  // 32-bit AXI-Lite control slave (from XDMA via decoupler).
  `AXI_SLAVE_FLAT_PORTS (s_axil_ctrl, 32,  32, 1, 8),

  // Legacy J18 cattrip board pin — kept so pncel_top's OBUF and
  // system_config telemetry input still have a defined driver.  Tied
  // to 0 inside (no HBM IP → no real thermal trip).
  output wire         hbm_cattrip
);

  // ---------------------------------------------------------------------
  // 100 MHz init_clk for Aurora's reset state machine.  clk_wiz_hbm is
  // reused from the original alveo_u50_host design (input = aclk @
  // 250 MHz, clk_out1 @ 100 MHz).  No reset port on this clk_wiz config.
  // Under SIMULATION the IP is dropped — clk_wiz_hbm includes an MMCM
  // and locking sequence that's slow and adds no value in RTL sim.
  // Just divide aclk-by-N behaviorally to make a roughly-100 MHz tick.
  // ---------------------------------------------------------------------
  wire init_clk_100;
`ifndef SIMULATION
  clk_wiz_hbm clk_wiz_init_inst (
    .clk_in1  (aclk),
    .clk_out1 (init_clk_100)
  );
`else
  // Behavioural 100 MHz tick: aclk is 250 MHz (4 ns); divide by ~2.5 ↦
  // toggle every 2 aclks (~125 MHz, close enough for sim — no IP timing
  // checks).  Aurora's reset state machine tolerates any clock in this
  // range.  Use `always` not `always_ff` so VCS's strict single-driver
  // rule doesn't reject the initializer + clocked-update combo.  This
  // is a sim-only behavioural toggle; no synthesis intent.
  reg sim_init_clk_r = 1'b0;
  always @(posedge aclk) sim_init_clk_r <= ~sim_init_clk_r;
  assign init_clk_100 = sim_init_clk_r;
`endif

  // ---------------------------------------------------------------------
  // Aurora 64b/66b — instantiate with the same pin / refclk / lane map
  // as the original alveo_u50_host aurora design (4 lanes @ 10.3125
  // Gb/s, GTYE4_CHANNEL_X0Y28..X0Y31, MGTREFCLK0_of_Quad_X0Y7).
  // ---------------------------------------------------------------------
  wire        aurora_user_clk;
  wire        aurora_user_aresetn;
  wire        aurora_channel_up;
  wire        aurora_sys_reset_int;
  assign aurora_user_aresetn = ~aurora_sys_reset_int;

  // Aurora user-side streams (256-bit data + user-K).
  wire [255:0] aurora_tx_tdata;
  wire [31:0]  aurora_tx_tkeep;
  wire         aurora_tx_tlast;
  wire         aurora_tx_tvalid;
  wire         aurora_tx_tready;
  wire [255:0] aurora_rx_tdata;
  wire [31:0]  aurora_rx_tkeep;
  wire         aurora_rx_tlast;
  wire         aurora_rx_tvalid;
  wire [255:0] aurora_userk_tx_tdata;
  wire         aurora_userk_tx_tvalid;
  wire         aurora_userk_tx_tready;
  wire [255:0] aurora_userk_rx_tdata;
  wire         aurora_userk_rx_tvalid;

  // ---------------------------------------------------------------------
  // Aurora status / error / clocking nets.  Declared up here (not inline
  // at the Aurora instantiation) so the port mappings don't trigger
  // Verilog implicit 1-bit net creation — same gotcha that bit us on
  // bridge.m_*.  These nets are only driven by the Aurora IP in synth;
  // the simulation stub doesn't model link state in detail so they
  // stay dangling under SIMULATION.
  // ---------------------------------------------------------------------
  wire [3:0]   aurora_st_lane_up;
  wire         aurora_st_hard_err;
  wire         aurora_st_soft_err;
  wire         aurora_st_gt_pll_lock;
  wire [3:0]   aurora_st_gt_powergood;
  wire         aurora_st_mmcm_not_locked_out;
  wire         aurora_st_link_reset_out;
  wire         aurora_st_gt_reset_out;
  wire         aurora_st_qpllrefclklost;
  wire         aurora_st_qplllock_q1;
  wire         aurora_st_qplllock;
  wire         aurora_st_crc_pass_fail_n;
  wire         aurora_st_crc_valid;

`ifndef SIMULATION
  aurora_64b66b_0 u_aurora (
    // ---- GT serial side ----
    .rxp                          (rxp),
    .rxn                          (rxn),
    .txp                          (txp),
    .txn                          (txn),

    // ---- GT reference clock ----
    .gt_refclk1_p                 (gt_refclk1_p),
    .gt_refclk1_n                 (gt_refclk1_n),
    .gt_refclk1_out               (),

    // ---- Init clock ----
    .init_clk                     (init_clk_100),

    // ---- Reset / power / control (support layer manages init) ----
    .reset_pb                     (1'b0),
    .pma_init                     (1'b0),
    .power_down                   (1'b0),
    .loopback                     (3'b000),

    // ---- Status outputs ----
    .channel_up                   (aurora_channel_up),
    .lane_up                      (aurora_st_lane_up),
    .hard_err                     (aurora_st_hard_err),
    .soft_err                     (aurora_st_soft_err),
    .gt_pll_lock                  (aurora_st_gt_pll_lock),
    .gt_powergood                 (aurora_st_gt_powergood),
    .mmcm_not_locked_out          (aurora_st_mmcm_not_locked_out),
    .link_reset_out               (aurora_st_link_reset_out),
    .sys_reset_out                (aurora_sys_reset_int),
    .gt_reset_out                 (aurora_st_gt_reset_out),

    // ---- Generated clocks ----
    .tx_out_clk                   (),
    .user_clk_out                 (aurora_user_clk),
    .sync_clk_out                 (),
    .gt_rxusrclk_out              (),

    // ---- QPLL / refclk fan-out ----
    .gt_qpllclk_quad1_out         (),
    .gt_qpllrefclk_quad1_out      (),
    .gt_qpllrefclklost_quad1_out  (aurora_st_qpllrefclklost),
    .gt_qplllock_quad1_out        (aurora_st_qplllock_q1),
    .gt_qplllock                  (aurora_st_qplllock),

    // ---- CRC indicators ----
    .crc_pass_fail_n              (aurora_st_crc_pass_fail_n),
    .crc_valid                    (aurora_st_crc_valid),

    // ---- GT control extras ----
    .gt_rxcdrovrden_in            (1'b0),

    // ---- USER SIDE: data TX AXI-Stream (256-bit) ----
    .s_axi_tx_tdata               (aurora_tx_tdata),
    .s_axi_tx_tkeep               (aurora_tx_tkeep),
    .s_axi_tx_tlast               (aurora_tx_tlast),
    .s_axi_tx_tvalid              (aurora_tx_tvalid),
    .s_axi_tx_tready              (aurora_tx_tready),

    // ---- USER SIDE: data RX AXI-Stream (256-bit) ----
    .m_axi_rx_tdata               (aurora_rx_tdata),
    .m_axi_rx_tkeep               (aurora_rx_tkeep),
    .m_axi_rx_tlast               (aurora_rx_tlast),
    .m_axi_rx_tvalid              (aurora_rx_tvalid),

    // ---- USER SIDE: user-K AXI-Stream (256-bit) ----
    .s_axi_user_k_tx_tdata        (aurora_userk_tx_tdata),
    .s_axi_user_k_tx_tvalid       (aurora_userk_tx_tvalid),
    .s_axi_user_k_tx_tready       (aurora_userk_tx_tready),
    .m_axi_rx_user_k_tdata        (aurora_userk_rx_tdata),
    .m_axi_rx_user_k_tvalid       (aurora_userk_rx_tvalid),

    // ---- Per-lane AXI-Lite DRP (tied off — no per-lane DRP traffic) ----
    .s_axi_awaddr        (32'h0), .s_axi_awaddr_lane1  (32'h0),
    .s_axi_awaddr_lane2  (32'h0), .s_axi_awaddr_lane3  (32'h0),
    .s_axi_awvalid       (1'b0),  .s_axi_awvalid_lane1 (1'b0),
    .s_axi_awvalid_lane2 (1'b0),  .s_axi_awvalid_lane3 (1'b0),
    .s_axi_awready       (),      .s_axi_awready_lane1 (),
    .s_axi_awready_lane2 (),      .s_axi_awready_lane3 (),
    .s_axi_wdata         (32'h0), .s_axi_wdata_lane1   (32'h0),
    .s_axi_wdata_lane2   (32'h0), .s_axi_wdata_lane3   (32'h0),
    .s_axi_wstrb         (4'h0),  .s_axi_wstrb_lane1   (4'h0),
    .s_axi_wstrb_lane2   (4'h0),  .s_axi_wstrb_lane3   (4'h0),
    .s_axi_wvalid        (1'b0),  .s_axi_wvalid_lane1  (1'b0),
    .s_axi_wvalid_lane2  (1'b0),  .s_axi_wvalid_lane3  (1'b0),
    .s_axi_wready        (),      .s_axi_wready_lane1  (),
    .s_axi_wready_lane2  (),      .s_axi_wready_lane3  (),
    .s_axi_bresp         (),      .s_axi_bresp_lane1   (),
    .s_axi_bresp_lane2   (),      .s_axi_bresp_lane3   (),
    .s_axi_bvalid        (),      .s_axi_bvalid_lane1  (),
    .s_axi_bvalid_lane2  (),      .s_axi_bvalid_lane3  (),
    .s_axi_bready        (1'b1),  .s_axi_bready_lane1  (1'b1),
    .s_axi_bready_lane2  (1'b1),  .s_axi_bready_lane3  (1'b1),
    .s_axi_araddr        (32'h0), .s_axi_araddr_lane1  (32'h0),
    .s_axi_araddr_lane2  (32'h0), .s_axi_araddr_lane3  (32'h0),
    .s_axi_arvalid       (1'b0),  .s_axi_arvalid_lane1 (1'b0),
    .s_axi_arvalid_lane2 (1'b0),  .s_axi_arvalid_lane3 (1'b0),
    .s_axi_arready       (),      .s_axi_arready_lane1 (),
    .s_axi_arready_lane2 (),      .s_axi_arready_lane3 (),
    .s_axi_rdata         (),      .s_axi_rdata_lane1   (),
    .s_axi_rdata_lane2   (),      .s_axi_rdata_lane3   (),
    .s_axi_rresp         (),      .s_axi_rresp_lane1   (),
    .s_axi_rresp_lane2   (),      .s_axi_rresp_lane3   (),
    .s_axi_rvalid        (),      .s_axi_rvalid_lane1  (),
    .s_axi_rvalid_lane2  (),      .s_axi_rvalid_lane3  (),
    .s_axi_rready        (1'b1),  .s_axi_rready_lane1  (1'b1),
    .s_axi_rready_lane2  (1'b1),  .s_axi_rready_lane3  (1'b1),

    // ---- GT debug / per-lane control (safe defaults; LPM eq enabled) ----
    .gt_eyescanreset     (4'h0),  .gt_eyescandataerror (),
    .gt_rxlpmen          (4'hF),  .gt_eyescantrigger   (4'h0),
    .gt_rxcdrhold        (4'h0),  .gt_rxdfelpmreset    (4'h0),
    .gt_rxpmareset       (4'h0),  .gt_rxpcsreset       (4'h0),
    .gt_rxbufreset       (4'h0),  .gt_rxpmaresetdone   (),
    .gt_rxprbssel        (16'h0), .gt_rxprbserr        (),
    .gt_rxprbscntreset   (4'h0),  .gt_rxresetdone      (),
    .gt_rxbufstatus      (),      .gt_txpostcursor     (20'h0),
    .gt_txdiffctrl       (20'h0), .gt_txinhibit        (4'h0),
    .gt_pcsrsvdin        (64'h0), .gt_txprecursor      (20'h0),
    .gt_txpolarity       (4'h0),  .gt_txpmareset       (4'h0),
    .gt_txpcsreset       (4'h0),  .gt_txprbssel        (16'h0),
    .gt_txprbsforceerr   (4'h0),  .gt_txbufstatus      (),
    .gt_txresetdone      (),      .gt_dmonitorout      (),
    .gt_cplllock         (),      .gt_rxrate           (12'h0)
  );

  // ---------------------------------------------------------------------
  // ILA on every Aurora status signal, clocked off the 100 MHz init_clk.
  //
  // Most of these signals originate on user_clk (channel_up, lane_up,
  // hard/soft_err, CRC) or are async with respect to init_clk (the GT
  // *_powergood / *_pll_lock / *_qplllock family).  A 2-FF synchroniser
  // upstream of the ILA prevents metastability on the capture path —
  // single-cycle pulses are slightly at risk of being missed, but
  // every signal here is slow-changing in practice (link bring-up,
  // sustained errors), so the loss is acceptable in exchange for clean
  // ILA output.
  //
  // capture depth = 4096 samples × 10 ns = 40 us per capture, plenty
  // to cover an Aurora bring-up sequence end-to-end.
  // ---------------------------------------------------------------------
  // Concatenate the 21-bit status pool, sync as one bus to reduce LUT
  // count, then re-slice for the ILA's named probes.
  localparam int AUR_ST_W = 1 + 4 + 1 + 1 + 1 + 4 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1;  // 21
  wire [AUR_ST_W-1:0] aurora_status_async = {
      aurora_st_qpllrefclklost,        // [20]
      aurora_st_qplllock_q1,           // [19]
      aurora_st_qplllock,              // [18]
      aurora_st_crc_pass_fail_n,       // [17]
      aurora_st_crc_valid,             // [16]
      aurora_st_mmcm_not_locked_out,   // [15]
      aurora_st_gt_powergood,          // [14:11]
      aurora_st_gt_pll_lock,           // [10]
      aurora_st_gt_reset_out,          // [9]
      aurora_st_link_reset_out,        // [8]
      aurora_sys_reset_int,            // [7]
      aurora_st_soft_err,              // [6]
      aurora_st_hard_err,              // [5]
      aurora_st_lane_up,               // [4:1]
      aurora_channel_up                // [0]
  };

  (* ASYNC_REG = "TRUE" *) reg [AUR_ST_W-1:0] aurora_status_sync_q0;
  (* ASYNC_REG = "TRUE" *) reg [AUR_ST_W-1:0] aurora_status_sync_q1;
  always @(posedge init_clk_100) begin
    aurora_status_sync_q0 <= aurora_status_async;
    aurora_status_sync_q1 <= aurora_status_sync_q0;
  end
  wire [AUR_ST_W-1:0] s = aurora_status_sync_q1;

  ila_aurora_status u_ila_aurora_status (
    .clk     (init_clk_100),
    .probe0  (s[0]),         // channel_up
    .probe1  (s[4:1]),       // lane_up[3:0]
    .probe2  (s[5]),         // hard_err
    .probe3  (s[6]),         // soft_err
    .probe4  (s[7]),         // sys_reset_out
    .probe5  (s[8]),         // link_reset_out
    .probe6  (s[9]),         // gt_reset_out
    .probe7  (s[10]),        // gt_pll_lock
    .probe8  (s[14:11]),     // gt_powergood[3:0]
    .probe9  (s[15]),        // mmcm_not_locked_out
    .probe10 (s[16]),        // crc_valid
    .probe11 (s[17]),        // crc_pass_fail_n
    .probe12 (s[18]),        // gt_qplllock
    .probe13 (s[19]),        // gt_qplllock_quad1_out
    .probe14 (s[20])         // gt_qpllrefclklost_quad1_out
  );
`else
  // ----- Simulation Aurora stub --------------------------------------
  // Aurora IP replaced by direct pass-through to / from the sim_aurora_*
  // ports.  The testbench provides aurora_user_clk and asserts
  // channel_up after its own bring-up sequence.
  assign aurora_user_clk        = sim_aurora_user_clk;
  assign aurora_channel_up      = sim_aurora_channel_up;
  // sys_reset goes low when the link is up.  Mirror that off
  // channel_up so the downstream bridge_aresetn behaves the same way
  // it would in synth.
  assign aurora_sys_reset_int   = ~sim_aurora_channel_up;
  // TX streams: bridge → testbench
  assign sim_aurora_tx_tdata        = aurora_tx_tdata;
  assign sim_aurora_tx_tkeep        = aurora_tx_tkeep;
  assign sim_aurora_tx_tlast        = aurora_tx_tlast;
  assign sim_aurora_tx_tvalid       = aurora_tx_tvalid;
  assign aurora_tx_tready           = sim_aurora_tx_tready;
  // RX streams: testbench → bridge
  assign aurora_rx_tdata            = sim_aurora_rx_tdata;
  assign aurora_rx_tkeep            = sim_aurora_rx_tkeep;
  assign aurora_rx_tlast            = sim_aurora_rx_tlast;
  assign aurora_rx_tvalid           = sim_aurora_rx_tvalid;
  // User-K
  assign sim_aurora_userk_tx_tdata  = aurora_userk_tx_tdata;
  assign sim_aurora_userk_tx_tvalid = aurora_userk_tx_tvalid;
  assign aurora_userk_tx_tready     = sim_aurora_userk_tx_tready;
  assign aurora_userk_rx_tdata      = sim_aurora_userk_rx_tdata;
  assign aurora_userk_rx_tvalid     = sim_aurora_userk_rx_tvalid;
`endif

  // ---------------------------------------------------------------------
  // Bridge runs on aurora_user_clk.  Reset = AND(static-side aresetn
  // synced into user_clk, aurora_user_aresetn).  Simplest sync: feed
  // aresetn directly; aurora_user_aresetn is already glitch-free off
  // sys_reset_out, and the bridge tolerates async assert / sync deassert.
  // ---------------------------------------------------------------------
  reg [2:0] aresetn_user_sync;
  always_ff @(posedge aurora_user_clk or negedge aresetn) begin
    if (!aresetn)
      aresetn_user_sync <= 3'b000;
    else
      aresetn_user_sync <= {aresetn_user_sync[1:0], 1'b1};
  end
  wire bridge_aresetn = aurora_user_aresetn & aresetn_user_sync[2];

  // ---------------------------------------------------------------------
  // AXI4 256 b clock converter — XDMA (aclk, 250 MHz) → bridge (user_clk).
  // ---------------------------------------------------------------------
  wire        bf_awid_w_lo, bf_awvalid, bf_awready;
  // (use direct nets — verbose, but matches the IP's flat port shape)
  // For brevity we expose every signal here as a single wire and pass
  // them straight to the bridge.

  // Slave-side connections to data converter are the partition s_axi_data ports.
  // Master-side (user_clk-domain) wires into the bridge's s_full_* ports.
  wire [3:0]   df_m_awid;
  wire [63:0]  df_m_awaddr;
  wire [7:0]   df_m_awlen;
  wire [2:0]   df_m_awsize;
  wire [1:0]   df_m_awburst;
  wire         df_m_awlock;
  wire [3:0]   df_m_awcache;
  wire [2:0]   df_m_awprot;
  wire [3:0]   df_m_awqos;
  wire [3:0]   df_m_awregion;
  wire         df_m_awvalid;
  wire         df_m_awready;
  wire [255:0] df_m_wdata;
  wire [31:0]  df_m_wstrb;
  wire         df_m_wlast;
  wire         df_m_wvalid;
  wire         df_m_wready;
  wire [3:0]   df_m_bid;
  wire [1:0]   df_m_bresp;
  wire         df_m_bvalid;
  wire         df_m_bready;
  wire [3:0]   df_m_arid;
  wire [63:0]  df_m_araddr;
  wire [7:0]   df_m_arlen;
  wire [2:0]   df_m_arsize;
  wire [1:0]   df_m_arburst;
  wire         df_m_arlock;
  wire [3:0]   df_m_arcache;
  wire [2:0]   df_m_arprot;
  wire [3:0]   df_m_arqos;
  wire [3:0]   df_m_arregion;
  wire         df_m_arvalid;
  wire         df_m_arready;
  wire [3:0]   df_m_rid;
  wire [255:0] df_m_rdata;
  wire [1:0]   df_m_rresp;
  wire         df_m_rlast;
  wire         df_m_rvalid;
  wire         df_m_rready;

  // ---------------------------------------------------------------------
  // Phase-2 host-preload tunnel: in combined_sim, the host-preload
  // path (sim_axi_dma → axi_dma_switch.M02 → s_axi_hbm) is re-routed
  // to feed the aurora bridge instead of terminating at the local
  // axi_crossbar_bram (the chip's BRAM now lives on zcu102).  When
  // PHASE2_HOST_PRELOAD_OVER_AURORA is defined, the CDC's slave port
  // is driven by s_axi_hbm_*; in the default FPGA build it stays
  // wired to s_axi_data_* as before.
  // ---------------------------------------------------------------------
  axi_clock_converter_data u_axi_cdc_data (
    .s_axi_aclk     (aclk),
    .s_axi_aresetn  (aresetn),
`ifdef PHASE2_HOST_PRELOAD_OVER_AURORA
    .s_axi_awid     (s_axi_hbm_awid),
    .s_axi_awaddr   (s_axi_hbm_awaddr),
    .s_axi_awlen    (s_axi_hbm_awlen),
    .s_axi_awsize   (s_axi_hbm_awsize),
    .s_axi_awburst  (s_axi_hbm_awburst),
    .s_axi_awlock   (s_axi_hbm_awlock),
    .s_axi_awcache  (s_axi_hbm_awcache),
    .s_axi_awprot   (s_axi_hbm_awprot),
    .s_axi_awqos    (s_axi_hbm_awqos),
    .s_axi_awregion (s_axi_hbm_awregion),
    .s_axi_awvalid  (s_axi_hbm_awvalid),
    .s_axi_awready  (s_axi_hbm_awready),
    .s_axi_wdata    (s_axi_hbm_wdata),
    .s_axi_wstrb    (s_axi_hbm_wstrb),
    .s_axi_wlast    (s_axi_hbm_wlast),
    .s_axi_wvalid   (s_axi_hbm_wvalid),
    .s_axi_wready   (s_axi_hbm_wready),
    .s_axi_bid      (s_axi_hbm_bid),
    .s_axi_bresp    (s_axi_hbm_bresp),
    .s_axi_bvalid   (s_axi_hbm_bvalid),
    .s_axi_bready   (s_axi_hbm_bready),
    .s_axi_arid     (s_axi_hbm_arid),
    .s_axi_araddr   (s_axi_hbm_araddr),
    .s_axi_arlen    (s_axi_hbm_arlen),
    .s_axi_arsize   (s_axi_hbm_arsize),
    .s_axi_arburst  (s_axi_hbm_arburst),
    .s_axi_arlock   (s_axi_hbm_arlock),
    .s_axi_arcache  (s_axi_hbm_arcache),
    .s_axi_arprot   (s_axi_hbm_arprot),
    .s_axi_arqos    (s_axi_hbm_arqos),
    .s_axi_arregion (s_axi_hbm_arregion),
    .s_axi_arvalid  (s_axi_hbm_arvalid),
    .s_axi_arready  (s_axi_hbm_arready),
    .s_axi_rid      (s_axi_hbm_rid),
    .s_axi_rdata    (s_axi_hbm_rdata),
    .s_axi_rresp    (s_axi_hbm_rresp),
    .s_axi_rlast    (s_axi_hbm_rlast),
    .s_axi_rvalid   (s_axi_hbm_rvalid),
    .s_axi_rready   (s_axi_hbm_rready),
`else
    .s_axi_awid     (s_axi_data_awid),
    .s_axi_awaddr   (s_axi_data_awaddr),
    .s_axi_awlen    (s_axi_data_awlen),
    .s_axi_awsize   (s_axi_data_awsize),
    .s_axi_awburst  (s_axi_data_awburst),
    .s_axi_awlock   (s_axi_data_awlock),
    .s_axi_awcache  (s_axi_data_awcache),
    .s_axi_awprot   (s_axi_data_awprot),
    .s_axi_awqos    (s_axi_data_awqos),
    .s_axi_awregion (s_axi_data_awregion),
    .s_axi_awvalid  (s_axi_data_awvalid),
    .s_axi_awready  (s_axi_data_awready),
    .s_axi_wdata    (s_axi_data_wdata),
    .s_axi_wstrb    (s_axi_data_wstrb),
    .s_axi_wlast    (s_axi_data_wlast),
    .s_axi_wvalid   (s_axi_data_wvalid),
    .s_axi_wready   (s_axi_data_wready),
    .s_axi_bid      (s_axi_data_bid),
    .s_axi_bresp    (s_axi_data_bresp),
    .s_axi_bvalid   (s_axi_data_bvalid),
    .s_axi_bready   (s_axi_data_bready),
    .s_axi_arid     (s_axi_data_arid),
    .s_axi_araddr   (s_axi_data_araddr),
    .s_axi_arlen    (s_axi_data_arlen),
    .s_axi_arsize   (s_axi_data_arsize),
    .s_axi_arburst  (s_axi_data_arburst),
    .s_axi_arlock   (s_axi_data_arlock),
    .s_axi_arcache  (s_axi_data_arcache),
    .s_axi_arprot   (s_axi_data_arprot),
    .s_axi_arqos    (s_axi_data_arqos),
    .s_axi_arregion (s_axi_data_arregion),
    .s_axi_arvalid  (s_axi_data_arvalid),
    .s_axi_arready  (s_axi_data_arready),
    .s_axi_rid      (s_axi_data_rid),
    .s_axi_rdata    (s_axi_data_rdata),
    .s_axi_rresp    (s_axi_data_rresp),
    .s_axi_rlast    (s_axi_data_rlast),
    .s_axi_rvalid   (s_axi_data_rvalid),
    .s_axi_rready   (s_axi_data_rready),
`endif

    .m_axi_aclk     (aurora_user_clk),
    .m_axi_aresetn  (bridge_aresetn),
    .m_axi_awid     (df_m_awid),
    .m_axi_awaddr   (df_m_awaddr),
    .m_axi_awlen    (df_m_awlen),
    .m_axi_awsize   (df_m_awsize),
    .m_axi_awburst  (df_m_awburst),
    .m_axi_awlock   (df_m_awlock),
    .m_axi_awcache  (df_m_awcache),
    .m_axi_awprot   (df_m_awprot),
    .m_axi_awqos    (df_m_awqos),
    .m_axi_awregion (df_m_awregion),
    .m_axi_awvalid  (df_m_awvalid),
    .m_axi_awready  (df_m_awready),
    .m_axi_wdata    (df_m_wdata),
    .m_axi_wstrb    (df_m_wstrb),
    .m_axi_wlast    (df_m_wlast),
    .m_axi_wvalid   (df_m_wvalid),
    .m_axi_wready   (df_m_wready),
    .m_axi_bid      (df_m_bid),
    .m_axi_bresp    (df_m_bresp),
    .m_axi_bvalid   (df_m_bvalid),
    .m_axi_bready   (df_m_bready),
    .m_axi_arid     (df_m_arid),
    .m_axi_araddr   (df_m_araddr),
    .m_axi_arlen    (df_m_arlen),
    .m_axi_arsize   (df_m_arsize),
    .m_axi_arburst  (df_m_arburst),
    .m_axi_arlock   (df_m_arlock),
    .m_axi_arcache  (df_m_arcache),
    .m_axi_arprot   (df_m_arprot),
    .m_axi_arqos    (df_m_arqos),
    .m_axi_arregion (df_m_arregion),
    .m_axi_arvalid  (df_m_arvalid),
    .m_axi_arready  (df_m_arready),
    .m_axi_rid      (df_m_rid),
    .m_axi_rdata    (df_m_rdata),
    .m_axi_rresp    (df_m_rresp),
    .m_axi_rlast    (df_m_rlast),
    .m_axi_rvalid   (df_m_rvalid),
    .m_axi_rready   (df_m_rready)
  );

`ifdef PHASE2_HOST_PRELOAD_OVER_AURORA
  // s_axi_data is unused in this build (s_axi_hbm drives the CDC
  // above instead).  Tie off its slave-side outputs so the partition
  // port still presents a valid AXI4 slave.
  `AXI_SLAVE_TIEOFF(s_axi_data);
`endif

  // ---------------------------------------------------------------------
  // AXI-Lite clock converter — XDMA control (aclk) → bridge (user_clk).
  // ---------------------------------------------------------------------
  wire [31:0]  lf_m_awaddr;
  wire [2:0]   lf_m_awprot;
  wire         lf_m_awvalid;
  wire         lf_m_awready;
  wire [31:0]  lf_m_wdata;
  wire [3:0]   lf_m_wstrb;
  wire         lf_m_wvalid;
  wire         lf_m_wready;
  wire [1:0]   lf_m_bresp;
  wire         lf_m_bvalid;
  wire         lf_m_bready;
  wire [31:0]  lf_m_araddr;
  wire [2:0]   lf_m_arprot;
  wire         lf_m_arvalid;
  wire         lf_m_arready;
  wire [31:0]  lf_m_rdata;
  wire [1:0]   lf_m_rresp;
  wire         lf_m_rvalid;
  wire         lf_m_rready;

  // bridge.s_lite_rdata is DATA_W=128 wide on the bridge side, but
  // XDMA's AXI-Lite is 32-bit.  Truncate the lower 32 bits to feed back
  // through the AXI-Lite clock converter to XDMA.
  wire [127:0] lf_m_rdata_wide;
  assign lf_m_rdata = lf_m_rdata_wide[31:0];

  axi_lite_clock_converter_aurora u_axil_cdc_ctrl (
    .s_axi_aclk     (aclk),
    .s_axi_aresetn  (aresetn),
    .s_axi_awaddr   (s_axil_ctrl_awaddr),
    .s_axi_awprot   (s_axil_ctrl_awprot),
    .s_axi_awvalid  (s_axil_ctrl_awvalid),
    .s_axi_awready  (s_axil_ctrl_awready),
    .s_axi_wdata    (s_axil_ctrl_wdata),
    .s_axi_wstrb    (s_axil_ctrl_wstrb),
    .s_axi_wvalid   (s_axil_ctrl_wvalid),
    .s_axi_wready   (s_axil_ctrl_wready),
    .s_axi_bresp    (s_axil_ctrl_bresp),
    .s_axi_bvalid   (s_axil_ctrl_bvalid),
    .s_axi_bready   (s_axil_ctrl_bready),
    .s_axi_araddr   (s_axil_ctrl_araddr),
    .s_axi_arprot   (s_axil_ctrl_arprot),
    .s_axi_arvalid  (s_axil_ctrl_arvalid),
    .s_axi_arready  (s_axil_ctrl_arready),
    .s_axi_rdata    (s_axil_ctrl_rdata),
    .s_axi_rresp    (s_axil_ctrl_rresp),
    .s_axi_rvalid   (s_axil_ctrl_rvalid),
    .s_axi_rready   (s_axil_ctrl_rready),

    .m_axi_aclk     (aurora_user_clk),
    .m_axi_aresetn  (bridge_aresetn),
    .m_axi_awaddr   (lf_m_awaddr),
    .m_axi_awprot   (lf_m_awprot),
    .m_axi_awvalid  (lf_m_awvalid),
    .m_axi_awready  (lf_m_awready),
    .m_axi_wdata    (lf_m_wdata),
    .m_axi_wstrb    (lf_m_wstrb),
    .m_axi_wvalid   (lf_m_wvalid),
    .m_axi_wready   (lf_m_wready),
    .m_axi_bresp    (lf_m_bresp),
    .m_axi_bvalid   (lf_m_bvalid),
    .m_axi_bready   (lf_m_bready),
    .m_axi_araddr   (lf_m_araddr),
    .m_axi_arprot   (lf_m_arprot),
    .m_axi_arvalid  (lf_m_arvalid),
    .m_axi_arready  (lf_m_arready),
    .m_axi_rdata    (lf_m_rdata),
    .m_axi_rresp    (lf_m_rresp),
    .m_axi_rvalid   (lf_m_rvalid),
    .m_axi_rready   (lf_m_rready)
  );

  // s_axil_ctrl carries AXI4 ID / LEN fields that the AXI-Lite converter
  // doesn't read.  Drive zero-return on the response channels so the
  // partition boundary stays a valid AXI4 slave.
  assign s_axil_ctrl_bid     = '0;
  assign s_axil_ctrl_rid     = '0;
  assign s_axil_ctrl_rlast   = 1'b1;

  // ---------------------------------------------------------------------
  // axi_dwidth_xdma_to_bridge — widen the XDMA-side 256 b AXI4 up to
  // the bridge's 512 b s_full slave (bridge DATA_W is harmonised with
  // the zcu102 endpoint at 512; see u_bridge instantiation below).
  // ---------------------------------------------------------------------
  wire [3:0]   bd_s_awid;
  wire [63:0]  bd_s_awaddr;
  wire [7:0]   bd_s_awlen;
  wire [2:0]   bd_s_awsize;
  wire [1:0]   bd_s_awburst;
  wire [3:0]   bd_s_awcache;
  wire [2:0]   bd_s_awprot;
  wire         bd_s_awvalid;
  wire         bd_s_awready;
  wire [511:0] bd_s_wdata;
  wire [63:0]  bd_s_wstrb;
  wire         bd_s_wlast;
  wire         bd_s_wvalid;
  wire         bd_s_wready;
  wire [3:0]   bd_s_bid;
  wire [1:0]   bd_s_bresp;
  wire         bd_s_bvalid;
  wire         bd_s_bready;
  wire [3:0]   bd_s_arid;
  wire [63:0]  bd_s_araddr;
  wire [7:0]   bd_s_arlen;
  wire [2:0]   bd_s_arsize;
  wire [1:0]   bd_s_arburst;
  wire [3:0]   bd_s_arcache;
  wire [2:0]   bd_s_arprot;
  wire         bd_s_arvalid;
  wire         bd_s_arready;
  wire [3:0]   bd_s_rid;
  wire [511:0] bd_s_rdata;
  wire [1:0]   bd_s_rresp;
  wire         bd_s_rlast;
  wire         bd_s_rvalid;
  wire         bd_s_rready;

  axi_dwidth_xdma_to_bridge u_dwidth_xdma (
    .s_axi_aclk     (aurora_user_clk),
    .s_axi_aresetn  (bridge_aresetn),
    .s_axi_awid     (df_m_awid),
    .s_axi_awaddr   (df_m_awaddr),
    .s_axi_awlen    (df_m_awlen),
    .s_axi_awsize   (df_m_awsize),
    .s_axi_awburst  (df_m_awburst),
    .s_axi_awlock   (1'b0),
    .s_axi_awcache  (df_m_awcache),
    .s_axi_awprot   (df_m_awprot),
    .s_axi_awregion (4'b0),
    .s_axi_awqos    (4'b0),
    .s_axi_awvalid  (df_m_awvalid),
    .s_axi_awready  (df_m_awready),
    .s_axi_wdata    (df_m_wdata),
    .s_axi_wstrb    (df_m_wstrb),
    .s_axi_wlast    (df_m_wlast),
    .s_axi_wvalid   (df_m_wvalid),
    .s_axi_wready   (df_m_wready),
    .s_axi_bid      (df_m_bid),
    .s_axi_bresp    (df_m_bresp),
    .s_axi_bvalid   (df_m_bvalid),
    .s_axi_bready   (df_m_bready),
    .s_axi_arid     (df_m_arid),
    .s_axi_araddr   (df_m_araddr),
    .s_axi_arlen    (df_m_arlen),
    .s_axi_arsize   (df_m_arsize),
    .s_axi_arburst  (df_m_arburst),
    .s_axi_arlock   (1'b0),
    .s_axi_arcache  (df_m_arcache),
    .s_axi_arprot   (df_m_arprot),
    .s_axi_arregion (4'b0),
    .s_axi_arqos    (4'b0),
    .s_axi_arvalid  (df_m_arvalid),
    .s_axi_arready  (df_m_arready),
    .s_axi_rid      (df_m_rid),
    .s_axi_rdata    (df_m_rdata),
    .s_axi_rresp    (df_m_rresp),
    .s_axi_rlast    (df_m_rlast),
    .s_axi_rvalid   (df_m_rvalid),
    .s_axi_rready   (df_m_rready),

    .m_axi_awaddr   (bd_s_awaddr),
    .m_axi_awlen    (bd_s_awlen),
    .m_axi_awsize   (bd_s_awsize),
    .m_axi_awburst  (bd_s_awburst),
    .m_axi_awlock   (),
    .m_axi_awcache  (bd_s_awcache),
    .m_axi_awprot   (bd_s_awprot),
    .m_axi_awregion (),
    .m_axi_awqos    (),
    .m_axi_awvalid  (bd_s_awvalid),
    .m_axi_awready  (bd_s_awready),
    .m_axi_wdata    (bd_s_wdata),
    .m_axi_wstrb    (bd_s_wstrb),
    .m_axi_wlast    (bd_s_wlast),
    .m_axi_wvalid   (bd_s_wvalid),
    .m_axi_wready   (bd_s_wready),
    .m_axi_bresp    (bd_s_bresp),
    .m_axi_bvalid   (bd_s_bvalid),
    .m_axi_bready   (bd_s_bready),
    .m_axi_araddr   (bd_s_araddr),
    .m_axi_arlen    (bd_s_arlen),
    .m_axi_arsize   (bd_s_arsize),
    .m_axi_arburst  (bd_s_arburst),
    .m_axi_arlock   (),
    .m_axi_arcache  (bd_s_arcache),
    .m_axi_arprot   (bd_s_arprot),
    .m_axi_arregion (),
    .m_axi_arqos    (),
    .m_axi_arvalid  (bd_s_arvalid),
    .m_axi_arready  (bd_s_arready),
    .m_axi_rdata    (bd_s_rdata),
    .m_axi_rresp    (bd_s_rresp),
    .m_axi_rlast    (bd_s_rlast),
    .m_axi_rvalid   (bd_s_rvalid),
    .m_axi_rready   (bd_s_rready)
  );
  // The dwidth converter drops the AXI4 ID on the master side (its
  // single-master output doesn't propagate IDs through).  The bridge
  // tracks IDs internally; tie its s_full ID inputs to 0 — XDMA's
  // single-outstanding read scheme on this path makes that safe.
  assign bd_s_bid = '0;
  assign bd_s_rid = '0;

  // ---------------------------------------------------------------------
  // Bridge m_* wires (AXI4, 128 b — matches bridge DATA_W=128).  These
  // MUST be declared BEFORE the axi_aurora_bridge_inv instantiation
  // below — otherwise Verilog implicitly creates 1-bit nets at the
  // port-mapping point and silently drops the upper bits, which is
  // notoriously hard to debug (was a real bug discovered via TB
  // probing: addr 0x80 / data 0xf00d...def0 / strb 0xFFFF arrived at
  // the dwidth converter as 0 / 0 / 0x0001 — exactly the bit-0 of each
  // wide signal).
  // ---------------------------------------------------------------------
  // Widths now match the harmonised bridge parameters
  // (ADDR_W=32, DATA_W=512, ID_W=18) — see the bridge instantiation
  // below.  The address slice stays 64 b on this side and is
  // truncated at the bridge port; ID is widened from 4 → 18 to match
  // zcu102's L3_MEM_TAG_WIDTH (with UUID_WIDTH=12).
  wire [19:0]  br_m_awid;
  wire [31:0]  br_m_awaddr;
  wire [7:0]   br_m_awlen;
  wire [2:0]   br_m_awsize;
  wire [1:0]   br_m_awburst;
  wire [3:0]   br_m_awcache;
  wire [2:0]   br_m_awprot;
  wire         br_m_awvalid;
  wire         br_m_awready;
  wire [511:0] br_m_wdata;
  wire [63:0]  br_m_wstrb;
  wire         br_m_wlast;
  wire         br_m_wvalid;
  wire         br_m_wready;
  wire [19:0]  br_m_bid;
  wire [1:0]   br_m_bresp;
  wire         br_m_bvalid;
  wire         br_m_bready;
  wire [19:0]  br_m_arid;
  wire [31:0]  br_m_araddr;
  wire [7:0]   br_m_arlen;
  wire [2:0]   br_m_arsize;
  wire [1:0]   br_m_arburst;
  wire [3:0]   br_m_arcache;
  wire [2:0]   br_m_arprot;
  wire         br_m_arvalid;
  wire         br_m_arready;
  wire [19:0]  br_m_rid;
  wire [511:0] br_m_rdata;
  wire [1:0]   br_m_rresp;
  wire         br_m_rlast;
  wire         br_m_rvalid;
  wire         br_m_rready;

  // ---------------------------------------------------------------------
  // axi_aurora_bridge_inv — host-side bridge.  AXI4 master output flows
  // out to a 512→256 dwidth converter and then an aurora_user_clk→aclk
  // CDC, terminating at axi_crossbar_bram.SI[0].
  // ---------------------------------------------------------------------
  axi_aurora_bridge_inv #(
    // Harmonised with zcu102. zcu102's bridge uses ID_W =
    // AXI_TAG_WIDTH = L3_MEM_TAG_WIDTH. With Vortex's default
    // UUID_WIDTH=44 this evaluates to 50, exceeding the 32-bit cap on
    // the downstream axi_dwidth_converter / axi_crossbar IPs. The
    // combined_sim build defines UUID_WIDTH=12 (see combined_sim/
    // scripts/create_project.tcl), which brings L3_MEM_TAG_WIDTH down
    // to 18 — small enough for the IP cap, large enough to preserve
    // zcu102's 14-bit dispatcher routing tag.
    .ADDR_W (32),
    .DATA_W (512),
    .ID_W   (20)
  ) u_bridge (
    .aclk    (aurora_user_clk),
    .aresetn (bridge_aresetn),

    // AXI4-Full slave (from XDMA data path, post-CDC + post-dwidth)
    .s_full_awid    (4'b0),
    .s_full_awaddr  (bd_s_awaddr),
    .s_full_awlen   (bd_s_awlen),
    .s_full_awsize  (bd_s_awsize),
    .s_full_awburst (bd_s_awburst),
    .s_full_awcache (bd_s_awcache),
    .s_full_awprot  (bd_s_awprot),
    .s_full_awvalid (bd_s_awvalid),
    .s_full_awready (bd_s_awready),
    .s_full_wdata   (bd_s_wdata),
    .s_full_wstrb   (bd_s_wstrb),
    .s_full_wlast   (bd_s_wlast),
    .s_full_wvalid  (bd_s_wvalid),
    .s_full_wready  (bd_s_wready),
    .s_full_bid     (bd_s_bid),
    .s_full_bresp   (bd_s_bresp),
    .s_full_bvalid  (bd_s_bvalid),
    .s_full_bready  (bd_s_bready),
    .s_full_arid    (4'b0),
    .s_full_araddr  (bd_s_araddr),
    .s_full_arlen   (bd_s_arlen),
    .s_full_arsize  (bd_s_arsize),
    .s_full_arburst (bd_s_arburst),
    .s_full_arcache (bd_s_arcache),
    .s_full_arprot  (bd_s_arprot),
    .s_full_arvalid (bd_s_arvalid),
    .s_full_arready (bd_s_arready),
    .s_full_rid     (bd_s_rid),
    .s_full_rdata   (bd_s_rdata),
    .s_full_rresp   (bd_s_rresp),
    .s_full_rlast   (bd_s_rlast),
    .s_full_rvalid  (bd_s_rvalid),
    .s_full_rready  (bd_s_rready),

    // AXI-Lite slave (from XDMA AXI-Lite, after CDC)
    .s_lite_awaddr  (lf_m_awaddr),
    .s_lite_awprot  (lf_m_awprot),
    .s_lite_awvalid (lf_m_awvalid),
    .s_lite_awready (lf_m_awready),
    .s_lite_wdata   ({96'h0, lf_m_wdata}),   // pad 32 → DATA_W=128
    .s_lite_wstrb   ({12'h0, lf_m_wstrb}),   // pad 4 → STRB_W=16
    .s_lite_wvalid  (lf_m_wvalid),
    .s_lite_wready  (lf_m_wready),
    .s_lite_bresp   (lf_m_bresp),
    .s_lite_bvalid  (lf_m_bvalid),
    .s_lite_bready  (lf_m_bready),
    .s_lite_araddr  (lf_m_araddr),
    .s_lite_arprot  (lf_m_arprot),
    .s_lite_arvalid (lf_m_arvalid),
    .s_lite_arready (lf_m_arready),
    .s_lite_rdata   (lf_m_rdata_wide),       // upper 96 bits truncated above
    .s_lite_rresp   (lf_m_rresp),
    .s_lite_rvalid  (lf_m_rvalid),
    .s_lite_rready  (lf_m_rready),

    // AXI4-Full master output — far-end-originated traffic lands on
    // axi_crossbar_bram.SI[0] after a 512→256 dwidth converter and an
    // aurora_user_clk → aclk CDC.
    .m_awid     (br_m_awid),
    .m_awaddr   (br_m_awaddr),
    .m_awlen    (br_m_awlen),
    .m_awsize   (br_m_awsize),
    .m_awburst  (br_m_awburst),
    .m_awcache  (br_m_awcache),
    .m_awprot   (br_m_awprot),
    .m_awvalid  (br_m_awvalid),
    .m_awready  (br_m_awready),
    .m_wdata    (br_m_wdata),
    .m_wstrb    (br_m_wstrb),
    .m_wlast    (br_m_wlast),
    .m_wvalid   (br_m_wvalid),
    .m_wready   (br_m_wready),
    .m_bid      (br_m_bid),
    .m_bresp    (br_m_bresp),
    .m_bvalid   (br_m_bvalid),
    .m_bready   (br_m_bready),
    .m_arid     (br_m_arid),
    .m_araddr   (br_m_araddr),
    .m_arlen    (br_m_arlen),
    .m_arsize   (br_m_arsize),
    .m_arburst  (br_m_arburst),
    .m_arcache  (br_m_arcache),
    .m_arprot   (br_m_arprot),
    .m_arvalid  (br_m_arvalid),
    .m_arready  (br_m_arready),
    .m_rid      (br_m_rid),
    .m_rdata    (br_m_rdata),
    .m_rresp    (br_m_rresp),
    .m_rlast    (br_m_rlast),
    .m_rvalid   (br_m_rvalid),
    .m_rready   (br_m_rready),

    // Aurora user-side streams
    .tx_data_tdata   (aurora_tx_tdata),
    .tx_data_tkeep   (aurora_tx_tkeep),
    .tx_data_tlast   (aurora_tx_tlast),
    .tx_data_tvalid  (aurora_tx_tvalid),
    .tx_data_tready  (aurora_tx_tready),

    .rx_data_tdata   (aurora_rx_tdata),
    .rx_data_tkeep   (aurora_rx_tkeep),
    .rx_data_tlast   (aurora_rx_tlast),
    .rx_data_tvalid  (aurora_rx_tvalid),

    .tx_userk_tdata  (aurora_userk_tx_tdata),
    .tx_userk_tvalid (aurora_userk_tx_tvalid),
    .tx_userk_tready (aurora_userk_tx_tready),

    .rx_userk_tdata  (aurora_userk_rx_tdata),
    .rx_userk_tvalid (aurora_userk_rx_tvalid)
  );

  // ---------------------------------------------------------------------
  // Bridge m_* (AXI4 512 b, 16-bit ID, 8-bit AWLEN, aurora_user_clk) →
  // axi_dwidth_bridge_to_hbm → AXI4 256 b (pcs_*) → axi_clock_converter_bram
  // → axi_crossbar_bram.SI[0].  All AXI4 — no protocol conversion needed
  // since the BRAM controller is natively AXI4.  The dwidth converter
  // drops IDs on its master side, so AWID/ARID land at 0 downstream.
  // ---------------------------------------------------------------------
  // (br_m_* wires now declared above, before the bridge_inv
  //  instantiation, to avoid implicit 1-bit net creation.)

  // axi_dwidth_bridge_to_hbm master-side wires (AXI4 256 b, aurora_user_clk).
  wire [63:0]  pcs_awaddr;
  wire [7:0]   pcs_awlen;
  wire [2:0]   pcs_awsize;
  wire [1:0]   pcs_awburst;
  wire [3:0]   pcs_awcache;
  wire [2:0]   pcs_awprot;
  wire         pcs_awvalid;
  wire         pcs_awready;
  wire [255:0] pcs_wdata;
  wire [31:0]  pcs_wstrb;
  wire         pcs_wlast;
  wire         pcs_wvalid;
  wire         pcs_wready;
  wire [1:0]   pcs_bresp;
  wire         pcs_bvalid;
  wire         pcs_bready;
  wire [63:0]  pcs_araddr;
  wire [7:0]   pcs_arlen;
  wire [2:0]   pcs_arsize;
  wire [1:0]   pcs_arburst;
  wire [3:0]   pcs_arcache;
  wire [2:0]   pcs_arprot;
  wire         pcs_arvalid;
  wire         pcs_arready;
  wire [255:0] pcs_rdata;
  wire [1:0]   pcs_rresp;
  wire         pcs_rlast;
  wire         pcs_rvalid;
  wire         pcs_rready;

  axi_dwidth_bridge_to_hbm u_dwidth_hbm (
    .s_axi_aclk     (aurora_user_clk),
    .s_axi_aresetn  (bridge_aresetn),
    .s_axi_awid     (br_m_awid),
    .s_axi_awaddr   (br_m_awaddr),
    .s_axi_awlen    (br_m_awlen),
    .s_axi_awsize   (br_m_awsize),
    .s_axi_awburst  (br_m_awburst),
    .s_axi_awlock   (1'b0),
    .s_axi_awcache  (br_m_awcache),
    .s_axi_awprot   (br_m_awprot),
    .s_axi_awregion (4'b0),
    .s_axi_awqos    (4'b0),
    .s_axi_awvalid  (br_m_awvalid),
    .s_axi_awready  (br_m_awready),
    .s_axi_wdata    (br_m_wdata),
    .s_axi_wstrb    (br_m_wstrb),
    .s_axi_wlast    (br_m_wlast),
    .s_axi_wvalid   (br_m_wvalid),
    .s_axi_wready   (br_m_wready),
    .s_axi_bid      (br_m_bid),
    .s_axi_bresp    (br_m_bresp),
    .s_axi_bvalid   (br_m_bvalid),
    .s_axi_bready   (br_m_bready),
    .s_axi_arid     (br_m_arid),
    .s_axi_araddr   (br_m_araddr),
    .s_axi_arlen    (br_m_arlen),
    .s_axi_arsize   (br_m_arsize),
    .s_axi_arburst  (br_m_arburst),
    .s_axi_arlock   (1'b0),
    .s_axi_arcache  (br_m_arcache),
    .s_axi_arprot   (br_m_arprot),
    .s_axi_arregion (4'b0),
    .s_axi_arqos    (4'b0),
    .s_axi_arvalid  (br_m_arvalid),
    .s_axi_arready  (br_m_arready),
    .s_axi_rid      (br_m_rid),
    .s_axi_rdata    (br_m_rdata),
    .s_axi_rresp    (br_m_rresp),
    .s_axi_rlast    (br_m_rlast),
    .s_axi_rvalid   (br_m_rvalid),
    .s_axi_rready   (br_m_rready),

    .m_axi_awaddr   (pcs_awaddr),
    .m_axi_awlen    (pcs_awlen),
    .m_axi_awsize   (pcs_awsize),
    .m_axi_awburst  (pcs_awburst),
    .m_axi_awlock   (),
    .m_axi_awcache  (pcs_awcache),
    .m_axi_awprot   (pcs_awprot),
    .m_axi_awregion (),
    .m_axi_awqos    (),
    .m_axi_awvalid  (pcs_awvalid),
    .m_axi_awready  (pcs_awready),
    .m_axi_wdata    (pcs_wdata),
    .m_axi_wstrb    (pcs_wstrb),
    .m_axi_wlast    (pcs_wlast),
    .m_axi_wvalid   (pcs_wvalid),
    .m_axi_wready   (pcs_wready),
    .m_axi_bresp    (pcs_bresp),
    .m_axi_bvalid   (pcs_bvalid),
    .m_axi_bready   (pcs_bready),
    .m_axi_araddr   (pcs_araddr),
    .m_axi_arlen    (pcs_arlen),
    .m_axi_arsize   (pcs_arsize),
    .m_axi_arburst  (pcs_arburst),
    .m_axi_arlock   (),
    .m_axi_arcache  (pcs_arcache),
    .m_axi_arprot   (pcs_arprot),
    .m_axi_arregion (),
    .m_axi_arqos    (),
    .m_axi_arvalid  (pcs_arvalid),
    .m_axi_arready  (pcs_arready),
    .m_axi_rdata    (pcs_rdata),
    .m_axi_rresp    (pcs_rresp),
    .m_axi_rlast    (pcs_rlast),
    .m_axi_rvalid   (pcs_rvalid),
    .m_axi_rready   (pcs_rready)
  );

  // ---------------------------------------------------------------------
  // Aurora-bridge return → BRAM crossbar SI[0].
  //
  //   axi_dwidth_bridge_to_hbm.m_*      (AXI4 256 b, aurora_user_clk)
  //   → axi_clock_converter_bram        (aurora_user_clk → aclk)
  //   → axi_crossbar_bram.SI[0]         (AXI4 256 b, aclk)
  //
  // No protocol converter (BRAM is native AXI4); no deep data FIFO (BRAM
  // completes every beat in 1 cycle, so back-to-back writes don't race).
  // ---------------------------------------------------------------------
  wire [3:0]   cdc_out_awid;
  wire [63:0]  cdc_out_awaddr;
  wire [7:0]   cdc_out_awlen;
  wire [2:0]   cdc_out_awsize;
  wire [1:0]   cdc_out_awburst;
  wire         cdc_out_awlock;
  wire [3:0]   cdc_out_awcache;
  wire [2:0]   cdc_out_awprot;
  wire         cdc_out_awvalid;
  wire         cdc_out_awready;
  wire [255:0] cdc_out_wdata;
  wire [31:0]  cdc_out_wstrb;
  wire         cdc_out_wlast;
  wire         cdc_out_wvalid;
  wire         cdc_out_wready;
  wire [3:0]   cdc_out_bid;
  wire [1:0]   cdc_out_bresp;
  wire         cdc_out_bvalid;
  wire         cdc_out_bready;
  wire [3:0]   cdc_out_arid;
  wire [63:0]  cdc_out_araddr;
  wire [7:0]   cdc_out_arlen;
  wire [2:0]   cdc_out_arsize;
  wire [1:0]   cdc_out_arburst;
  wire         cdc_out_arlock;
  wire [3:0]   cdc_out_arcache;
  wire [2:0]   cdc_out_arprot;
  wire         cdc_out_arvalid;
  wire         cdc_out_arready;
  wire [3:0]   cdc_out_rid;
  wire [255:0] cdc_out_rdata;
  wire [1:0]   cdc_out_rresp;
  wire         cdc_out_rlast;
  wire         cdc_out_rvalid;
  wire         cdc_out_rready;

  axi_clock_converter_bram u_cdc_bram (
    // ----- Slave side: AXI4 256 b on aurora_user_clk, from the
    //       axi_dwidth_bridge_to_hbm master output (pcs_*).  The dwidth
    //       converter drops the ID on its master side, so AWID/ARID
    //       fall in at 0.
    .s_axi_aclk     (aurora_user_clk),
    .s_axi_aresetn  (bridge_aresetn),
    .s_axi_awid     (4'b0),
    .s_axi_awaddr   (pcs_awaddr),
    .s_axi_awlen    (pcs_awlen),
    .s_axi_awsize   (pcs_awsize),
    .s_axi_awburst  (pcs_awburst),
    .s_axi_awlock   (1'b0),
    .s_axi_awcache  (pcs_awcache),
    .s_axi_awprot   (pcs_awprot),
    .s_axi_awvalid  (pcs_awvalid),
    .s_axi_awready  (pcs_awready),
    .s_axi_wdata    (pcs_wdata),
    .s_axi_wstrb    (pcs_wstrb),
    .s_axi_wlast    (pcs_wlast),
    .s_axi_wvalid   (pcs_wvalid),
    .s_axi_wready   (pcs_wready),
    .s_axi_bid      (),
    .s_axi_bresp    (pcs_bresp),
    .s_axi_bvalid   (pcs_bvalid),
    .s_axi_bready   (pcs_bready),
    .s_axi_arid     (4'b0),
    .s_axi_araddr   (pcs_araddr),
    .s_axi_arlen    (pcs_arlen),
    .s_axi_arsize   (pcs_arsize),
    .s_axi_arburst  (pcs_arburst),
    .s_axi_arlock   (1'b0),
    .s_axi_arcache  (pcs_arcache),
    .s_axi_arprot   (pcs_arprot),
    .s_axi_arvalid  (pcs_arvalid),
    .s_axi_arready  (pcs_arready),
    .s_axi_rid      (),
    .s_axi_rdata    (pcs_rdata),
    .s_axi_rresp    (pcs_rresp),
    .s_axi_rlast    (pcs_rlast),
    .s_axi_rvalid   (pcs_rvalid),
    .s_axi_rready   (pcs_rready),

    // ----- Master side: aclk-domain output → crossbar SI[0].
    .m_axi_aclk     (aclk),
    .m_axi_aresetn  (aresetn),
    .m_axi_awid     (cdc_out_awid),
    .m_axi_awaddr   (cdc_out_awaddr),
    .m_axi_awlen    (cdc_out_awlen),
    .m_axi_awsize   (cdc_out_awsize),
    .m_axi_awburst  (cdc_out_awburst),
    .m_axi_awlock   (cdc_out_awlock),
    .m_axi_awcache  (cdc_out_awcache),
    .m_axi_awprot   (cdc_out_awprot),
    .m_axi_awvalid  (cdc_out_awvalid),
    .m_axi_awready  (cdc_out_awready),
    .m_axi_wdata    (cdc_out_wdata),
    .m_axi_wstrb    (cdc_out_wstrb),
    .m_axi_wlast    (cdc_out_wlast),
    .m_axi_wvalid   (cdc_out_wvalid),
    .m_axi_wready   (cdc_out_wready),
    .m_axi_bid      (cdc_out_bid),
    .m_axi_bresp    (cdc_out_bresp),
    .m_axi_bvalid   (cdc_out_bvalid),
    .m_axi_bready   (cdc_out_bready),
    .m_axi_arid     (cdc_out_arid),
    .m_axi_araddr   (cdc_out_araddr),
    .m_axi_arlen    (cdc_out_arlen),
    .m_axi_arsize   (cdc_out_arsize),
    .m_axi_arburst  (cdc_out_arburst),
    .m_axi_arlock   (cdc_out_arlock),
    .m_axi_arcache  (cdc_out_arcache),
    .m_axi_arprot   (cdc_out_arprot),
    .m_axi_arvalid  (cdc_out_arvalid),
    .m_axi_arready  (cdc_out_arready),
    .m_axi_rid      (cdc_out_rid),
    .m_axi_rdata    (cdc_out_rdata),
    .m_axi_rresp    (cdc_out_rresp),
    .m_axi_rlast    (cdc_out_rlast),
    .m_axi_rvalid   (cdc_out_rvalid),
    .m_axi_rready   (cdc_out_rready)
  );

  // ---------------------------------------------------------------------
  // 2:1 AXI4 crossbar → 64 KB BRAM controller.
  //
  //   SI[0] = cdc_out_*   (aurora-bridge return, AXI4 256 b, aclk)
  //   SI[1] = s_axi_hbm_* (XDMA direct, AXI4 256 b, aclk) — historical
  //           port name; nothing HBM-specific behind it now.
  //   MI    = axi_bram_ctrl_bram (AXI4 256 b, internal 64 KB BMG)
  //
  // ID widens 4 → 5 (NUM_SI=2 → log2=1).  Address sliced 64 → 16 b at
  // the bram_ctrl input — upper bits don't matter (64 KB needs 16).
  // ---------------------------------------------------------------------
  wire [4:0]   xb_m_axi_awid;
  wire [63:0]  xb_m_axi_awaddr;
  wire [7:0]   xb_m_axi_awlen;
  wire [2:0]   xb_m_axi_awsize;
  wire [1:0]   xb_m_axi_awburst;
  wire         xb_m_axi_awlock;
  wire [3:0]   xb_m_axi_awcache;
  wire [2:0]   xb_m_axi_awprot;
  wire [3:0]   xb_m_axi_awqos;
  wire         xb_m_axi_awvalid;
  wire         xb_m_axi_awready;
  wire [255:0] xb_m_axi_wdata;
  wire [31:0]  xb_m_axi_wstrb;
  wire         xb_m_axi_wlast;
  wire         xb_m_axi_wvalid;
  wire         xb_m_axi_wready;
  wire [4:0]   xb_m_axi_bid;
  wire [1:0]   xb_m_axi_bresp;
  wire         xb_m_axi_bvalid;
  wire         xb_m_axi_bready;
  wire [4:0]   xb_m_axi_arid;
  wire [63:0]  xb_m_axi_araddr;
  wire [7:0]   xb_m_axi_arlen;
  wire [2:0]   xb_m_axi_arsize;
  wire [1:0]   xb_m_axi_arburst;
  wire         xb_m_axi_arlock;
  wire [3:0]   xb_m_axi_arcache;
  wire [2:0]   xb_m_axi_arprot;
  wire [3:0]   xb_m_axi_arqos;
  wire         xb_m_axi_arvalid;
  wire         xb_m_axi_arready;
  wire [4:0]   xb_m_axi_rid;
  wire [255:0] xb_m_axi_rdata;
  wire [1:0]   xb_m_axi_rresp;
  wire         xb_m_axi_rlast;
  wire         xb_m_axi_rvalid;
  wire         xb_m_axi_rready;

  // Phase-2: s_axi_hbm is consumed by the bridge CDC (see top of file)
  // so its connection to crossbar SI[1] is replaced by an inactive
  // tie-off here.  Shadow wires `xb_si1_*` mux between the live HBM
  // master and zero based on PHASE2_HOST_PRELOAD_OVER_AURORA so the
  // crossbar instantiation below stays a single block.
  wire [3:0]   xb_si1_awid;
  wire [63:0]  xb_si1_awaddr;
  wire [7:0]   xb_si1_awlen;
  wire [2:0]   xb_si1_awsize;
  wire [1:0]   xb_si1_awburst;
  wire         xb_si1_awlock;
  wire [3:0]   xb_si1_awcache;
  wire [2:0]   xb_si1_awprot;
  wire [3:0]   xb_si1_awqos;
  wire         xb_si1_awvalid;
  wire         xb_si1_awready;
  wire [255:0] xb_si1_wdata;
  wire [31:0]  xb_si1_wstrb;
  wire         xb_si1_wlast;
  wire         xb_si1_wvalid;
  wire         xb_si1_wready;
  wire [3:0]   xb_si1_bid;
  wire [1:0]   xb_si1_bresp;
  wire         xb_si1_bvalid;
  wire         xb_si1_bready;
  wire [3:0]   xb_si1_arid;
  wire [63:0]  xb_si1_araddr;
  wire [7:0]   xb_si1_arlen;
  wire [2:0]   xb_si1_arsize;
  wire [1:0]   xb_si1_arburst;
  wire         xb_si1_arlock;
  wire [3:0]   xb_si1_arcache;
  wire [2:0]   xb_si1_arprot;
  wire [3:0]   xb_si1_arqos;
  wire         xb_si1_arvalid;
  wire         xb_si1_arready;
  wire [3:0]   xb_si1_rid;
  wire [255:0] xb_si1_rdata;
  wire [1:0]   xb_si1_rresp;
  wire         xb_si1_rlast;
  wire         xb_si1_rvalid;
  wire         xb_si1_rready;
`ifdef PHASE2_HOST_PRELOAD_OVER_AURORA
  // Inactive — s_axi_hbm goes to the bridge, not here.
  assign xb_si1_awid    = '0;
  assign xb_si1_awaddr  = '0;
  assign xb_si1_awlen   = '0;
  assign xb_si1_awsize  = '0;
  assign xb_si1_awburst = '0;
  assign xb_si1_awlock  = 1'b0;
  assign xb_si1_awcache = '0;
  assign xb_si1_awprot  = '0;
  assign xb_si1_awqos   = '0;
  assign xb_si1_awvalid = 1'b0;
  assign xb_si1_wdata   = '0;
  assign xb_si1_wstrb   = '0;
  assign xb_si1_wlast   = 1'b0;
  assign xb_si1_wvalid  = 1'b0;
  assign xb_si1_bready  = 1'b1;
  assign xb_si1_arid    = '0;
  assign xb_si1_araddr  = '0;
  assign xb_si1_arlen   = '0;
  assign xb_si1_arsize  = '0;
  assign xb_si1_arburst = '0;
  assign xb_si1_arlock  = 1'b0;
  assign xb_si1_arcache = '0;
  assign xb_si1_arprot  = '0;
  assign xb_si1_arqos   = '0;
  assign xb_si1_arvalid = 1'b0;
  assign xb_si1_rready  = 1'b1;
`else
  assign xb_si1_awid    = s_axi_hbm_awid;
  assign xb_si1_awaddr  = s_axi_hbm_awaddr;
  assign xb_si1_awlen   = s_axi_hbm_awlen;
  assign xb_si1_awsize  = s_axi_hbm_awsize;
  assign xb_si1_awburst = s_axi_hbm_awburst;
  assign xb_si1_awlock  = s_axi_hbm_awlock;
  assign xb_si1_awcache = s_axi_hbm_awcache;
  assign xb_si1_awprot  = s_axi_hbm_awprot;
  assign xb_si1_awqos   = s_axi_hbm_awqos;
  assign xb_si1_awvalid = s_axi_hbm_awvalid;
  assign s_axi_hbm_awready = xb_si1_awready;
  assign xb_si1_wdata   = s_axi_hbm_wdata;
  assign xb_si1_wstrb   = s_axi_hbm_wstrb;
  assign xb_si1_wlast   = s_axi_hbm_wlast;
  assign xb_si1_wvalid  = s_axi_hbm_wvalid;
  assign s_axi_hbm_wready = xb_si1_wready;
  assign s_axi_hbm_bid    = xb_si1_bid;
  assign s_axi_hbm_bresp  = xb_si1_bresp;
  assign s_axi_hbm_bvalid = xb_si1_bvalid;
  assign xb_si1_bready  = s_axi_hbm_bready;
  assign xb_si1_arid    = s_axi_hbm_arid;
  assign xb_si1_araddr  = s_axi_hbm_araddr;
  assign xb_si1_arlen   = s_axi_hbm_arlen;
  assign xb_si1_arsize  = s_axi_hbm_arsize;
  assign xb_si1_arburst = s_axi_hbm_arburst;
  assign xb_si1_arlock  = s_axi_hbm_arlock;
  assign xb_si1_arcache = s_axi_hbm_arcache;
  assign xb_si1_arprot  = s_axi_hbm_arprot;
  assign xb_si1_arqos   = s_axi_hbm_arqos;
  assign xb_si1_arvalid = s_axi_hbm_arvalid;
  assign s_axi_hbm_arready = xb_si1_arready;
  assign s_axi_hbm_rid    = xb_si1_rid;
  assign s_axi_hbm_rdata  = xb_si1_rdata;
  assign s_axi_hbm_rresp  = xb_si1_rresp;
  assign s_axi_hbm_rlast  = xb_si1_rlast;
  assign s_axi_hbm_rvalid = xb_si1_rvalid;
  assign xb_si1_rready  = s_axi_hbm_rready;
`endif

  axi_crossbar_bram u_xbar_bram (
    .aclk     (aclk),
    .aresetn  (aresetn),

    // SI = {SI[1]=xb_si1_*, SI[0]=cdc_out_*} per Xilinx concat order.
    // SI[1] is muxed between s_axi_hbm (default) and inactive (PHASE2).
    .s_axi_awid     ({xb_si1_awid,        cdc_out_awid}),
    .s_axi_awaddr   ({xb_si1_awaddr,      cdc_out_awaddr}),
    .s_axi_awlen    ({xb_si1_awlen,       cdc_out_awlen}),
    .s_axi_awsize   ({xb_si1_awsize,      cdc_out_awsize}),
    .s_axi_awburst  ({xb_si1_awburst,     cdc_out_awburst}),
    .s_axi_awlock   ({xb_si1_awlock,      cdc_out_awlock}),
    .s_axi_awcache  ({xb_si1_awcache,     cdc_out_awcache}),
    .s_axi_awprot   ({xb_si1_awprot,      cdc_out_awprot}),
    .s_axi_awqos    ({xb_si1_awqos,       4'b0}),
    .s_axi_awvalid  ({xb_si1_awvalid,     cdc_out_awvalid}),
    .s_axi_awready  ({xb_si1_awready,     cdc_out_awready}),
    .s_axi_wdata    ({xb_si1_wdata,       cdc_out_wdata}),
    .s_axi_wstrb    ({xb_si1_wstrb,       cdc_out_wstrb}),
    .s_axi_wlast    ({xb_si1_wlast,       cdc_out_wlast}),
    .s_axi_wvalid   ({xb_si1_wvalid,      cdc_out_wvalid}),
    .s_axi_wready   ({xb_si1_wready,      cdc_out_wready}),
    .s_axi_bid      ({xb_si1_bid,         cdc_out_bid}),
    .s_axi_bresp    ({xb_si1_bresp,       cdc_out_bresp}),
    .s_axi_bvalid   ({xb_si1_bvalid,      cdc_out_bvalid}),
    .s_axi_bready   ({xb_si1_bready,      cdc_out_bready}),
    .s_axi_arid     ({xb_si1_arid,        cdc_out_arid}),
    .s_axi_araddr   ({xb_si1_araddr,      cdc_out_araddr}),
    .s_axi_arlen    ({xb_si1_arlen,       cdc_out_arlen}),
    .s_axi_arsize   ({xb_si1_arsize,      cdc_out_arsize}),
    .s_axi_arburst  ({xb_si1_arburst,     cdc_out_arburst}),
    .s_axi_arlock   ({xb_si1_arlock,      cdc_out_arlock}),
    .s_axi_arcache  ({xb_si1_arcache,     cdc_out_arcache}),
    .s_axi_arprot   ({xb_si1_arprot,      cdc_out_arprot}),
    .s_axi_arqos    ({xb_si1_arqos,       4'b0}),
    .s_axi_arvalid  ({xb_si1_arvalid,     cdc_out_arvalid}),
    .s_axi_arready  ({xb_si1_arready,     cdc_out_arready}),
    .s_axi_rid      ({xb_si1_rid,         cdc_out_rid}),
    .s_axi_rdata    ({xb_si1_rdata,       cdc_out_rdata}),
    .s_axi_rresp    ({xb_si1_rresp,       cdc_out_rresp}),
    .s_axi_rlast    ({xb_si1_rlast,       cdc_out_rlast}),
    .s_axi_rvalid   ({xb_si1_rvalid,      cdc_out_rvalid}),
    .s_axi_rready   ({xb_si1_rready,      cdc_out_rready}),

    // MI = single MI → bram_ctrl.
    .m_axi_awid     (xb_m_axi_awid),
    .m_axi_awaddr   (xb_m_axi_awaddr),
    .m_axi_awlen    (xb_m_axi_awlen),
    .m_axi_awsize   (xb_m_axi_awsize),
    .m_axi_awburst  (xb_m_axi_awburst),
    .m_axi_awlock   (xb_m_axi_awlock),
    .m_axi_awcache  (xb_m_axi_awcache),
    .m_axi_awprot   (xb_m_axi_awprot),
    .m_axi_awqos    (xb_m_axi_awqos),
    .m_axi_awvalid  (xb_m_axi_awvalid),
    .m_axi_awready  (xb_m_axi_awready),
    .m_axi_wdata    (xb_m_axi_wdata),
    .m_axi_wstrb    (xb_m_axi_wstrb),
    .m_axi_wlast    (xb_m_axi_wlast),
    .m_axi_wvalid   (xb_m_axi_wvalid),
    .m_axi_wready   (xb_m_axi_wready),
    .m_axi_bid      (xb_m_axi_bid),
    .m_axi_bresp    (xb_m_axi_bresp),
    .m_axi_bvalid   (xb_m_axi_bvalid),
    .m_axi_bready   (xb_m_axi_bready),
    .m_axi_arid     (xb_m_axi_arid),
    .m_axi_araddr   (xb_m_axi_araddr),
    .m_axi_arlen    (xb_m_axi_arlen),
    .m_axi_arsize   (xb_m_axi_arsize),
    .m_axi_arburst  (xb_m_axi_arburst),
    .m_axi_arlock   (xb_m_axi_arlock),
    .m_axi_arcache  (xb_m_axi_arcache),
    .m_axi_arprot   (xb_m_axi_arprot),
    .m_axi_arqos    (xb_m_axi_arqos),
    .m_axi_arvalid  (xb_m_axi_arvalid),
    .m_axi_arready  (xb_m_axi_arready),
    .m_axi_rid      (xb_m_axi_rid),
    .m_axi_rdata    (xb_m_axi_rdata),
    .m_axi_rresp    (xb_m_axi_rresp),
    .m_axi_rlast    (xb_m_axi_rlast),
    .m_axi_rvalid   (xb_m_axi_rvalid),
    .m_axi_rready   (xb_m_axi_rready)
  );

  // axi_bram_ctrl_bram has auto-derived AXI_ADDR_WIDTH=16 (from
  // MEM_DEPTH=2048 × DATA_WIDTH/8=32 → log2(65536)=16).  Slice the
  // crossbar's 64 b address — upper bits don't matter (64 KB only
  // needs 16).
  axi_bram_ctrl_bram u_bram_ctrl_bram (
    .s_axi_aclk     (aclk),
    .s_axi_aresetn  (aresetn),

    .s_axi_awid     (xb_m_axi_awid),
    .s_axi_awaddr   (xb_m_axi_awaddr[15:0]),
    .s_axi_awlen    (xb_m_axi_awlen),
    .s_axi_awsize   (xb_m_axi_awsize),
    .s_axi_awburst  (xb_m_axi_awburst),
    .s_axi_awlock   (xb_m_axi_awlock),
    .s_axi_awcache  (xb_m_axi_awcache),
    .s_axi_awprot   (xb_m_axi_awprot),
    .s_axi_awvalid  (xb_m_axi_awvalid),
    .s_axi_awready  (xb_m_axi_awready),

    .s_axi_wdata    (xb_m_axi_wdata),
    .s_axi_wstrb    (xb_m_axi_wstrb),
    .s_axi_wlast    (xb_m_axi_wlast),
    .s_axi_wvalid   (xb_m_axi_wvalid),
    .s_axi_wready   (xb_m_axi_wready),

    .s_axi_bid      (xb_m_axi_bid),
    .s_axi_bresp    (xb_m_axi_bresp),
    .s_axi_bvalid   (xb_m_axi_bvalid),
    .s_axi_bready   (xb_m_axi_bready),

    .s_axi_arid     (xb_m_axi_arid),
    .s_axi_araddr   (xb_m_axi_araddr[15:0]),
    .s_axi_arlen    (xb_m_axi_arlen),
    .s_axi_arsize   (xb_m_axi_arsize),
    .s_axi_arburst  (xb_m_axi_arburst),
    .s_axi_arlock   (xb_m_axi_arlock),
    .s_axi_arcache  (xb_m_axi_arcache),
    .s_axi_arprot   (xb_m_axi_arprot),
    .s_axi_arvalid  (xb_m_axi_arvalid),
    .s_axi_arready  (xb_m_axi_arready),

    .s_axi_rid      (xb_m_axi_rid),
    .s_axi_rdata    (xb_m_axi_rdata),
    .s_axi_rresp    (xb_m_axi_rresp),
    .s_axi_rlast    (xb_m_axi_rlast),
    .s_axi_rvalid   (xb_m_axi_rvalid),
    .s_axi_rready   (xb_m_axi_rready)
  );

  // Legacy J18 cattrip output — no HBM means no real thermal trip.
  assign hbm_cattrip = 1'b0;

endmodule

`undef AXI_SLAVE_FLAT_PORTS
