// *************************************************************************
//
// mini_dice_alveo dynamic region — PR partition body.
//
// Houses the zcu102-derived chip stack (mini_dice_top + Vortex caches +
// L3) wired straight into the alveo's 64 KB AXI BRAM controller.  No
// Aurora link.  XDMA's AXI-Lite path (s_axil_ctrl) feeds the chip's
// CSR/launch FIFO directly through axi_lite_switch.
//
// Architecture:
//
//   s_axi_data    →  stubbed (instant-OK sink; no consumer in this image)
//   s_axil_ctrl   →  axi_lite_switch (was driven by axi_aurora_bridge)
//                       ↘ axi_lite_fifo       → axil_fifo_packet_former →
//                       ↘ axi_lite_regmap                                 ↘
//                                                                         ↘
//   chip-side packet plumbing  →  mini_dice_top  ←  rr_arbiter  ←  CSR-launch packets
//                                       ↕
//                              cache_hierarchy (L1/L2/L3)
//                                       │
//                                       ▼  vx_axi_adapter_v22 (L3 → AXI4 512b)
//                              axi_dwidth_l3_to_bram (512 → 256)
//                                       │
//                                       ▼   SI[0]
//                              axi_crossbar_alveo (2:1, AXI4 256b, ID=20)
//                                       │   SI[1] ← s_axi_hbm (XDMA direct,
//                                       │            ID zero-ext 4→20)
//                                       ▼
//                              axi_bram_ctrl_alveo (64 KB, ID=21, BMG=INTERNAL)
//
// All chip-side logic clocks on `aclk` (250 MHz) and resets on `aresetn`.
//
// *************************************************************************
`timescale 1ns/1ps
`include "VX_define.vh"

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

module mini_dice_alveo_dynamic_region import VX_gpu_pkg::*; (
  input  wire aclk,
  input  wire aresetn,

  `AXI_SLAVE_FLAT_PORTS (s_axi_data,  64, 256, 4, 8),
  `AXI_SLAVE_FLAT_PORTS (s_axi_hbm,   64, 256, 4, 8),
  `AXI_SLAVE_FLAT_PORTS (s_axil_ctrl, 32,  32, 1, 8),

  output wire         hbm_cattrip

`ifdef SIM_CHIP_STUB
  // -- Simulation-only chip-side link interface (exposed when the chip
  //    -- mini_dice_top -- is stubbed). Lets a testbench inject the
  //    32-bit flit stream the chip would emit AND observe the flit
  //    stream the FPGA would send back to the chip (cache responses,
  //    AXI-Lite responses, etc.).  Mirrors mini_dice_zcu102_top's
  //    SIM_CHIP_STUB port list verbatim so the same testbench tasks
  //    work against either DUT.
  ,input  wire [31:0] sim_chip_tx_data_i
  ,input  wire        sim_chip_tx_valid_i
  ,output wire        sim_chip_tx_ready_o
  ,output wire [31:0] sim_chip_rx_data_o
  ,output wire        sim_chip_rx_valid_o
  ,output wire        sim_chip_rx_last_o
  ,input  wire        sim_chip_rx_ready_i
`endif
);

  // Active-high reset alias for chip-side blocks that use `posedge clk` +
  // `if (reset)` semantics (Vortex / mini_dice_top etc.).
  //
  // ORs in the host-driven SOFT_RESET pulse (regmap reg #2 bit 0 → FSM
  // below), giving the host a chip-wide reset accessible over XDMA on
  // real silicon without a bitstream reload.  CSR-path components (host
  // switch, lite switch/FIFO, regmap itself) stay on `aresetn` so the
  // host can still talk to the regmap to poll the bit auto-clear.
  // `__alveo_soft_reset_pulse__` is declared below in the regmap block.
  wire __alveo_soft_reset_pulse__;
  wire __alveo_reset__ = ~aresetn | __alveo_soft_reset_pulse__;

  // No HBM IP → no DRAM thermal trip.  Drives pncel_top's J18 OBUF.
  assign hbm_cattrip = 1'b0;

  // =========================================================================
  // s_axi_data stub — XDMA's bridge-bound AXI4 has no consumer in this
  // image.  Tie off with instant-OK response so any stray transactions
  // complete without stalling.
  // =========================================================================
  reg s_axi_data_b_pending_r;
  reg [3:0] s_axi_data_b_id_r;
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      s_axi_data_b_pending_r <= 1'b0;
      s_axi_data_b_id_r      <= '0;
    end else if (s_axi_data_awvalid && s_axi_data_awready &&
                 s_axi_data_wvalid  && s_axi_data_wready && s_axi_data_wlast) begin
      s_axi_data_b_pending_r <= 1'b1;
      s_axi_data_b_id_r      <= s_axi_data_awid;
    end else if (s_axi_data_bvalid && s_axi_data_bready) begin
      s_axi_data_b_pending_r <= 1'b0;
    end
  end
  assign s_axi_data_awready = !s_axi_data_b_pending_r;
  assign s_axi_data_wready  = !s_axi_data_b_pending_r;
  assign s_axi_data_bvalid  = s_axi_data_b_pending_r;
  assign s_axi_data_bid     = s_axi_data_b_id_r;
  assign s_axi_data_bresp   = 2'b00;

  reg                  s_axi_data_r_active_r;
  reg [3:0]            s_axi_data_r_id_r;
  reg [7:0]            s_axi_data_r_beats_left_r;
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      s_axi_data_r_active_r     <= 1'b0;
      s_axi_data_r_id_r         <= '0;
      s_axi_data_r_beats_left_r <= '0;
    end else if (!s_axi_data_r_active_r && s_axi_data_arvalid && s_axi_data_arready) begin
      s_axi_data_r_active_r     <= 1'b1;
      s_axi_data_r_id_r         <= s_axi_data_arid;
      s_axi_data_r_beats_left_r <= s_axi_data_arlen;
    end else if (s_axi_data_rvalid && s_axi_data_rready) begin
      if (s_axi_data_r_beats_left_r == 0) s_axi_data_r_active_r <= 1'b0;
      else                                 s_axi_data_r_beats_left_r <= s_axi_data_r_beats_left_r - 1'b1;
    end
  end
  assign s_axi_data_arready = !s_axi_data_r_active_r;
  assign s_axi_data_rvalid  = s_axi_data_r_active_r;
  assign s_axi_data_rid     = s_axi_data_r_id_r;
  assign s_axi_data_rdata   = '0;
  assign s_axi_data_rresp   = 2'b00;
  assign s_axi_data_rlast   = s_axi_data_r_active_r && (s_axi_data_r_beats_left_r == 0);


  // ===========================================================================
  // bsg_link DDR endpoints — COMMENTED OUT
  //
  // The off-chip bsg_link path that used to carry 32-bit flits to/from a
  // physical Mini-Dice ASIC has been replaced by an in-fabric
  // `mini_dice_top` instantiation (see `u_mini_dice` block below).  The
  // ASIC lives inside the FPGA now, so the off-chip DDR PHY, its async
  // CDC FIFOs, and the bsg_io_clk domain are no longer needed for this
  // path.
  // ===========================================================================
  // bsg_link_ddr_upstream
  //   #(.width_p                         (32)
  //    ,.channel_width_p                 (channel_width_p)
  //    ,.num_channels_p                  (num_channels_p)
  //    ,.lg_fifo_depth_p                 (6)
  //    ,.lg_credit_to_token_decimation_p (3)
  //    ) up_link
  //   (.core_clk_i           (aclk)
  //   ,.core_link_reset_i    (__alveo_reset__)
  //   ,.core_data_i          (arb_out_data)
  //   ,.core_valid_i         (arb_out_valid)
  //   ,.core_ready_o         (arb_out_ready)
  //   ,.io_clk_i             (bsg_io_clk)
  //   ,.io_link_reset_i      (1'b0)
  //   ,.async_token_reset_i  (1'b0)
  //   ,.io_clk_r_o           (link_clk_o)
  //   ,.io_data_r_o          (link_data_o)
  //   ,.io_valid_r_o         (link_valid_o)
  //   ,.token_clk_i          (link_token_i)
  //   );

  // Wires between the downstream link's core-side output and the packet parser.
  // (Driven by u_mini_dice.link_tx_* below; kept on their original names so
  //  axil_read_response_handler doesn't need to be rewired.)
  wire [31:0] dl_core_data;
  wire        dl_core_valid;
  wire        dl_core_yumi;
  wire        dl_core_ready_to_tap;  // forward-decl (VCS strict); driven by
                                     // axil_read_response_handler.in_ready_o
  wire        parser_pkt_ready;

  // Forward declarations for arb_out_* (driven later by the rr_arbiter at
  // ~line 870; needed earlier here for the SIM_CHIP_STUB chip-RX hookup).
  // RC_DATA_WIDTH = 32 (CH_D_WORD_SIZE*8) is the response beat width.
  logic                     arb_out_valid;
  logic [31:0]              arb_out_data;
  logic                     arb_out_last;
  logic                     arb_out_ready;

  // bsg_link_ddr_downstream
  //   #(.width_p                         (32)
  //    ,.channel_width_p                 (channel_width_p)
  //    ,.num_channels_p                  (num_channels_p)
  //    ,.lg_fifo_depth_p                 (6)
  //    ,.lg_credit_to_token_decimation_p (3)
  //    ) down_link
  //   (.core_clk_i        (aclk)
  //   ,.core_link_reset_i (__alveo_reset__)
  //   ,.io_link_reset_i   (1'b0)
  //   ,.core_data_o       (dl_core_data)
  //   ,.core_valid_o      (dl_core_valid)
  //   ,.core_yumi_i       (dl_core_yumi)
  //   ,.io_clk_i          (link_clk_i)
  //   ,.io_data_i         (link_data_i)
  //   ,.io_valid_i        (link_valid_i)
  //   ,.core_token_r_o    (link_token_o)
  //   );

  // ===========================================================================
  // mini_dice_top — in-fabric instantiation replacing the off-chip bsg_link
  // path above.  Its 32-bit flit stream interfaces tie directly into the
  // existing endpoints:
  //
  //   FPGA "packetizer"  (rr_arbiter output, arb_out_*) ─► link_rx_* (consume)
  //   FPGA "depacketizer" (axil_read_response_handler ► packet_parser)
  //                                              ◄─ link_tx_* (produce)
  //
  // bsg-style yumi_o asserts on the cycle a flit is accepted — semantically
  // equivalent to the "ready" pulse the FPGA-side arbiter expects, so
  // arb_out_ready ← link_rx_yumi_o is a clean ready/valid handshake.
  //
  // mini_dice_top's other ports (cgra_prog_*) are left dangling; expose them
  // through the top-level port list later if board-level scan-chain access
  // is needed.
  // ===========================================================================
`ifdef SIM_CHIP_STUB
  // SIM_CHIP_STUB: skip the in-fabric mini_dice_top; drive the chip→FPGA
  // link from sim_chip_tx_*, and expose the FPGA→chip direction
  // (arb_out_*) so the TB can decode cache responses.
  assign dl_core_data        = sim_chip_tx_data_i;
  assign dl_core_valid       = sim_chip_tx_valid_i;
  assign sim_chip_tx_ready_o = dl_core_ready_to_tap;
  assign sim_chip_rx_data_o  = arb_out_data;
  assign sim_chip_rx_valid_o = arb_out_valid;
  assign sim_chip_rx_last_o  = arb_out_last;
  assign arb_out_ready       = sim_chip_rx_ready_i;
`else
  // ===========================================================================
  // Chip clock domain (50 MHz) + async-FIFO CDC.
  //
  // mini_dice_top runs on a slower 50 MHz domain (chip_clk) to ease timing
  // closure on the chip's deep CGRA pipeline.  The 50 MHz is generated by
  // a clk_wiz MMCM from aclk (XDMA's 250 MHz user clock).  The two flit
  // streams between mini_dice_top and the aclk-side packet plumbing cross
  // clock domains, so both directions go through an async FIFO
  // (xpm_fifo_async, first-word-fall-through).
  //
  // Reset for the chip's domain:
  //   - assert async on (aresetn=0 OR PLL unlocked)
  //   - deassert sync to chip_clk after a 2-FF synchronizer
  // ===========================================================================
  wire chip_clk_wiz_out;
  wire chip_clk_locked;
  wire chip_clk;

  clk_wiz_50Mhz u_chip_clk_wiz (
      .clk_in1  (aclk),
      .resetn   (aresetn),
      .clk_out1 (chip_clk_wiz_out),
      .clk_out2 (),               // 100 MHz output unused
      .locked   (chip_clk_locked)
  );

  BUFG u_chip_clk_bufg (
      .I (chip_clk_wiz_out),
      .O (chip_clk)
  );

  // 2-FF async-assert / sync-deassert reset synchronizer in the chip domain.
  // Includes __alveo_soft_reset_pulse__ so the host-driven soft reset (regmap
  // reg #2 bit 0) hits the chip too, not just the dynamic-region plumbing.
  // 32 aclk cycles ≈ 6 chip_clk cycles at 50 MHz, well past the 2-FF sync.
  wire chip_async_rst = (~aresetn) | (~chip_clk_locked) | __alveo_soft_reset_pulse__;
  (* ASYNC_REG = "TRUE" *) logic [1:0] chip_rst_sync_q;
  always_ff @(posedge chip_clk or posedge chip_async_rst) begin
    if (chip_async_rst) chip_rst_sync_q <= 2'b11;
    else                chip_rst_sync_q <= {chip_rst_sync_q[0], 1'b0};
  end
  wire chip_rst = chip_rst_sync_q[1];

  // -- aclk → chip_clk async FIFO on the FPGA→chip link (RX into chip). --
  wire        rx_fifo_full, rx_fifo_empty;
  wire [31:0] rx_fifo_dout;
  wire        rx_fifo_wr_en  = arb_out_valid & ~rx_fifo_full;
  wire        chip_link_rx_valid = ~rx_fifo_empty;
  wire        chip_link_rx_yumi;
  wire        rx_fifo_rd_en  = chip_link_rx_yumi;

  assign arb_out_ready = ~rx_fifo_full;

  xpm_fifo_async #(
      .FIFO_MEMORY_TYPE   ("auto"),
      .FIFO_WRITE_DEPTH   (32),
      .WRITE_DATA_WIDTH   (32),
      .READ_DATA_WIDTH    (32),
      .READ_MODE          ("fwft"),
      .FIFO_READ_LATENCY  (0),
      .CDC_SYNC_STAGES    (2),
      .RELATED_CLOCKS     (0),
      .USE_ADV_FEATURES   ("0000")
  ) u_rx_cdc (
      .rst        (~aresetn),
      .wr_clk     (aclk),
      .wr_en      (rx_fifo_wr_en),
      .din        (arb_out_data),
      .full       (rx_fifo_full),
      .rd_clk     (chip_clk),
      .rd_en      (rx_fifo_rd_en),
      .dout       (rx_fifo_dout),
      .empty      (rx_fifo_empty),
      // unused/ignored outputs
      .wr_data_count   (),
      .rd_data_count   (),
      .overflow        (),
      .underflow       (),
      .almost_full     (),
      .almost_empty    (),
      .data_valid      (),
      .wr_ack          (),
      .prog_full       (),
      .prog_empty      (),
      .dbiterr         (),
      .sbiterr         (),
      .injectsbiterr   (1'b0),
      .injectdbiterr   (1'b0),
      .sleep           (1'b0)
  );

  // -- chip_clk → aclk async FIFO on the chip→FPGA link (TX out of chip). --
  wire        tx_fifo_full, tx_fifo_empty;
  wire [31:0] tx_fifo_dout;
  wire        chip_link_tx_valid;
  wire [31:0] chip_link_tx_data;
  wire        tx_fifo_wr_en = chip_link_tx_valid & ~tx_fifo_full;
  wire        tx_fifo_rd_en = ~tx_fifo_empty & dl_core_ready_to_tap;

  assign dl_core_valid = ~tx_fifo_empty;
  assign dl_core_data  = tx_fifo_dout;

  xpm_fifo_async #(
      .FIFO_MEMORY_TYPE   ("auto"),
      .FIFO_WRITE_DEPTH   (32),
      .WRITE_DATA_WIDTH   (32),
      .READ_DATA_WIDTH    (32),
      .READ_MODE          ("fwft"),
      .FIFO_READ_LATENCY  (0),
      .CDC_SYNC_STAGES    (2),
      .RELATED_CLOCKS     (0),
      .USE_ADV_FEATURES   ("0000")
  ) u_tx_cdc (
      .rst        (chip_rst),
      .wr_clk     (chip_clk),
      .wr_en      (tx_fifo_wr_en),
      .din        (chip_link_tx_data),
      .full       (tx_fifo_full),
      .rd_clk     (aclk),
      .rd_en      (tx_fifo_rd_en),
      .dout       (tx_fifo_dout),
      .empty      (tx_fifo_empty),
      // unused/ignored outputs
      .wr_data_count   (),
      .rd_data_count   (),
      .overflow        (),
      .underflow       (),
      .almost_full     (),
      .almost_empty    (),
      .data_valid      (),
      .wr_ack          (),
      .prog_full       (),
      .prog_empty      (),
      .dbiterr         (),
      .sbiterr         (),
      .injectsbiterr   (1'b0),
      .injectdbiterr   (1'b0),
      .sleep           (1'b0)
  );

  mini_dice_top #(
      .FLIT_WIDTH    (32),
      .CHANNEL_WIDTH (8)
  ) u_mini_dice (
      .clk_i             (chip_clk),
      .rst_i             (chip_rst),

      // FPGA → core: chip-clk-domain side of the rx async FIFO
      .link_rx_data_i    (rx_fifo_dout),
      .link_rx_valid_i   (chip_link_rx_valid),
      .link_rx_yumi_o    (chip_link_rx_yumi),

      // core → FPGA: chip-clk-domain side of the tx async FIFO
      .link_tx_data_o    (chip_link_tx_data),
      .link_tx_valid_o   (chip_link_tx_valid),
      .link_tx_ready_i   (~tx_fifo_full),

      // CGRA scan chain / bitstream — dangling
      .cgra_prog_dout_o  (),
      .cgra_prog_we_o    ()
  );
`endif

  // dl_core_yumi (formerly driven by `assign dl_core_yumi = dl_core_valid &
  // dl_core_ready_to_tap;`, line ~262 below) is no longer needed —
  // bsg_link_ddr_downstream is the only consumer of that signal and it's
  // commented out.  See the comment-out of that assign below.

  // ===========================================================================
  // axil_read_response_handler — sits inline on the downstream link path.
  // Intercepts opcode-2'b01 (AXI-Lite read response) packets and drives the
  // axi_lite_fifo's rd_rsp_* port; forwards everything else to packet_parser
  // unchanged.
  // ===========================================================================
  wire        tap_to_parser_valid;
  wire [31:0] tap_to_parser_data;

  axil_read_response_handler #(
      .DATA_W (32),
      .OPCODE (2'b01)
  ) u_axil_read_rsp_handler (
      .aclk    (aclk),
      .aresetn (aresetn),

      .in_valid_i (dl_core_valid),
      .in_data_i  (dl_core_data),
      .in_ready_o (dl_core_ready_to_tap),       // declared below

      .out_valid_o (tap_to_parser_valid),
      .out_data_o  (tap_to_parser_data),
      .out_ready_i (parser_pkt_ready),

      .rd_rsp_valid_o (axil_fifo_rd_rsp_valid),
      .rd_rsp_data_o  (axil_fifo_rd_rsp_data),
      .rd_rsp_ready_i (axil_fifo_rd_rsp_ready)
  );

  // (dl_core_ready_to_tap forward-declared above.)

  // bsg convention: yumi (yes-um-i) is asserted when the consumer accepts the
  // current valid beat. yumi = valid & ready. Originally drove
  // bsg_link_ddr_downstream.core_yumi_i — that's commented out now since
  // mini_dice_top replaces it, and mini_dice_top.link_tx_ready_i takes a
  // plain ready (wired to dl_core_ready_to_tap directly).  The assign
  // below is left commented out for the same reason; dl_core_yumi has no
  // remaining consumer.
  // assign dl_core_yumi = dl_core_valid & dl_core_ready_to_tap;

  // ===========================================================================
  // Packet parser (sits at the tap's forwarding output)
  // ===========================================================================
  wire        parser_tx_valid;
  wire [1:0]  parser_tx_type;
  wire [15:0] parser_tx_addr;
  wire [31:0] parser_tx_data;
  wire [3:0]  parser_tx_tid;
  wire [2:0]  parser_tx_eblock;
  wire [4:0]  parser_tx_regaddr;
  wire [1:0]  parser_tx_id;
  wire [7:0]  parser_tx_len;

  packet_parser
    #(.PKT_WIDTH  (32)
     ,.ADDR_WIDTH (16)
     ,.DATA_WIDTH (32)
     ,.LEN_WIDTH  (8)
     ,.ID_WIDTH   (2)
     ) parser
    (.clk           (aclk)
    ,.reset         (__alveo_reset__)

    ,.pkt_data_i    (tap_to_parser_data)
    ,.pkt_valid_i   (tap_to_parser_valid)
    ,.pkt_ready_o   (parser_pkt_ready)

    ,.tx_valid_o    (parser_tx_valid)
    ,.tx_type_o     (parser_tx_type)
    ,.tx_addr_o     (parser_tx_addr)
    ,.tx_id_o       (parser_tx_id)
    ,.tx_data_o     (parser_tx_data)
    ,.tx_tid_o      (parser_tx_tid)
    ,.tx_eblock_o   (parser_tx_eblock)
    ,.tx_regaddr_o  (parser_tx_regaddr)
    ,.tx_len_o      (parser_tx_len)
    );

  // ===========================================================================
  // ID dispatcher: 6 FIFOs, one per id (0..5), split into two width-different
  // groups:
  //   Burst group  (FIFOs 0..1) : {type, addr, id, len}                  — metadata/bitstream caches
  //   D$    group  (FIFOs 2..5) : {type, addr, id, data, tid, eblock, regaddr} — L1 D$ ports 0..3
  // The metadata fields (tid/eblock/regaddr) get packed into the cache tag so
  // the response carries them back. No len on the D$ FIFOs since those
  // transactions are always single-beat.
  // ===========================================================================
  localparam int DISP_ID_WIDTH       = 2;
  localparam int DISP_NUM_FIFOS      = 6;
  localparam int DISP_NUM_BURST      = 2;
  localparam int DISP_NUM_DCACHE     = DISP_NUM_FIFOS - DISP_NUM_BURST;
  localparam int DISP_BURST_TXN_WIDTH  = 2 + 16 + DISP_ID_WIDTH + 8;          // 28
  localparam int DISP_DCACHE_TXN_WIDTH = 2 + 16 + DISP_ID_WIDTH + 32 + 4 + 3 + 5; // 64

  logic [DISP_NUM_BURST-1:0]                            burst_out_valid;
  logic [DISP_NUM_BURST-1:0][DISP_BURST_TXN_WIDTH-1:0]  burst_out_data;
  logic [DISP_NUM_BURST-1:0]                            burst_out_ready;
  logic [DISP_NUM_BURST-1:0]                            burst_fifo_full;

  logic [DISP_NUM_DCACHE-1:0]                            dcache_out_valid;
  logic [DISP_NUM_DCACHE-1:0][DISP_DCACHE_TXN_WIDTH-1:0] dcache_out_data;
  logic [DISP_NUM_DCACHE-1:0]                            dcache_out_ready;
  logic [DISP_NUM_DCACHE-1:0]                            dcache_fifo_full;

  id_dispatcher
    #(.NUM_FIFOS       (DISP_NUM_FIFOS)
     ,.NUM_BURST_FIFOS (DISP_NUM_BURST)
     ,.FIFO_DEPTH      (16)
     ,.ADDR_WIDTH      (16)
     ,.DATA_WIDTH      (32)
     ,.TID_WIDTH       (4)
     ,.EBLOCK_WIDTH    (3)
     ,.REGADDR_WIDTH   (5)
     ,.ID_WIDTH        (DISP_ID_WIDTH)
     ,.LEN_WIDTH       (8)
     ) dispatcher
    (.clk          (aclk)
    ,.reset        (__alveo_reset__)

    ,.tx_valid_i   (parser_tx_valid)
    ,.tx_type_i    (parser_tx_type)
    ,.tx_addr_i    (parser_tx_addr)
    ,.tx_id_i      (parser_tx_id)
    ,.tx_data_i    (parser_tx_data)
    ,.tx_tid_i     (parser_tx_tid)
    ,.tx_eblock_i  (parser_tx_eblock)
    ,.tx_regaddr_i (parser_tx_regaddr)
    ,.tx_len_i     (parser_tx_len)

    ,.burst_out_valid_o   (burst_out_valid)
    ,.burst_out_data_o    (burst_out_data)
    ,.burst_out_ready_i   (burst_out_ready)
    ,.burst_fifo_full_o   (burst_fifo_full)

    ,.dcache_out_valid_o  (dcache_out_valid)
    ,.dcache_out_data_o   (dcache_out_data)
    ,.dcache_out_ready_i  (dcache_out_ready)
    ,.dcache_fifo_full_o  (dcache_fifo_full)
    );

  // ===========================================================================
  // Cache hierarchy (metadata + bitstream + L1 D$ + L2 + L3)
  // ===========================================================================
  localparam int CH_D_NUM_PORTS = 4;
  localparam int CH_D_WORD_SIZE = 4;
  // D$ tag carries {tid[3:0], eblock[2:0], regaddr[4:0], id[1:0]} = 14 bits
  // of routing metadata. On master Vortex these go through the cache's
  // 14-bit `tag_t = {uuid[11:0], value[1:0]}` opaquely (uuid is preserved
  // bit-for-bit across the cache hierarchy and downstream memory), so we
  // size the cache's TAG_WIDTH at 14 (UUID + 2) rather than UUID+14 — the
  // latter inflates DCACHE_MEM_TAG_WIDTH past what the package's
  // L3_MEM_TAG_WIDTH expects, causing the cache_hierarchy.sv port
  // assignment to truncate the mem-side struct and bleed bits between
  // addr and tag.
  localparam int CH_D_TAG_WIDTH = UUID_WIDTH + 2;
  localparam int CH_I_NUM_PORTS = 1;
  localparam int CH_I_WORD_SIZE = 4;
  // Bitstream/metadata caches carry {seq[1:0], len[7:0], beat_count[7:0],
  // id[1:0]} in the tag (20 bits). `seq` lets the burst_response_reorder
  // buffer distinguish up to 4 in-flight bursts per port (each port only
  // ever sees one `id`, so id alone can't tell back-to-back bursts apart).
  // len is replicated into every beat so the read-side FSM in the
  // response_collector can frame transactions.
  localparam int CH_I_SEQ_WIDTH = 2;
  localparam int CH_I_TAG_WIDTH = UUID_WIDTH + 18 + CH_I_SEQ_WIDTH;
  localparam int CH_MSHR_DEPTH  = 32;

  // Local dangling interfaces (unconnected at the other end)
  VX_mem_bus_if #(
      .DATA_SIZE (CH_I_WORD_SIZE),
      .TAG_WIDTH (CH_I_TAG_WIDTH)
  ) ch_metadata_cache_bus_if [CH_I_NUM_PORTS]();

  VX_mem_bus_if #(
      .DATA_SIZE (CH_I_WORD_SIZE),
      .TAG_WIDTH (CH_I_TAG_WIDTH)
  ) ch_bitstream_cache_bus_if [CH_I_NUM_PORTS]();

  VX_mem_bus_if #(
      .DATA_SIZE (CH_D_WORD_SIZE),
      .TAG_WIDTH (CH_D_TAG_WIDTH)
  ) ch_dcache_bus_if [CH_D_NUM_PORTS]();

  // Cache-side dcache bus.  Under SIM_DCACHE_ECHO, reads are absorbed by a
  // sim-only address-echo responder (so the CGRA sees the same
  // dice_core_tb_axi_read16(addr) = addr & 0xFFFF data the upstream EP
  // serves); writes still flow through to the real cache so the AXI BRAM
  // snoop catches them for DPI write-checking.  Without SIM_DCACHE_ECHO,
  // this is a 1:1 passthrough of ch_dcache_bus_if.
  VX_mem_bus_if #(
      .DATA_SIZE (CH_D_WORD_SIZE),
      .TAG_WIDTH (CH_D_TAG_WIDTH)
  ) ch_dcache_to_cache_bus_if [CH_D_NUM_PORTS]();

  // ---------------------------------------------------------------------------
  // Wire dispatcher D$ FIFOs (2..5) to L1 D$ ports 0..3
  //   dcache_out_data field order (MSB → LSB), DISP_DCACHE_TXN_WIDTH = 64:
  //     { type[1:0], addr[15:0], id[1:0], data[31:0],
  //       tid[3:0],  eblock[2:0], regaddr[4:0] }                  (no len)
  //   - cache addr = { parser_addr, 1'b0 } (LSB 0 appended, zero-extended)
  //   - rw         = (type == 2'b00)   // single-write
  //   - byteen     = all ones
  //   - tag        = { tid, eblock, regaddr, id }, zero-extended into the
  //                  cache tag width. The response uses this exact tag, so
  //                  the response packetizer can unpack and route it back.
  //   D$ responses are absorbed by the response_collector below.
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < CH_D_NUM_PORTS; ++i) begin : g_d_port_wire
    // Unpack the 64-bit D$ transaction.
    wire [1:0]  u_type    = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-1  -: 2];
    wire [15:0] u_addr    = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-3  -: 16];
    wire [1:0]  u_id      = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-19 -: DISP_ID_WIDTH];
    wire [31:0] u_data    = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-21 -: 32];
    wire [3:0]  u_tid     = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-53 -: 4];
    wire [2:0]  u_eblock  = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-57 -: 3];
    wire [4:0]  u_regaddr = dcache_out_data[i][DISP_DCACHE_TXN_WIDTH-60 -: 5];

    // Build a 17-bit byte address from the 16-bit field with a 0 LSB appended
    wire [16:0] byte_addr = {u_addr, 1'b0};

    // Pack the 14-bit routing tag: {tid, eblock, regaddr, id}.
    wire [13:0] u_routing_tag = {u_tid, u_eblock, u_regaddr, u_id};

    assign ch_dcache_bus_if[i].req_valid       = dcache_out_valid[i];
    assign ch_dcache_bus_if[i].req_data.rw     = (u_type == 2'b00);
    assign ch_dcache_bus_if[i].req_data.byteen = '1;
    assign ch_dcache_bus_if[i].req_data.addr   = byte_addr;        // implicit zero-extend
    assign ch_dcache_bus_if[i].req_data.flags  = '0;  // master Vortex: atype→flags
    assign ch_dcache_bus_if[i].req_data.data   = u_data;
    assign ch_dcache_bus_if[i].req_data.tag    = u_routing_tag;    // implicit zero-extend

    // FIFO pop when the cache accepts the request
    assign dcache_out_ready[i] = ch_dcache_bus_if[i].req_ready;

    // D$ response side: wired into the response_collector below
    // (rsp_ready driven from rc_in_ready[i+2])
  end

  // ---------------------------------------------------------------------------
  // dcache routing layer: address-space partitioning + response tag echo.
  //
  // Two synthesizable transforms sit between the dispatcher's
  // ch_dcache_bus_if and the cache's dcache_bus_if:
  //
  //   (1) BRAM region offset on the request address.  All chip-side
  //       request types (mfetch, bsfetch, dfetch) ultimately hit the
  //       same physical BRAM via the L3 cache; without partitioning,
  //       chip-address ranges that overlap between request types (e.g.
  //       gemm: bs spans chip 0x0..0x1A00, meta 0x1000..0x1D00, dfetch
  //       writes around 0x100..0x320) would collide in BRAM.  Hard-coded
  //       per-type base offsets keep them disjoint:
  //
  //         meta  region : BRAM 0x0000..0x4000 (1:1 with chip addr,
  //                       chip's mfetch naturally starts at 0x1000)
  //         bs    region : BRAM 0x4000..0x8000 (+ BS_BRAM_OFFSET below)
  //         data  region : BRAM 0x8000..0xC000 (+ DATA_BRAM_OFFSET here)
  //
  //   (2) Response tag echo.  The chip's CGRA encodes its destination
  //       register info (tid/eblock/regaddr) in the request's aruser
  //       (cgra_io_axi4_top maps ar.user[AxiUserWidth-1] = is_meta etc.).
  //       The chip-side memory protocol requires the FPGA to echo that
  //       routing metadata back in bits [28:16] of the response data —
  //       without it, the CGRA can't deposit results into the right
  //       registers (eblocks stall, no writes ever emitted).  Mirrors
  //       the upstream EP's pack_read_beat behaviour when is_meta=1.
  //
  // Both transforms are unconditional combinational logic — synthesizable,
  // single-bit muxes only, no ifdef / sim-only guards.
  // ---------------------------------------------------------------------------
  //
  // DATA_BRAM_OFFSET_WORDS is the word-unit offset (cache treats
  // req_data.addr as 32-bit word index).  The cache scales by 4 to get
  // BRAM byte, so 17'h2000 word units → 0x8000 BRAM byte offset.
  localparam logic [16:0] DATA_BRAM_OFFSET_WORDS = 17'h2000;

  for (genvar i = 0; i < CH_D_NUM_PORTS; ++i) begin : g_d_route
    // -- Request: 1:1 pass-through except for addr (gets BRAM offset).
    assign ch_dcache_to_cache_bus_if[i].req_valid       = ch_dcache_bus_if[i].req_valid;
    assign ch_dcache_to_cache_bus_if[i].req_data.rw     = ch_dcache_bus_if[i].req_data.rw;
    assign ch_dcache_to_cache_bus_if[i].req_data.byteen = ch_dcache_bus_if[i].req_data.byteen;
    assign ch_dcache_to_cache_bus_if[i].req_data.addr   =
        ch_dcache_bus_if[i].req_data.addr + DATA_BRAM_OFFSET_WORDS;
    assign ch_dcache_to_cache_bus_if[i].req_data.data   = ch_dcache_bus_if[i].req_data.data;
    assign ch_dcache_to_cache_bus_if[i].req_data.flags  = ch_dcache_bus_if[i].req_data.flags;
    assign ch_dcache_to_cache_bus_if[i].req_data.tag    = ch_dcache_bus_if[i].req_data.tag;
    assign ch_dcache_bus_if[i].req_ready                = ch_dcache_to_cache_bus_if[i].req_ready;

    // -- Response: forward valid/tag/ready, inject tag bits into upper data.
    //
    // tag layout (from dispatcher's u_routing_tag = {tid, eblock, regaddr, id}):
    //   tag[13:10] = tid  (4 b)
    //   tag[9:7]   = eblock  (3 b)
    //   tag[6:2]   = regaddr  (5 b)
    //   tag[1:0]   = id  (2 b)
    // Response data layout (DW=32, matching upstream pack_read_beat):
    //   data[31:29] = 3'b0
    //   data[28]    = 1'b0
    //   data[27:24] = tid
    //   data[23:21] = eblock
    //   data[20:16] = regaddr
    //   data[15:0]  = real operand value from BRAM
    wire [CH_D_TAG_WIDTH-1:0] rsp_tag      = ch_dcache_to_cache_bus_if[i].rsp_data.tag;
    wire [31:0]                rsp_data_raw = ch_dcache_to_cache_bus_if[i].rsp_data.data;
    assign ch_dcache_bus_if[i].rsp_valid     = ch_dcache_to_cache_bus_if[i].rsp_valid;
    assign ch_dcache_bus_if[i].rsp_data.data = {3'b0, 1'b0, rsp_tag[13:2], rsp_data_raw[15:0]};
    assign ch_dcache_bus_if[i].rsp_data.tag  = rsp_tag;
    assign ch_dcache_to_cache_bus_if[i].rsp_ready = ch_dcache_bus_if[i].rsp_ready;
  end

  // ---------------------------------------------------------------------------
  // Wire dispatcher burst FIFO 0 → metadata cache, FIFO 1 → bitstream cache.
  //   Burst-read packets route here (type == 2'b10, id ∈ {0, 1}).
  //   burst_out_data field order (MSB → LSB), DISP_BURST_TXN_WIDTH = 28:
  //     { type[1:0], addr[15:0], id[1:0], len[7:0] }
  //   burst_read_expander turns each entry into (len+1) word-spaced cache
  //   reads. Each beat is tagged with {seq, len, beat_count, id}; up to
  //   2**CH_I_SEQ_WIDTH bursts can be in flight at once per port. The
  //   responses (which may arrive out of order due to MSHR completion
  //   order) are reordered by burst_response_reorder before being handed
  //   to the response_collector.
  //
  //   Backpressure: the reorder buffer's lane_busy_o feeds back into
  //   burst_read_expander.lane_busy_i; the expander stalls request
  //   issuance whenever the next burst's seq lane is still draining.
  // ---------------------------------------------------------------------------
  localparam int CH_I_NUM_LANES = 1 << CH_I_SEQ_WIDTH;

  // -- Burst FIFO 0 → metadata cache (burst-expanded + reorder) --
  // Chip's packet `addr` field is in byte units (matches DPI's
  // meta_read32(byte_addr) contract); pass through 1:1 zero-extended to
  // 17 bits.  Earlier this was `{meta_u_addr, 1'b0}` (a 2× shift) which
  // doubled the chip's address — that was incompatible with sequential
  // bursts (within a burst the expander steps cache_byte by 4 but the
  // chip's logical byte advances by 4 too, so a 2× base shift makes the
  // alveo's BRAM byte and the chip's expected meta byte offset diverge
  // after beat 0).  Without the shift, BRAM[B] = meta_read32(B) preload
  // works for any burst base.
  wire [15:0] meta_u_addr      = burst_out_data[0][DISP_BURST_TXN_WIDTH-3  -: 16];
  wire [1:0]  meta_u_id        = burst_out_data[0][DISP_BURST_TXN_WIDTH-19 -: DISP_ID_WIDTH];
  wire [7:0]  meta_u_len       = burst_out_data[0][7:0];
  wire [16:0] meta_byte_addr   = {1'b0, meta_u_addr};

  wire [CH_I_NUM_LANES-1:0]  meta_lane_busy;

  // The expander emits cache_req_addr_o in BYTE units
  // (addr + beat_count*WORD_SIZE), but the cache port's req_data.addr
  // is WORD-indexed (ADDR_WIDTH = MEM_ADDR_WIDTH - clog2(WORD_SIZE)).
  // Wiring them directly causes a 4× scaling — each beat advances 16 B
  // in the cache view, crossing a 64 B line every 4 beats.  Shift down
  // by clog2(WORD_SIZE) to recover one-word-per-beat stride so a burst
  // stays within one cache line up to LINE_SIZE/WORD_SIZE = 16 beats.
  wire [16:0] meta_exp_addr_byte;

  burst_read_expander #(
      .ADDR_WIDTH   (17),
      .ID_WIDTH     (DISP_ID_WIDTH),
      .LEN_WIDTH    (8),
      .DATA_WIDTH   (CH_I_WORD_SIZE * 8),
      .BYTEEN_WIDTH (CH_I_WORD_SIZE),
      .WORD_SIZE    (CH_I_WORD_SIZE),
      .TAG_WIDTH    (CH_I_TAG_WIDTH),
      .SEQ_WIDTH    (CH_I_SEQ_WIDTH)
  ) u_meta_burst_expander (
      .clk    (aclk),
      .reset  (__alveo_reset__),

      .fifo_valid_i (burst_out_valid[0]),
      .fifo_addr_i  (meta_byte_addr),
      .fifo_id_i    (meta_u_id),
      .fifo_len_i   (meta_u_len),
      .fifo_ready_o (burst_out_ready[0]),

      .cache_req_valid_o  (ch_metadata_cache_bus_if[0].req_valid),
      .cache_req_rw_o     (ch_metadata_cache_bus_if[0].req_data.rw),
      .cache_req_byteen_o (ch_metadata_cache_bus_if[0].req_data.byteen),
      .cache_req_addr_o   (meta_exp_addr_byte),
      .cache_req_data_o   (ch_metadata_cache_bus_if[0].req_data.data),
      .cache_req_atype_o  (ch_metadata_cache_bus_if[0].req_data.flags),
      .cache_req_tag_o    (ch_metadata_cache_bus_if[0].req_data.tag),
      .cache_req_ready_i  (ch_metadata_cache_bus_if[0].req_ready),

      .lane_busy_i        (meta_lane_busy)
  );

  assign ch_metadata_cache_bus_if[0].req_data.addr =
      meta_exp_addr_byte >> $clog2(CH_I_WORD_SIZE);

  // Reorder buffer for metadata cache responses
  wire                      meta_reord_valid;
  wire [CH_I_WORD_SIZE*8-1:0] meta_reord_data;
  wire [CH_I_TAG_WIDTH-1:0] meta_reord_tag;
  wire                      meta_reord_ready;

  burst_response_reorder #(
      .DATA_WIDTH (CH_I_WORD_SIZE * 8),
      .TAG_WIDTH  (CH_I_TAG_WIDTH),
      .ID_WIDTH   (DISP_ID_WIDTH),
      .LEN_WIDTH  (8),
      .SEQ_WIDTH  (CH_I_SEQ_WIDTH),
      .MAX_BEATS  (256)
  ) u_meta_reorder (
      .clk    (aclk),
      .reset  (__alveo_reset__),

      .in_valid_i (ch_metadata_cache_bus_if[0].rsp_valid),
      .in_data_i  (ch_metadata_cache_bus_if[0].rsp_data.data),
      .in_tag_i   (ch_metadata_cache_bus_if[0].rsp_data.tag),
      .in_ready_o (ch_metadata_cache_bus_if[0].rsp_ready),

      .out_valid_o (meta_reord_valid),
      .out_data_o  (meta_reord_data),
      .out_tag_o   (meta_reord_tag),
      .out_ready_i (meta_reord_ready),

      .lane_busy_o (meta_lane_busy)
  );

  // -- Burst FIFO 1 → bitstream cache (burst-expanded + reorder) --
  wire [15:0] bs_u_addr    = burst_out_data[1][DISP_BURST_TXN_WIDTH-3  -: 16];
  wire [1:0]  bs_u_id      = burst_out_data[1][DISP_BURST_TXN_WIDTH-19 -: DISP_ID_WIDTH];
  wire [7:0]  bs_u_len     = burst_out_data[1][7:0];
  // Byte-units pass-through with a hard-coded BRAM region offset so the bs
  // and meta images live in disjoint BRAM regions even when the chip
  // happens to fetch them at overlapping chip-side addresses (e.g. gemm:
  // bs spans chip 0x0..0x1A00, meta 0x1000..0x1D00).  The compiler / host
  // software is responsible for placing bs payloads at BRAM byte offsets
  // [BS_BRAM_OFFSET, BS_BRAM_OFFSET + bs_image_size) — see the g_d_route
  // generate block above for the matching DATA region offset.
  localparam logic [16:0] BS_BRAM_OFFSET = 17'h4000;
  wire [16:0] bs_byte_addr = {1'b0, bs_u_addr} + BS_BRAM_OFFSET;

  wire [CH_I_NUM_LANES-1:0]  bs_lane_busy;

  // Byte→word shift on the bitstream-cache req addr, same as metadata.
  wire [16:0] bs_exp_addr_byte;

  burst_read_expander #(
      .ADDR_WIDTH   (17),
      .ID_WIDTH     (DISP_ID_WIDTH),
      .LEN_WIDTH    (8),
      .DATA_WIDTH   (CH_I_WORD_SIZE * 8),
      .BYTEEN_WIDTH (CH_I_WORD_SIZE),
      .WORD_SIZE    (CH_I_WORD_SIZE),
      .TAG_WIDTH    (CH_I_TAG_WIDTH),
      .SEQ_WIDTH    (CH_I_SEQ_WIDTH)
  ) u_bs_burst_expander (
      .clk    (aclk),
      .reset  (__alveo_reset__),

      .fifo_valid_i (burst_out_valid[1]),
      .fifo_addr_i  (bs_byte_addr),
      .fifo_id_i    (bs_u_id),
      .fifo_len_i   (bs_u_len),
      .fifo_ready_o (burst_out_ready[1]),

      .cache_req_valid_o  (ch_bitstream_cache_bus_if[0].req_valid),
      .cache_req_rw_o     (ch_bitstream_cache_bus_if[0].req_data.rw),
      .cache_req_byteen_o (ch_bitstream_cache_bus_if[0].req_data.byteen),
      .cache_req_addr_o   (bs_exp_addr_byte),
      .cache_req_data_o   (ch_bitstream_cache_bus_if[0].req_data.data),
      .cache_req_atype_o  (ch_bitstream_cache_bus_if[0].req_data.flags),
      .cache_req_tag_o    (ch_bitstream_cache_bus_if[0].req_data.tag),
      .cache_req_ready_i  (ch_bitstream_cache_bus_if[0].req_ready),

      .lane_busy_i        (bs_lane_busy)
  );

  assign ch_bitstream_cache_bus_if[0].req_data.addr =
      bs_exp_addr_byte >> $clog2(CH_I_WORD_SIZE);

  // Reorder buffer for bitstream cache responses
  wire                      bs_reord_valid;
  wire [CH_I_WORD_SIZE*8-1:0] bs_reord_data;
  wire [CH_I_TAG_WIDTH-1:0] bs_reord_tag;
  wire                      bs_reord_ready;

  burst_response_reorder #(
      .DATA_WIDTH (CH_I_WORD_SIZE * 8),
      .TAG_WIDTH  (CH_I_TAG_WIDTH),
      .ID_WIDTH   (DISP_ID_WIDTH),
      .LEN_WIDTH  (8),
      .SEQ_WIDTH  (CH_I_SEQ_WIDTH),
      .MAX_BEATS  (256)
  ) u_bs_reorder (
      .clk    (aclk),
      .reset  (__alveo_reset__),

      .in_valid_i (ch_bitstream_cache_bus_if[0].rsp_valid),
      .in_data_i  (ch_bitstream_cache_bus_if[0].rsp_data.data),
      .in_tag_i   (ch_bitstream_cache_bus_if[0].rsp_data.tag),
      .in_ready_o (ch_bitstream_cache_bus_if[0].rsp_ready),

      .out_valid_o (bs_reord_valid),
      .out_data_o  (bs_reord_data),
      .out_tag_o   (bs_reord_tag),
      .out_ready_i (bs_reord_ready),

      .lane_busy_o (bs_lane_busy)
  );

  // ===========================================================================
  // Response collector: 6 per-port FIFOs that buffer cache responses.
  //   FIFO 0    ← metadata-cache  response  (I$, formatted as BURST_READ resp)
  //   FIFO 1    ← bitstream-cache response  (I$, formatted as BURST_READ resp)
  //   FIFO 2..5 ← D$ port 0..3   responses  (formatted as single READ resp)
  //
  // Each FIFO emits a flat sequence of 32-bit packet beats over its read port:
  //
  //     [HEADER, DATA0, DATA1, ..., DATA_last]   per transaction
  //
  // The HEADER beat is formatted *outside* the response_collector (per-port,
  // below) so the module itself stays port-agnostic. The HEADER layout
  // mirrors packet_parser's request formats so the remote sender can decode
  // it with the same logic:
  //
  //   BURST_READ response (type=2'b10), I$ ports 0/1:
  //     [31:30]=2'b10  [29]=0  [28]=id[0]  [27:24]=0
  //     [23:16]=len     [15:0]=0
  //
  //   READ response (type=2'b11), D$ ports 2..5:
  //     [31:30]=2'b11  [29:28]=id    [27:24]=tid
  //     [23:21]=eblock [20:16]=regaddr  [15:0]=0
  //
  // Per-port `rsp_last_i`:
  //   - I$ FIFOs (0, 1): last when tag.beat_count == tag.len.
  //   - D$ FIFOs (2..5): every transaction is single-beat, so last = 1.
  // ===========================================================================
  localparam int RC_NUM_FIFOS  = DISP_NUM_FIFOS;          // 6
  localparam int RC_FIFO_DEPTH = 16;
  localparam int RC_DATA_WIDTH = CH_D_WORD_SIZE * 8;      // 32

  // I$ cache-tag field positions (matches burst_read_expander layout):
  //   { seq[1:0], len[7:0], beat_count[7:0], id[1:0] } at the low 20 bits
  localparam int IRESP_ID_LSB    = 0;
  localparam int IRESP_ID_W      = DISP_ID_WIDTH;                       // 2
  localparam int IRESP_BEAT_LSB  = IRESP_ID_LSB   + IRESP_ID_W;         // 2
  localparam int IRESP_LEN_W     = 8;
  localparam int IRESP_LEN_LSB   = IRESP_BEAT_LSB + IRESP_LEN_W;        // 10
  localparam int IRESP_SEQ_LSB   = IRESP_LEN_LSB  + IRESP_LEN_W;        // 18
  localparam int IRESP_SEQ_W     = CH_I_SEQ_WIDTH;                      // 2

  // D$ cache-tag field positions (matches dispatcher's u_routing_tag):
  //   { tid[3:0], eblock[2:0], regaddr[4:0], id[1:0] } at the low 14 bits
  localparam int DRESP_ID_LSB      = 0;
  localparam int DRESP_ID_W        = DISP_ID_WIDTH;                     // 2
  localparam int DRESP_REGADDR_LSB = DRESP_ID_LSB + DRESP_ID_W;         // 2
  localparam int DRESP_REGADDR_W   = 5;
  localparam int DRESP_EB_LSB      = DRESP_REGADDR_LSB + DRESP_REGADDR_W; // 7
  localparam int DRESP_EB_W        = 3;
  localparam int DRESP_TID_LSB     = DRESP_EB_LSB + DRESP_EB_W;         // 10
  localparam int DRESP_TID_W       = 4;

  // Outgoing packet type code for FPGA → chip read responses.  The
  // chip's `axi_link_rx` (Mini_Dice_Backend/Mini_Dice/rtl/IO/axi_link_rx.sv
  // lines 100-105) accepts:
  //   2'b00 OP_WRITE      — chip → FPGA write request   (NOT what we emit)
  //   2'b01 OP_READ_RESP  — FPGA → chip READ response   ← USE THIS
  //   2'b10 OP_BURST_READ — chip → FPGA burst-read req  (chip request, not response)
  //   2'b11 OP_READ       — chip → FPGA single-read req (chip request)
  // Earlier this file emitted 2'b10 / 2'b11 for the response headers,
  // which the chip routed to its own request FIFO instead of the
  // mfetch/dfetch response queue — mfetch_resp.r_valid never fired and
  // every kernel hung waiting on its first instruction fetch.
  // READ_RESP header layout (per axi_link_rx.sv:316-323):
  //   [31:30] = 2'b01 opcode
  //   [29:28] = id_wide          (2-bit; demuxes mfetch / bsfetch / D$ port)
  //   [27]    = is_burst         (1 for mfetch/bsfetch, 0 for D$)
  //   [26:24] = reserved
  //   [23:16] = len_axi          (beats - 1; 0 for D$ single-beat)
  //   [15:0]  = addr             (unused for responses)
  localparam logic [1:0] RSP_TYPE_READ_RESP  = 2'b01;

  logic [RC_NUM_FIFOS-1:0]                    rc_in_valid;
  logic [RC_NUM_FIFOS-1:0][RC_DATA_WIDTH-1:0] rc_in_data;
  logic [RC_NUM_FIFOS-1:0][RC_DATA_WIDTH-1:0] rc_in_header;
  logic [RC_NUM_FIFOS-1:0]                    rc_in_last;
  logic [RC_NUM_FIFOS-1:0]                    rc_in_ready;

  logic [RC_NUM_FIFOS-1:0]                    rc_out_valid;
  logic [RC_NUM_FIFOS-1:0][RC_DATA_WIDTH-1:0] rc_out_data;
  logic [RC_NUM_FIFOS-1:0]                    rc_out_last;
  logic [RC_NUM_FIFOS-1:0]                    rc_out_ready;
  logic [RC_NUM_FIFOS-1:0]                    rc_fifo_empty;

  // -- FIFO 0: metadata cache (I$ BURST_READ response) --
  // -- FIFO 0/1 reorder→collector pipeline registers --
  //
  // Post-route timing analysis showed the worst path on aclk (250 MHz)
  // running from u_(bs|meta)_reorder.g_lane_state[].next_expected_r_reg/C
  // straight through 14-15 LUT levels (MUXF7/MUXF8 trees) into
  // u_rsp_collector.g_fifo[0|1].pending_data_r_reg/D, with WNS = -1.27 ns.
  //
  // A 1-deep forward register slice on the reorder→collector handoff
  // halves the combinational cone — the reorder's internal mux is still
  // 6-8 levels, the collector's input mux is 6-7 levels, and the new FF
  // splits them.  Throughput is unchanged (the slice can accept a beat
  // every cycle when the collector is draining), latency adds 1 cycle.
  //
  // Standard "forward register" pattern:
  //   upstream_ready = ~reg_valid | downstream_ready
  //   on rising edge, if upstream_ready: reg <= upstream

  // -- FIFO 0: metadata cache (I$ BURST_READ response) --
  logic                       meta_reord_pipe_valid;
  logic [CH_I_WORD_SIZE*8-1:0] meta_reord_pipe_data;
  logic [CH_I_TAG_WIDTH-1:0]   meta_reord_pipe_tag;
  assign meta_reord_ready = ~meta_reord_pipe_valid | rc_in_ready[0];
  always_ff @(posedge aclk) begin
    if (__alveo_reset__) begin
      meta_reord_pipe_valid <= 1'b0;
    end else if (meta_reord_ready) begin
      meta_reord_pipe_valid <= meta_reord_valid;
      if (meta_reord_valid) begin
        meta_reord_pipe_data <= meta_reord_data;
        meta_reord_pipe_tag  <= meta_reord_tag;
      end
    end
  end

  // Tag fields decoded from the registered tag (1 LUT-level into the
  // collector's input mux).
  wire [IRESP_LEN_W-1:0] meta_rsp_len  = meta_reord_pipe_tag[IRESP_LEN_LSB  +: IRESP_LEN_W];
  wire [IRESP_LEN_W-1:0] meta_rsp_beat = meta_reord_pipe_tag[IRESP_BEAT_LSB +: IRESP_LEN_W];
  wire                   meta_rsp_id0  = meta_reord_pipe_tag[IRESP_ID_LSB];

  assign rc_in_valid[0]  = meta_reord_pipe_valid;
  assign rc_in_data[0]   = meta_reord_pipe_data;
  // mfetch READ_RESP: opcode=01, id_wide={0,meta_rsp_id0}, is_burst=1, len.
  assign rc_in_header[0] = {RSP_TYPE_READ_RESP, 1'b0, meta_rsp_id0,
                             1'b1, 3'b0, meta_rsp_len, 16'b0};
  assign rc_in_last[0]   = (meta_rsp_beat == meta_rsp_len);

  // -- FIFO 1: bitstream cache (I$ BURST_READ response) --
  logic                       bs_reord_pipe_valid;
  logic [CH_I_WORD_SIZE*8-1:0] bs_reord_pipe_data;
  logic [CH_I_TAG_WIDTH-1:0]   bs_reord_pipe_tag;
  assign bs_reord_ready = ~bs_reord_pipe_valid | rc_in_ready[1];
  always_ff @(posedge aclk) begin
    if (__alveo_reset__) begin
      bs_reord_pipe_valid <= 1'b0;
    end else if (bs_reord_ready) begin
      bs_reord_pipe_valid <= bs_reord_valid;
      if (bs_reord_valid) begin
        bs_reord_pipe_data <= bs_reord_data;
        bs_reord_pipe_tag  <= bs_reord_tag;
      end
    end
  end

  wire [IRESP_LEN_W-1:0] bs_rsp_len  = bs_reord_pipe_tag[IRESP_LEN_LSB  +: IRESP_LEN_W];
  wire [IRESP_LEN_W-1:0] bs_rsp_beat = bs_reord_pipe_tag[IRESP_BEAT_LSB +: IRESP_LEN_W];
  wire                   bs_rsp_id0  = bs_reord_pipe_tag[IRESP_ID_LSB];

  assign rc_in_valid[1]  = bs_reord_pipe_valid;
  assign rc_in_data[1]   = bs_reord_pipe_data;
  // bsfetch READ_RESP: opcode=01, id_wide={0,bs_rsp_id0}, is_burst=1, len.
  assign rc_in_header[1] = {RSP_TYPE_READ_RESP, 1'b0, bs_rsp_id0,
                             1'b1, 3'b0, bs_rsp_len, 16'b0};
  assign rc_in_last[1]   = (bs_rsp_beat == bs_rsp_len);

  // -- FIFOs 2..5: D$ ports 0..3 (READ response, single-beat per txn) --
  for (genvar i = 0; i < CH_D_NUM_PORTS; ++i) begin : g_rc_d_port
    wire [CH_D_TAG_WIDTH-1:0]  d_rsp_tag     = ch_dcache_bus_if[i].rsp_data.tag;
    wire [DRESP_ID_W-1:0]      d_rsp_id      = d_rsp_tag[DRESP_ID_LSB      +: DRESP_ID_W];
    wire [DRESP_REGADDR_W-1:0] d_rsp_regaddr = d_rsp_tag[DRESP_REGADDR_LSB +: DRESP_REGADDR_W];
    wire [DRESP_EB_W-1:0]      d_rsp_eb      = d_rsp_tag[DRESP_EB_LSB      +: DRESP_EB_W];
    wire [DRESP_TID_W-1:0]     d_rsp_tid     = d_rsp_tag[DRESP_TID_LSB     +: DRESP_TID_W];

    assign rc_in_valid [i+DISP_NUM_BURST] = ch_dcache_bus_if[i].rsp_valid;
    assign rc_in_data  [i+DISP_NUM_BURST] = ch_dcache_bus_if[i].rsp_data.data;
    // D$ READ_RESP: opcode=01, id_wide=d_rsp_id (2-bit), is_burst=0,
    // len=0 (single beat).  D$ tid/eblock/regaddr are not part of the
    // READ_RESP header layout — the chip's axi_link_rx uses id_wide
    // alone to demux back to the right D$ port; the chip's higher-level
    // bookkeeping (which CGRA fetch slot this response belongs to)
    // tracks tid/eb/regaddr separately via its outbound request's tag.
    assign rc_in_header[i+DISP_NUM_BURST] = {RSP_TYPE_READ_RESP, d_rsp_id,
                                             1'b0, 3'b0, 8'b0, 16'b0};
    assign rc_in_last  [i+DISP_NUM_BURST] = 1'b1;   // D$ is always single-beat
    assign ch_dcache_bus_if[i].rsp_ready  = rc_in_ready[i+DISP_NUM_BURST];
    // Suppress lint on d_rsp_tid/eb/regaddr (kept for diagnostics).
    wire _unused_drsp = &{1'b0, d_rsp_tid, d_rsp_eb, d_rsp_regaddr, 1'b0};
  end

  response_collector
    #(.NUM_FIFOS        (RC_NUM_FIFOS)
     ,.NUM_BURST_FIFOS  (DISP_NUM_BURST)
     ,.FIFO_DEPTH       (RC_FIFO_DEPTH)
     ,.DATA_WIDTH       (RC_DATA_WIDTH)
     ) u_rsp_collector
    (.clk          (aclk)
    ,.reset        (__alveo_reset__)

    ,.rsp_valid_i  (rc_in_valid)
    ,.rsp_data_i   (rc_in_data)
    ,.rsp_header_i (rc_in_header)
    ,.rsp_last_i   (rc_in_last)
    ,.rsp_ready_o  (rc_in_ready)

    ,.out_valid_o  (rc_out_valid)
    ,.out_data_o   (rc_out_data)
    ,.out_last_o   (rc_out_last)
    ,.out_ready_i  (rc_out_ready)

    ,.fifo_empty_o (rc_fifo_empty)
    );

  // ===========================================================================
  // Response arbiter: round-robin merge of the 6 cache-response FIFOs PLUS
  // 2 AXI-Lite packet streams (write packet from FIFO entries; read packet
  // from staged AXI-Lite reads) onto a single 32-bit packet-beat stream
  // for the upstream bsg_link.
  //
  // Each FIFO entry is already a fully formed packet beat (HEADER on the
  // first beat of a transaction, then DATA beats), so the arbiter's tag pin
  // is unused — we set TAG_WIDTH=1 and tie in_tag_i to '0. Routing/decoding
  // is done at the remote receiver from the header bits.
  //
  // Per-input "last beat":
  //   - inputs [0..5] : rc_out_last from response_collector
  //   - input  [6]    : axil write packet former (asserts on data beat)
  //   - input  [7]    : axil read  packet former (single-beat, always last)
  // The arbiter holds the channel across all beats of a transaction and
  // only re-arbitrates after a last-beat handshake. arb_out_port is
  // exposed for debug but the consumer doesn't need it.
  // ===========================================================================
  localparam int ARB_NUM_INPUTS = RC_NUM_FIFOS + 2;     // 6 cache + write + read
  localparam int ARB_PORT_W     = (ARB_NUM_INPUTS <= 1) ? 1 : $clog2(ARB_NUM_INPUTS);

  // -- axi_lite write-packet former side --
  wire                      axil_pkt_valid;
  wire [RC_DATA_WIDTH-1:0]  axil_pkt_data;
  wire                      axil_pkt_last;
  wire                      axil_pkt_ready;

  // -- axi_lite write-FIFO pop wires (driven below by u_axi_lite_fifo) --
  wire                      axil_fifo_out_valid;
  wire [15:0]               axil_fifo_out_addr;
  wire [15:0]               axil_fifo_out_data;
  wire                      axil_fifo_out_ready;

  // -- axi_lite read-request former side --
  wire                      axil_rd_pkt_valid;
  wire [RC_DATA_WIDTH-1:0]  axil_rd_pkt_data;
  wire                      axil_rd_pkt_last;
  wire                      axil_rd_pkt_ready;

  // -- axi_lite read-request staging wires (driven below by u_axi_lite_fifo) --
  wire                      axil_fifo_rd_req_valid;
  wire [15:0]               axil_fifo_rd_req_addr;
  wire                      axil_fifo_rd_req_ready;
  // Read response back to the AXI-Lite R channel; driven by
  // u_axil_read_rsp_handler (decodes the 2-beat opcode-2'b01 packet on the
  // downstream link).
  wire                      axil_fifo_rd_rsp_valid;
  wire [RC_DATA_WIDTH-1:0]  axil_fifo_rd_rsp_data;
  wire                      axil_fifo_rd_rsp_ready;

  // Concatenated arbiter inputs: cache FIFOs at [0..5], axil write at [6],
  // axil read at [7].
  logic [ARB_NUM_INPUTS-1:0]                       arb_in_valid;
  logic [ARB_NUM_INPUTS-1:0][RC_DATA_WIDTH-1:0]    arb_in_data;
  logic [ARB_NUM_INPUTS-1:0]                       arb_in_last;
  logic [ARB_NUM_INPUTS-1:0]                       arb_in_ready;

  for (genvar i = 0; i < RC_NUM_FIFOS; ++i) begin : g_arb_in_rc
    assign arb_in_valid[i] = rc_out_valid[i];
    assign arb_in_data[i]  = rc_out_data[i];
    assign arb_in_last[i]  = rc_out_last[i];
    assign rc_out_ready[i] = arb_in_ready[i];
  end
  assign arb_in_valid[RC_NUM_FIFOS]     = axil_pkt_valid;
  assign arb_in_data [RC_NUM_FIFOS]     = axil_pkt_data;
  assign arb_in_last [RC_NUM_FIFOS]     = axil_pkt_last;
  assign axil_pkt_ready                 = arb_in_ready[RC_NUM_FIFOS];

  assign arb_in_valid[RC_NUM_FIFOS + 1] = axil_rd_pkt_valid;
  assign arb_in_data [RC_NUM_FIFOS + 1] = axil_rd_pkt_data;
  assign arb_in_last [RC_NUM_FIFOS + 1] = axil_rd_pkt_last;
  assign axil_rd_pkt_ready              = arb_in_ready[RC_NUM_FIFOS + 1];

  // arb_out_valid/data/last/ready forward-declared at the top of the module
  // (the SIM_CHIP_STUB chip-RX hookup needs them earlier than the rr_arbiter
  // instantiation here).
  logic [ARB_PORT_W-1:0]    arb_out_port;

  rr_arbiter
    #(.NUM_INPUTS (ARB_NUM_INPUTS)
     ,.DATA_WIDTH (RC_DATA_WIDTH)
     ,.TAG_WIDTH  (1)
     ) u_rsp_arbiter
    (.clk         (aclk)
    ,.reset       (__alveo_reset__)

    ,.in_valid_i  (arb_in_valid)
    ,.in_data_i   (arb_in_data)
    ,.in_tag_i    ('0)              // tag unused — header is baked into data
    ,.in_last_i   (arb_in_last)
    ,.in_ready_o  (arb_in_ready)

    ,.out_valid_o (arb_out_valid)
    ,.out_data_o  (arb_out_data)
    ,.out_tag_o   ()                // unused
    ,.out_port_o  (arb_out_port)
    ,.out_last_o  (arb_out_last)
    ,.out_ready_i (arb_out_ready)
    );

  // ---------------------------------------------------------------------------
  // axil_fifo_packet_former — drains u_axi_lite_fifo's pop port and emits a
  // 2-beat WRITE packet ({opcode, 14'b0, addr[15:0]} then {16'b0, data[15:0]})
  // into the arbiter's 7th input. axil_fifo_out_* / axil_pkt_* wires are
  // declared above; the FIFO that drives them lives in the AXI-Lite
  // subsystem block further down in this file.
  // ---------------------------------------------------------------------------
  axil_fifo_packet_former #(
      .DATA_W         (RC_DATA_WIDTH),
      .ADDR_PAYLOAD_W (16),
      .DATA_PAYLOAD_W (16),
      .OPCODE         (2'b00)            // packet_parser WRITE opcode
  ) u_axil_fifo_packet_former (
      .aclk    (aclk),
      .aresetn (aresetn),

      .in_valid_i (axil_fifo_out_valid),
      .in_addr_i  (axil_fifo_out_addr),
      .in_data_i  (axil_fifo_out_data),
      .in_ready_o (axil_fifo_out_ready),

      .out_valid_o (axil_pkt_valid),
      .out_data_o  (axil_pkt_data),
      .out_last_o  (axil_pkt_last),
      .out_ready_i (axil_pkt_ready)
  );

  // ---------------------------------------------------------------------------
  // axil_read_packet_former — single-beat READ packet emission from the
  // axi_lite_fifo's staged read request. Asserts as soon as the FIFO's
  // read FSM enters its "send packet" state; the arbiter handshake hands
  // ownership of the request back to the FIFO, which then waits for the
  // remote response on axil_fifo_rd_rsp_* (driven by
  // u_axil_read_rsp_handler from the downstream bsg_link).
  // ---------------------------------------------------------------------------
  axil_read_packet_former #(
      .DATA_W         (RC_DATA_WIDTH),
      .ADDR_PAYLOAD_W (16),
      .OPCODE         (2'b11)            // packet_parser READ opcode
  ) u_axil_read_packet_former (
      .aclk    (aclk),
      .aresetn (aresetn),

      .in_valid_i (axil_fifo_rd_req_valid),
      .in_addr_i  (axil_fifo_rd_req_addr),
      .in_ready_o (axil_fifo_rd_req_ready),

      .out_valid_o (axil_rd_pkt_valid),
      .out_data_o  (axil_rd_pkt_data),
      .out_last_o  (axil_rd_pkt_last),
      .out_ready_i (axil_rd_pkt_ready)
  );

  // arb_out_ready is driven by bsg_link_ddr_upstream's core_ready_o above.
  // arb_out_last / arb_out_port are exposed for debug but not consumed —
  // the link transports each beat as an opaque 32-bit word; the remote
  // receiver decodes transaction boundaries from the header's type/len.

  VX_mem_bus_if #(
      .DATA_SIZE (`L3_LINE_SIZE),
      .TAG_WIDTH (L3_MEM_TAG_WIDTH)
  ) ch_mem_bus_if();

  cache_hierarchy
    #(.D_NUM_PORTS      (CH_D_NUM_PORTS)
     ,.D_WORD_SIZE      (CH_D_WORD_SIZE)
     ,.D_TAG_WIDTH      (CH_D_TAG_WIDTH)
     ,.I_NUM_PORTS      (CH_I_NUM_PORTS)
     ,.I_WORD_SIZE      (CH_I_WORD_SIZE)
     ,.I_TAG_WIDTH      (CH_I_TAG_WIDTH)
     ,.MSHR_DEPTH       (CH_MSHR_DEPTH)
     ,.EXT_MEM_TAG_WIDTH(L3_MEM_TAG_WIDTH)  // package version; matches ch_mem_bus_if's TAG_WIDTH
     ) cache
    (.clk                    (aclk)
    ,.reset                  (__alveo_reset__)
    ,.metadata_cache_bus_if  (ch_metadata_cache_bus_if)
    ,.bitstream_cache_bus_if (ch_bitstream_cache_bus_if)
    ,.dcache_bus_if          (ch_dcache_to_cache_bus_if)
    ,.mem_bus_if             (ch_mem_bus_if)
    );

  // ===========================================================================
  // VX_axi_adapter — convert L3 mem-side VX_mem_bus_if -> AXI4 master
  //
  // The Vortex adapter takes flat signals, not an SV interface, so we unpack
  // ch_mem_bus_if into wires first, then feed the adapter.
  //
  // Downstream AXI master signals are declared but currently dangling /
  // tied off — wire them to your AXI consumer (axi_to_aurora, AXI BRAM,
  // PS DDR via Smartconnect, etc.) when ready.
  // ===========================================================================
  localparam int AXI_DATA_WIDTH = `L3_LINE_SIZE * 8;       // 512
  localparam int AXI_ADDR_WIDTH = `MEM_ADDR_WIDTH;         // 32
  localparam int AXI_TAG_WIDTH  = L3_MEM_TAG_WIDTH;        // ~16
  localparam int AXI_NUM_BANKS  = 1;

  // -- Unpack ch_mem_bus_if into flat signals -----------------------------
  wire                              l3_mem_req_valid;
  wire                              l3_mem_req_rw;
  wire [`L3_LINE_SIZE-1:0]          l3_mem_req_byteen;
  wire [VX_MEM_ADDR_WIDTH-1:0]      l3_mem_req_addr;
  wire [`L3_LINE_SIZE*8-1:0]        l3_mem_req_data;
  wire [L3_MEM_TAG_WIDTH-1:0]       l3_mem_req_tag;
  wire                              l3_mem_req_ready;

  wire                              l3_mem_rsp_valid;
  wire [`L3_LINE_SIZE*8-1:0]        l3_mem_rsp_data;
  wire [L3_MEM_TAG_WIDTH-1:0]       l3_mem_rsp_tag;
  wire                              l3_mem_rsp_ready;

  assign l3_mem_req_valid           = ch_mem_bus_if.req_valid;
  assign l3_mem_req_rw              = ch_mem_bus_if.req_data.rw;
  assign l3_mem_req_byteen          = ch_mem_bus_if.req_data.byteen;
  assign l3_mem_req_addr            = ch_mem_bus_if.req_data.addr;
  assign l3_mem_req_data            = ch_mem_bus_if.req_data.data;
  assign l3_mem_req_tag             = ch_mem_bus_if.req_data.tag;
  assign ch_mem_bus_if.req_ready    = l3_mem_req_ready;

  assign ch_mem_bus_if.rsp_valid    = l3_mem_rsp_valid;
  assign ch_mem_bus_if.rsp_data.data = l3_mem_rsp_data;
  assign ch_mem_bus_if.rsp_data.tag  = l3_mem_rsp_tag;
  assign l3_mem_rsp_ready            = ch_mem_bus_if.rsp_ready;

  // (flags is not consumed by the AXI adapter; master Vortex: atype→flags)
  wire [MEM_FLAGS_WIDTH-1:0] _unused_flags = ch_mem_bus_if.req_data.flags;

  // -- AXI master wires (unpacked arrays, one element since NUM_BANKS=1) --
  wire                            m_axi_awvalid  [AXI_NUM_BANKS];
  wire                            m_axi_awready  [AXI_NUM_BANKS];
  wire [AXI_ADDR_WIDTH-1:0]       m_axi_awaddr   [AXI_NUM_BANKS];
  wire [AXI_TAG_WIDTH-1:0]        m_axi_awid     [AXI_NUM_BANKS];
  wire [7:0]                      m_axi_awlen    [AXI_NUM_BANKS];
  wire [2:0]                      m_axi_awsize   [AXI_NUM_BANKS];
  wire [1:0]                      m_axi_awburst  [AXI_NUM_BANKS];
  wire [1:0]                      m_axi_awlock   [AXI_NUM_BANKS];
  wire [3:0]                      m_axi_awcache  [AXI_NUM_BANKS];
  wire [2:0]                      m_axi_awprot   [AXI_NUM_BANKS];
  wire [3:0]                      m_axi_awqos    [AXI_NUM_BANKS];
  wire [3:0]                      m_axi_awregion [AXI_NUM_BANKS];

  wire                            m_axi_wvalid   [AXI_NUM_BANKS];
  wire                            m_axi_wready   [AXI_NUM_BANKS];
  wire [AXI_DATA_WIDTH-1:0]       m_axi_wdata    [AXI_NUM_BANKS];
  wire [AXI_DATA_WIDTH/8-1:0]     m_axi_wstrb    [AXI_NUM_BANKS];
  wire                            m_axi_wlast    [AXI_NUM_BANKS];

  wire                            m_axi_bvalid   [AXI_NUM_BANKS];
  wire                            m_axi_bready   [AXI_NUM_BANKS];
  wire [AXI_TAG_WIDTH-1:0]        m_axi_bid      [AXI_NUM_BANKS];
  wire [1:0]                      m_axi_bresp    [AXI_NUM_BANKS];

  wire                            m_axi_arvalid  [AXI_NUM_BANKS];
  wire                            m_axi_arready  [AXI_NUM_BANKS];
  wire [AXI_ADDR_WIDTH-1:0]       m_axi_araddr   [AXI_NUM_BANKS];
  wire [AXI_TAG_WIDTH-1:0]        m_axi_arid     [AXI_NUM_BANKS];
  wire [7:0]                      m_axi_arlen    [AXI_NUM_BANKS];
  wire [2:0]                      m_axi_arsize   [AXI_NUM_BANKS];
  wire [1:0]                      m_axi_arburst  [AXI_NUM_BANKS];
  wire [1:0]                      m_axi_arlock   [AXI_NUM_BANKS];
  wire [3:0]                      m_axi_arcache  [AXI_NUM_BANKS];
  wire [2:0]                      m_axi_arprot   [AXI_NUM_BANKS];
  wire [3:0]                      m_axi_arqos    [AXI_NUM_BANKS];
  wire [3:0]                      m_axi_arregion [AXI_NUM_BANKS];

  wire                            m_axi_rvalid   [AXI_NUM_BANKS];
  wire                            m_axi_rready   [AXI_NUM_BANKS];
  wire [AXI_DATA_WIDTH-1:0]       m_axi_rdata    [AXI_NUM_BANKS];
  wire [AXI_TAG_WIDTH-1:0]        m_axi_rid      [AXI_NUM_BANKS];
  wire [1:0]                      m_axi_rresp    [AXI_NUM_BANKS];
  wire                            m_axi_rlast    [AXI_NUM_BANKS];

  // ===========================================================================
  // Aurora user-side stream wires (256-bit data + 256-bit user-K).
  // Everything between the VX_axi_adapter and the Aurora user interface
  // is wrapped by `axi_aurora_bridge` below; this file just connects
  // those four streams to the Aurora IP.
  // ===========================================================================
  wire [255:0] data_tx_tdata;
  wire [31:0]  data_tx_tkeep;
  wire         data_tx_tlast;
  wire         data_tx_tvalid;
  wire         data_tx_tready;

  wire [255:0] data_rx_tdata;
  wire [31:0]  data_rx_tkeep;
  wire         data_rx_tlast;
  wire         data_rx_tvalid;

  wire [255:0] userk_tx_tdata;
  wire         userk_tx_tvalid;
  wire         userk_tx_tready;

  wire [255:0] userk_rx_tdata;
  wire         userk_rx_tvalid;

  // Use the v2.2-API wrapper around master Vortex's VX_axi_adapter
  // (master made every mem_req_* / m_axi_* signal an array). See
  // rtl/vx_axi_adapter_v22.sv.
  vx_axi_adapter_v22 #(
    .DATA_WIDTH (AXI_DATA_WIDTH),
    .ADDR_WIDTH (AXI_ADDR_WIDTH),
    .TAG_WIDTH  (AXI_TAG_WIDTH),
    .NUM_BANKS  (AXI_NUM_BANKS)
  ) u_axi_adapter (
    .clk            (aclk),
    .reset          (__alveo_reset__),

    .mem_req_valid  (l3_mem_req_valid),
    .mem_req_rw     (l3_mem_req_rw),
    .mem_req_byteen (l3_mem_req_byteen),
    .mem_req_addr   (l3_mem_req_addr),
    .mem_req_data   (l3_mem_req_data),
    .mem_req_tag    (l3_mem_req_tag),
    .mem_req_ready  (l3_mem_req_ready),

    .mem_rsp_valid  (l3_mem_rsp_valid),
    .mem_rsp_data   (l3_mem_rsp_data),
    .mem_rsp_tag    (l3_mem_rsp_tag),
    .mem_rsp_ready  (l3_mem_rsp_ready),

    .m_axi_awvalid  (m_axi_awvalid),
    .m_axi_awready  (m_axi_awready),
    .m_axi_awaddr   (m_axi_awaddr),
    .m_axi_awid     (m_axi_awid),
    .m_axi_awlen    (m_axi_awlen),
    .m_axi_awsize   (m_axi_awsize),
    .m_axi_awburst  (m_axi_awburst),
    .m_axi_awlock   (m_axi_awlock),
    .m_axi_awcache  (m_axi_awcache),
    .m_axi_awprot   (m_axi_awprot),
    .m_axi_awqos    (m_axi_awqos),
    .m_axi_awregion (m_axi_awregion),

    .m_axi_wvalid   (m_axi_wvalid),
    .m_axi_wready   (m_axi_wready),
    .m_axi_wdata    (m_axi_wdata),
    .m_axi_wstrb    (m_axi_wstrb),
    .m_axi_wlast    (m_axi_wlast),

    .m_axi_bvalid   (m_axi_bvalid),
    .m_axi_bready   (m_axi_bready),
    .m_axi_bid      (m_axi_bid),
    .m_axi_bresp    (m_axi_bresp),

    .m_axi_arvalid  (m_axi_arvalid),
    .m_axi_arready  (m_axi_arready),
    .m_axi_araddr   (m_axi_araddr),
    .m_axi_arid     (m_axi_arid),
    .m_axi_arlen    (m_axi_arlen),
    .m_axi_arsize   (m_axi_arsize),
    .m_axi_arburst  (m_axi_arburst),
    .m_axi_arlock   (m_axi_arlock),
    .m_axi_arcache  (m_axi_arcache),
    .m_axi_arprot   (m_axi_arprot),
    .m_axi_arqos    (m_axi_arqos),
    .m_axi_arregion (m_axi_arregion),

    .m_axi_rvalid   (m_axi_rvalid),
    .m_axi_rready   (m_axi_rready),
    .m_axi_rdata    (m_axi_rdata),
    .m_axi_rid      (m_axi_rid),
    .m_axi_rresp    (m_axi_rresp),
    .m_axi_rlast    (m_axi_rlast)
  );

  // ===========================================================================
  // axi_aurora_bridge — full bidirectional AXI <-> Aurora bridge.
  //   Bundles the four packetization sub-modules (axi_to_aurora,
  //   aurora_r_receiver, axi_depacketizer, axi_packetizer), the data-TX
  //   and user-K TX arbiters, and the cross-gating between W and R chunked
  //   receivers on the shared data RX.
  //
  // External ports:
  //   - 1 AXI4-Full SLAVE  port : VX_axi_adapter (bank 0) drives it
  //   - 1 AXI4-Full MASTER port : (future) on-FPGA AXI-Full slave
  //   - 1 AXI-Lite   MASTER port : (future) on-FPGA AXI-Lite slave
  //   - 4 Aurora user-side streams (data TX/RX, user-K TX/RX)
  //
  // The two master ports are currently dangling (outputs open, response
  // inputs tied to defaults) -- replace the input tie-offs with the real
  // slave wiring when ready (e.g., DDR via Smartconnect for Full, control
  // registers for Lite).
  // ===========================================================================

  // Forward declarations -- the bridge port connections below reference these
  // wires; VCS strict-implicit-decl would otherwise infer them as 1-bit and
  // break the bit-selects in the AXI-Lite subsystem block further down.
  wire [AXI_ADDR_WIDTH-1:0]         m_lite_awaddr;
  wire [2:0]                        m_lite_awprot;
  wire                              m_lite_awvalid;
  wire                              m_lite_awready;
  wire [AXI_DATA_WIDTH-1:0]         m_lite_wdata;
  wire [AXI_DATA_WIDTH/8-1:0]       m_lite_wstrb;
  wire                              m_lite_wvalid;
  wire                              m_lite_wready;
  wire [1:0]                        m_lite_bresp;
  wire                              m_lite_bvalid;
  wire                              m_lite_bready;
  wire [AXI_ADDR_WIDTH-1:0]         m_lite_araddr;
  wire [2:0]                        m_lite_arprot;
  wire                              m_lite_arvalid;
  wire                              m_lite_arready;
  wire [AXI_DATA_WIDTH-1:0]         m_lite_rdata;
  wire [1:0]                        m_lite_rresp;
  wire                              m_lite_rvalid;
  wire                              m_lite_rready;


  // =========================================================================
  // axi_aurora_bridge replacement.  In the alveo image the AXI-Lite
  // master port that previously came from the bridge is sourced
  // directly from XDMA via s_axil_ctrl.  Connect s_axil_ctrl_* (32 b
  // AXI-Lite) straight to the chip-stack's (legacy 512 b-wide) m_lite_*
  // wires; the rest of the chip stack expects this shape.  Zero-extend
  // wdata/wstrb to the wider bus and truncate rdata on the way back.
  // =========================================================================
  assign m_lite_awaddr  = s_axil_ctrl_awaddr;
  assign m_lite_awprot  = s_axil_ctrl_awprot;
  assign m_lite_awvalid = s_axil_ctrl_awvalid;
  assign s_axil_ctrl_awready = m_lite_awready;
  assign m_lite_wdata   = {{(AXI_DATA_WIDTH-32){1'b0}}, s_axil_ctrl_wdata};
  assign m_lite_wstrb   = {{(AXI_DATA_WIDTH/8-4){1'b0}}, s_axil_ctrl_wstrb};
  assign m_lite_wvalid  = s_axil_ctrl_wvalid;
  assign s_axil_ctrl_wready = m_lite_wready;
  assign s_axil_ctrl_bresp  = m_lite_bresp;
  assign s_axil_ctrl_bvalid = m_lite_bvalid;
  assign m_lite_bready  = s_axil_ctrl_bready;
  assign m_lite_araddr  = s_axil_ctrl_araddr;
  assign m_lite_arprot  = s_axil_ctrl_arprot;
  assign m_lite_arvalid = s_axil_ctrl_arvalid;
  assign s_axil_ctrl_arready = m_lite_arready;
  assign s_axil_ctrl_rdata  = m_lite_rdata[31:0];
  assign s_axil_ctrl_rresp  = m_lite_rresp;
  assign s_axil_ctrl_rvalid = m_lite_rvalid;
  assign m_lite_rready  = s_axil_ctrl_rready;

  // AXI-Lite has no IDs; bid/rid back to the host are tied to 0.
  // rlast is implicit 1 for AXI-Lite (axi_lite_clock_converter handles
  // the protocol correctly, so s_axil_ctrl_rdata/rresp/rvalid come from
  // the IP).  But s_axil_ctrl_bid / rid / rlast are AXI4 fields the
  // flat port macro exposes — tie them off.
  assign s_axil_ctrl_bid     = '0;
  assign s_axil_ctrl_rid     = '0;
  assign s_axil_ctrl_rlast   = 1'b1;

  // Aurora user-side streams: no Aurora IP in this image, so the chip-side
  // TX is sunk and the RX held at idle.  These wires are sourced from /
  // sinked to the (removed) axi_aurora_bridge in the zcu102 design.
  assign data_tx_tready  = 1'b1;
  assign userk_tx_tready = 1'b1;
  assign data_rx_tdata   = '0;
  assign data_rx_tkeep   = '0;
  assign data_rx_tlast   = 1'b0;
  assign data_rx_tvalid  = 1'b0;
  assign userk_rx_tdata  = '0;
  assign userk_rx_tvalid = 1'b0;


  // ===========================================================================
  // AXI-Lite subsystem
  //
  //   axi_aurora_bridge.m_lite_*  →  axi_lite_switch  →  { axi_lite_fifo
  //                                                       , axi_lite_regmap }
  //
  // The bridge exposes its AXI-Lite master port at DATA_W = AXI_DATA_WIDTH
  // (=512) to share parameters with the AXI-Full master. The downstream
  // slaves use the conventional 32-bit AXI-Lite, so the bridge's wider
  // wdata/wstrb/rdata get truncated / zero-extended at the switch slave
  // boundary.
  //
  // axi_lite_switch is currently a STUB — the slave port refuses all
  // transactions, the master ports stay idle. The FIFO and regmap are
  // instantiated so the wiring is in place; once the switch's routing
  // logic is filled in, traffic will flow without any further top-level
  // changes.
  // ===========================================================================
  localparam int             LITE_ADDR_W     = AXI_ADDR_WIDTH;          // 32
  localparam int             LITE_DATA_W     = 32;
  localparam int             LITE_STRB_W     = LITE_DATA_W / 8;          // 4
  // axi_lite_fifo BASE_ADDR — the IP matches `awaddr[31:16] ==
  // BASE_ADDR[31:16]`, so the lower 16 b of the host AXI address become
  // the OP_WRITE packet's `addr` field.  Parked at 0x0008_0000 inside
  // axil_host_switch.M02 SEG00 (0x0008_0000..0x0009_FFFF) so a host
  // write to 0x0008_FF02 carries packet addr=0xFF02 (REG_STARTPC).
  // The 0x80000 base matches pncel_alveo/host/mini_dice.py:FIFO_BASE
  // and the 1 MB BAR's compact address map.
  localparam [LITE_ADDR_W-1:0] LITE_FIFO_BASE = 32'h0008_0000;
  // Regmap at 0x0009_0000 (next 64 KB block) — doesn't overlap the
  // FIFO's 16-bit aperture.  Matches mini_dice.py:REGMAP_BASE.
  localparam [LITE_ADDR_W-1:0] LITE_REGS_BASE = 32'h0009_0000;
  localparam int             LITE_NUM_REGS   = 16;

  // -- Bridge-side wires (wide: DATA_W = AXI_DATA_WIDTH) declared above the
  //    bridge instantiation (forward-decl block).

  // -- Switch slave-side wires (narrow: 32-bit AXI-Lite) --
  wire [LITE_DATA_W-1:0]            sw_s_rdata;            // driven by switch
  wire [LITE_DATA_W-1:0]            sw_s_wdata  = m_lite_wdata[LITE_DATA_W-1:0];
  wire [LITE_STRB_W-1:0]            sw_s_wstrb  = m_lite_wstrb[LITE_STRB_W-1:0];
  // Bridge ← switch return path: zero-extend the 32-bit read data up to the
  // bridge's wider rdata bus.
  assign m_lite_rdata = {{(AXI_DATA_WIDTH-LITE_DATA_W){1'b0}}, sw_s_rdata};

  // -- Switch master-side wires (m0 → fifo, m1 → regmap) --
  wire [LITE_ADDR_W-1:0]            sw_m0_awaddr;
  wire [2:0]                        sw_m0_awprot;
  wire                              sw_m0_awvalid;
  wire                              sw_m0_awready;
  wire [LITE_DATA_W-1:0]            sw_m0_wdata;
  wire [LITE_STRB_W-1:0]            sw_m0_wstrb;
  wire                              sw_m0_wvalid;
  wire                              sw_m0_wready;
  wire [1:0]                        sw_m0_bresp;
  wire                              sw_m0_bvalid;
  wire                              sw_m0_bready;
  wire [LITE_ADDR_W-1:0]            sw_m0_araddr;
  wire [2:0]                        sw_m0_arprot;
  wire                              sw_m0_arvalid;
  wire                              sw_m0_arready;
  wire [LITE_DATA_W-1:0]            sw_m0_rdata;
  wire [1:0]                        sw_m0_rresp;
  wire                              sw_m0_rvalid;
  wire                              sw_m0_rready;

  wire [LITE_ADDR_W-1:0]            sw_m1_awaddr;
  wire [2:0]                        sw_m1_awprot;
  wire                              sw_m1_awvalid;
  wire                              sw_m1_awready;
  wire [LITE_DATA_W-1:0]            sw_m1_wdata;
  wire [LITE_STRB_W-1:0]            sw_m1_wstrb;
  wire                              sw_m1_wvalid;
  wire                              sw_m1_wready;
  wire [1:0]                        sw_m1_bresp;
  wire                              sw_m1_bvalid;
  wire                              sw_m1_bready;
  wire [LITE_ADDR_W-1:0]            sw_m1_araddr;
  wire [2:0]                        sw_m1_arprot;
  wire                              sw_m1_arvalid;
  wire                              sw_m1_arready;
  wire [LITE_DATA_W-1:0]            sw_m1_rdata;
  wire [1:0]                        sw_m1_rresp;
  wire                              sw_m1_rvalid;
  wire                              sw_m1_rready;

  // ---------------------------------------------------------------------------
  // STUB axi_lite_switch — port shape only, no routing yet.
  // ---------------------------------------------------------------------------
  axi_lite_switch #(
      .ADDR_W       (LITE_ADDR_W),
      .DATA_W       (LITE_DATA_W),
      .M0_BASE_ADDR (LITE_FIFO_BASE),
      .M1_BASE_ADDR (LITE_REGS_BASE)
  ) u_axi_lite_switch (
      .aclk    (aclk),
      .aresetn (aresetn),

      // Slave port ← axi_aurora_bridge.m_lite_*
      .s_awaddr  (m_lite_awaddr),
      .s_awprot  (m_lite_awprot),
      .s_awvalid (m_lite_awvalid),
      .s_awready (m_lite_awready),
      .s_wdata   (sw_s_wdata),
      .s_wstrb   (sw_s_wstrb),
      .s_wvalid  (m_lite_wvalid),
      .s_wready  (m_lite_wready),
      .s_bresp   (m_lite_bresp),
      .s_bvalid  (m_lite_bvalid),
      .s_bready  (m_lite_bready),
      .s_araddr  (m_lite_araddr),
      .s_arprot  (m_lite_arprot),
      .s_arvalid (m_lite_arvalid),
      .s_arready (m_lite_arready),
      .s_rdata   (sw_s_rdata),
      .s_rresp   (m_lite_rresp),
      .s_rvalid  (m_lite_rvalid),
      .s_rready  (m_lite_rready),

      // Master port 0 → axi_lite_fifo
      .m0_awaddr  (sw_m0_awaddr),
      .m0_awprot  (sw_m0_awprot),
      .m0_awvalid (sw_m0_awvalid),
      .m0_awready (sw_m0_awready),
      .m0_wdata   (sw_m0_wdata),
      .m0_wstrb   (sw_m0_wstrb),
      .m0_wvalid  (sw_m0_wvalid),
      .m0_wready  (sw_m0_wready),
      .m0_bresp   (sw_m0_bresp),
      .m0_bvalid  (sw_m0_bvalid),
      .m0_bready  (sw_m0_bready),
      .m0_araddr  (sw_m0_araddr),
      .m0_arprot  (sw_m0_arprot),
      .m0_arvalid (sw_m0_arvalid),
      .m0_arready (sw_m0_arready),
      .m0_rdata   (sw_m0_rdata),
      .m0_rresp   (sw_m0_rresp),
      .m0_rvalid  (sw_m0_rvalid),
      .m0_rready  (sw_m0_rready),

      // Master port 1 → axi_lite_regmap
      .m1_awaddr  (sw_m1_awaddr),
      .m1_awprot  (sw_m1_awprot),
      .m1_awvalid (sw_m1_awvalid),
      .m1_awready (sw_m1_awready),
      .m1_wdata   (sw_m1_wdata),
      .m1_wstrb   (sw_m1_wstrb),
      .m1_wvalid  (sw_m1_wvalid),
      .m1_wready  (sw_m1_wready),
      .m1_bresp   (sw_m1_bresp),
      .m1_bvalid  (sw_m1_bvalid),
      .m1_bready  (sw_m1_bready),
      .m1_araddr  (sw_m1_araddr),
      .m1_arprot  (sw_m1_arprot),
      .m1_arvalid (sw_m1_arvalid),
      .m1_arready (sw_m1_arready),
      .m1_rdata   (sw_m1_rdata),
      .m1_rresp   (sw_m1_rresp),
      .m1_rvalid  (sw_m1_rvalid),
      .m1_rready  (sw_m1_rready)
  );

  // ---------------------------------------------------------------------------
  // axi_lite_fifo: host-pushed message queue (single base address; AXI-Lite
  // writes push, AXI-Lite reads peek). The external pop port is left
  // unconsumed for now (out_ready tied low) — wire it to a downstream
  // consumer when one exists.
  // ---------------------------------------------------------------------------
  axi_lite_fifo #(
      .ADDR_W     (LITE_ADDR_W),
      .DATA_W     (LITE_DATA_W),
      .BASE_ADDR  (LITE_FIFO_BASE),
      .FIFO_DEPTH (16)
  ) u_axi_lite_fifo (
      .aclk    (aclk),
      .aresetn (aresetn),

      .s_awaddr  (sw_m0_awaddr),
      .s_awprot  (sw_m0_awprot),
      .s_awvalid (sw_m0_awvalid),
      .s_awready (sw_m0_awready),
      .s_wdata   (sw_m0_wdata),
      .s_wstrb   (sw_m0_wstrb),
      .s_wvalid  (sw_m0_wvalid),
      .s_wready  (sw_m0_wready),
      .s_bresp   (sw_m0_bresp),
      .s_bvalid  (sw_m0_bvalid),
      .s_bready  (sw_m0_bready),
      .s_araddr  (sw_m0_araddr),
      .s_arprot  (sw_m0_arprot),
      .s_arvalid (sw_m0_arvalid),
      .s_arready (sw_m0_arready),
      .s_rdata   (sw_m0_rdata),
      .s_rresp   (sw_m0_rresp),
      .s_rvalid  (sw_m0_rvalid),
      .s_rready  (sw_m0_rready),

      // External pop port → axil_fifo_packet_former (above). The entry's
      // {addr_payload[15:0], data_payload[15:0]} are emitted as a 2-beat
      // WRITE packet and merged into the upstream response stream by the
      // rr_arbiter.
      .fifo_out_valid_o (axil_fifo_out_valid),
      .fifo_out_addr_o  (axil_fifo_out_addr),
      .fifo_out_data_o  (axil_fifo_out_data),
      .fifo_out_ready_i (axil_fifo_out_ready),

      // Read-request output → axil_read_packet_former (above). Staged
      // 16-bit address from in-aperture AXI-Lite reads.
      .rd_req_valid_o (axil_fifo_rd_req_valid),
      .rd_req_addr_o  (axil_fifo_rd_req_addr),
      .rd_req_ready_i (axil_fifo_rd_req_ready),

      // Read-response input. TODO: source from downstream bsg_link path
      // once the upstream→host read response handler exists.
      .rd_rsp_valid_i (axil_fifo_rd_rsp_valid),
      .rd_rsp_data_i  (axil_fifo_rd_rsp_data),
      .rd_rsp_ready_o (axil_fifo_rd_rsp_ready),

      .fifo_empty_o (),
      .fifo_full_o  ()
  );

  // ---------------------------------------------------------------------------
  // axi_lite_regmap: bank of LITE_NUM_REGS 32-bit registers.
  //
  // Reg #2 bit 0 — SOFT_RESET.  Host write of 1 starts a soft-reset
  // pulse: a small FSM holds `__alveo_reset__` high for SOFT_RST_CYCLES
  // ticks (resets everything that uses __alveo_reset__: cache_hierarchy,
  // the chip, the burst expanders + reorder buffers, etc.).  The CSR
  // path itself (axil_host_switch, axi_lite_switch, axi_lite_fifo, this
  // regmap) runs off `aresetn` and stays alive throughout, so the host
  // can keep talking.  At the end of the pulse the bit is hardware-
  // cleared via regs_we_i[2]+regs_wd_i[2]=0 so a host poll on this bit
  // returns 0 once the chip is ready again.
  //
  // Why this lives at the regmap and not the cache's flags[FLUSH_FLAG]
  // path: in sim the cache's MSHR / pending_size counters can carry X
  // values from time-0 and never settle their `mshr_empty` signal, so
  // the per-cache flush handshake in VX_cache_flush hangs in WAIT1
  // forever.  A reset pulse skirts that entirely.
  // ---------------------------------------------------------------------------
  wire [LITE_NUM_REGS-1:0][LITE_DATA_W-1:0] regs_o_w;
  wire [LITE_NUM_REGS-1:0]                  regs_we_w;
  wire [LITE_NUM_REGS-1:0][LITE_DATA_W-1:0] regs_wd_w;

  localparam int SOFT_RST_CYCLES = 32;
  localparam int SOFT_RST_CTRW   = $clog2(SOFT_RST_CYCLES + 1);

  wire soft_reset_req = regs_o_w[2][0];          // host-driven bit
  reg                       soft_reset_active_r; // FSM "we are pulsing __alveo_reset__"
  reg [SOFT_RST_CTRW-1:0]   soft_reset_ctr_r;    // counts down to 0
  reg                       soft_reset_done_r;   // 1-cycle pulse to clear the bit

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      soft_reset_active_r <= 1'b0;
      soft_reset_ctr_r    <= '0;
      soft_reset_done_r   <= 1'b0;
    end else begin
      soft_reset_done_r <= 1'b0;
      if (!soft_reset_active_r) begin
        if (soft_reset_req) begin
          soft_reset_active_r <= 1'b1;
          soft_reset_ctr_r    <= SOFT_RST_CTRW'(SOFT_RST_CYCLES);
        end
      end else begin
        if (soft_reset_ctr_r != 0) begin
          soft_reset_ctr_r <= soft_reset_ctr_r - 1'b1;
        end else begin
          soft_reset_active_r <= 1'b0;
          soft_reset_done_r   <= 1'b1;  // pulse to clear the regmap bit
        end
      end
    end
  end

  // Drive the forward-declared __alveo_soft_reset_pulse__ from the FSM.
  assign __alveo_soft_reset_pulse__ = soft_reset_active_r;

  // bit 2 = soft_reset_done_r (auto-clear pulse), all others 0
  assign regs_we_w = {{(LITE_NUM_REGS-3){1'b0}}, soft_reset_done_r, 2'b00};
  assign regs_wd_w = '0;

  axi_lite_regmap #(
      .ADDR_W    (LITE_ADDR_W),
      .DATA_W    (LITE_DATA_W),
      .NUM_REGS  (LITE_NUM_REGS),
      .BASE_ADDR (LITE_REGS_BASE)
  ) u_axi_lite_regmap (
      .aclk    (aclk),
      .aresetn (aresetn),

      .s_awaddr  (sw_m1_awaddr),
      .s_awprot  (sw_m1_awprot),
      .s_awvalid (sw_m1_awvalid),
      .s_awready (sw_m1_awready),
      .s_wdata   (sw_m1_wdata),
      .s_wstrb   (sw_m1_wstrb),
      .s_wvalid  (sw_m1_wvalid),
      .s_wready  (sw_m1_wready),
      .s_bresp   (sw_m1_bresp),
      .s_bvalid  (sw_m1_bvalid),
      .s_bready  (sw_m1_bready),
      .s_araddr  (sw_m1_araddr),
      .s_arprot  (sw_m1_arprot),
      .s_arvalid (sw_m1_arvalid),
      .s_arready (sw_m1_arready),
      .s_rdata   (sw_m1_rdata),
      .s_rresp   (sw_m1_rresp),
      .s_rvalid  (sw_m1_rvalid),
      .s_rready  (sw_m1_rready),

      .regs_o       (regs_o_w),
      .regs_we_i    (regs_we_w),
      .regs_wd_i    (regs_wd_w),
      .regs_sw_we_o ()
  );


  // =========================================================================
  // L3 → BRAM chain.  Picks up vx_axi_adapter_v22's m_axi_*[0] outputs
  // (512 b AXI4 master, ID=AXI_TAG_WIDTH, ADDR=32 b), narrows to 256 b
  // with axi_dwidth_l3_to_bram, then arbitrates with XDMA's direct
  // s_axi_hbm path in axi_crossbar_alveo, and stores into a 64 KB BRAM
  // via axi_bram_ctrl_alveo (internal blk_mem_gen).
  //
  // ID widening: crossbar SI = 20 b each, MI = 21 b after the +log2(2)
  // bit the crossbar adds.  s_axi_hbm's 4 b ID is zero-extended to 20 b.
  // =========================================================================
  // L3-side response ID wires — driven by axi_dwidth_l3_to_bram's
  // slave-side .s_axi_bid / .s_axi_rid outputs (dwidth recreates the
  // L3 master's response ID internally).  Width = the dwidth IP's
  // SI_ID_WIDTH (20 b); truncated back to AXI_TAG_WIDTH for L3.
  wire [19:0]  m_axi_bid_512_to_20;
  wire [19:0]  m_axi_rid_512_to_20;

  wire [19:0]  dw_m_awid;
  wire [31:0]  dw_m_awaddr;
  wire [7:0]   dw_m_awlen;
  wire [2:0]   dw_m_awsize;
  wire [1:0]   dw_m_awburst;
  wire         dw_m_awlock;
  wire [3:0]   dw_m_awcache;
  wire [2:0]   dw_m_awprot;
  wire [3:0]   dw_m_awqos;
  wire [3:0]   dw_m_awregion;
  wire         dw_m_awvalid;
  wire         dw_m_awready;
  wire [255:0] dw_m_wdata;
  wire [31:0]  dw_m_wstrb;
  wire         dw_m_wlast;
  wire         dw_m_wvalid;
  wire         dw_m_wready;
  wire [19:0]  dw_m_bid;
  wire [1:0]   dw_m_bresp;
  wire         dw_m_bvalid;
  wire         dw_m_bready;
  wire [19:0]  dw_m_arid;
  wire [31:0]  dw_m_araddr;
  wire [7:0]   dw_m_arlen;
  wire [2:0]   dw_m_arsize;
  wire [1:0]   dw_m_arburst;
  wire         dw_m_arlock;
  wire [3:0]   dw_m_arcache;
  wire [2:0]   dw_m_arprot;
  wire [3:0]   dw_m_arqos;
  wire [3:0]   dw_m_arregion;
  wire         dw_m_arvalid;
  wire         dw_m_arready;
  wire [19:0]  dw_m_rid;
  wire [255:0] dw_m_rdata;
  wire [1:0]   dw_m_rresp;
  wire         dw_m_rlast;
  wire         dw_m_rvalid;
  wire         dw_m_rready;

  axi_dwidth_l3_to_bram u_dwidth_l3 (
    .s_axi_aclk     (aclk),
    .s_axi_aresetn  (aresetn),

    // L3 side (512 b).  vx_axi_adapter_v22 outputs an array of arrays;
    // unpack [0] of each here.  L3 ID width = AXI_TAG_WIDTH; pad to 20 b
    // (the dwidth SI_ID_WIDTH).
    .s_axi_awid     ({{(20-AXI_TAG_WIDTH){1'b0}}, m_axi_awid[0]}),
    .s_axi_awaddr   (m_axi_awaddr[0]),
    .s_axi_awlen    (m_axi_awlen[0]),
    .s_axi_awsize   (m_axi_awsize[0]),
    .s_axi_awburst  (m_axi_awburst[0]),
    .s_axi_awlock   (m_axi_awlock[0][0]),
    .s_axi_awcache  (m_axi_awcache[0]),
    .s_axi_awprot   (m_axi_awprot[0]),
    .s_axi_awregion (m_axi_awregion[0]),
    .s_axi_awqos    (m_axi_awqos[0]),
    .s_axi_awvalid  (m_axi_awvalid[0]),
    .s_axi_awready  (m_axi_awready[0]),
    .s_axi_wdata    (m_axi_wdata[0]),
    .s_axi_wstrb    (m_axi_wstrb[0]),
    .s_axi_wlast    (m_axi_wlast[0]),
    .s_axi_wvalid   (m_axi_wvalid[0]),
    .s_axi_wready   (m_axi_wready[0]),
    .s_axi_bid      (m_axi_bid_512_to_20),
    .s_axi_bresp    (m_axi_bresp[0]),
    .s_axi_bvalid   (m_axi_bvalid[0]),
    .s_axi_bready   (m_axi_bready[0]),
    .s_axi_arid     ({{(20-AXI_TAG_WIDTH){1'b0}}, m_axi_arid[0]}),
    .s_axi_araddr   (m_axi_araddr[0]),
    .s_axi_arlen    (m_axi_arlen[0]),
    .s_axi_arsize   (m_axi_arsize[0]),
    .s_axi_arburst  (m_axi_arburst[0]),
    .s_axi_arlock   (m_axi_arlock[0][0]),
    .s_axi_arcache  (m_axi_arcache[0]),
    .s_axi_arprot   (m_axi_arprot[0]),
    .s_axi_arregion (m_axi_arregion[0]),
    .s_axi_arqos    (m_axi_arqos[0]),
    .s_axi_arvalid  (m_axi_arvalid[0]),
    .s_axi_arready  (m_axi_arready[0]),
    .s_axi_rid      (m_axi_rid_512_to_20),
    .s_axi_rdata    (m_axi_rdata[0]),
    .s_axi_rresp    (m_axi_rresp[0]),
    .s_axi_rlast    (m_axi_rlast[0]),
    .s_axi_rvalid   (m_axi_rvalid[0]),
    .s_axi_rready   (m_axi_rready[0]),

    // BRAM side (256 b) → crossbar SI[0].
    // axi_dwidth_converter does NOT expose ID ports on the master side
    // when downsizing — it absorbs IDs internally and reproduces them
    // on the s_axi response side.  Crossbar SI[0] sees ID=0 always
    // (driven explicitly below).
    .m_axi_awaddr   (dw_m_awaddr),
    .m_axi_awlen    (dw_m_awlen),
    .m_axi_awsize   (dw_m_awsize),
    .m_axi_awburst  (dw_m_awburst),
    .m_axi_awlock   (dw_m_awlock),
    .m_axi_awcache  (dw_m_awcache),
    .m_axi_awprot   (dw_m_awprot),
    .m_axi_awregion (dw_m_awregion),
    .m_axi_awqos    (dw_m_awqos),
    .m_axi_awvalid  (dw_m_awvalid),
    .m_axi_awready  (dw_m_awready),
    .m_axi_wdata    (dw_m_wdata),
    .m_axi_wstrb    (dw_m_wstrb),
    .m_axi_wlast    (dw_m_wlast),
    .m_axi_wvalid   (dw_m_wvalid),
    .m_axi_wready   (dw_m_wready),
    .m_axi_bresp    (dw_m_bresp),
    .m_axi_bvalid   (dw_m_bvalid),
    .m_axi_bready   (dw_m_bready),
    .m_axi_araddr   (dw_m_araddr),
    .m_axi_arlen    (dw_m_arlen),
    .m_axi_arsize   (dw_m_arsize),
    .m_axi_arburst  (dw_m_arburst),
    .m_axi_arlock   (dw_m_arlock),
    .m_axi_arcache  (dw_m_arcache),
    .m_axi_arprot   (dw_m_arprot),
    .m_axi_arregion (dw_m_arregion),
    .m_axi_arqos    (dw_m_arqos),
    .m_axi_arvalid  (dw_m_arvalid),
    .m_axi_arready  (dw_m_arready),
    .m_axi_rdata    (dw_m_rdata),
    .m_axi_rresp    (dw_m_rresp),
    .m_axi_rlast    (dw_m_rlast),
    .m_axi_rvalid   (dw_m_rvalid),
    .m_axi_rready   (dw_m_rready)
  );

  // dwidth drops IDs on the master side; tie dw_m_*id to 0 so the
  // crossbar SI[0] sees a defined ID (zero — only one SI[0] path).
  assign dw_m_awid = '0;
  assign dw_m_arid = '0;

  // Route the dwidth's slave-side response IDs back to L3 with the
  // right width.  m_axi_bid_512_to_20 and m_axi_rid_512_to_20 are
  // declared above (before first use).
  assign m_axi_bid[0] = m_axi_bid_512_to_20[AXI_TAG_WIDTH-1:0];
  assign m_axi_rid[0] = m_axi_rid_512_to_20[AXI_TAG_WIDTH-1:0];

  // ID width adaptation on s_axi_hbm side: 4 b → 20 b.
  wire [19:0] s_axi_hbm_bid_20b;
  wire [19:0] s_axi_hbm_rid_20b;
  assign s_axi_hbm_bid = s_axi_hbm_bid_20b[3:0];
  assign s_axi_hbm_rid = s_axi_hbm_rid_20b[3:0];

  // Crossbar MI wires.
  wire [20:0]  xb_m_awid;
  wire [63:0]  xb_m_awaddr;
  wire [7:0]   xb_m_awlen;
  wire [2:0]   xb_m_awsize;
  wire [1:0]   xb_m_awburst;
  wire         xb_m_awlock;
  wire [3:0]   xb_m_awcache;
  wire [2:0]   xb_m_awprot;
  wire [3:0]   xb_m_awqos;
  wire         xb_m_awvalid;
  wire         xb_m_awready;
  wire [255:0] xb_m_wdata;
  wire [31:0]  xb_m_wstrb;
  wire         xb_m_wlast;
  wire         xb_m_wvalid;
  wire         xb_m_wready;
  wire [20:0]  xb_m_bid;
  wire [1:0]   xb_m_bresp;
  wire         xb_m_bvalid;
  wire         xb_m_bready;
  wire [20:0]  xb_m_arid;
  wire [63:0]  xb_m_araddr;
  wire [7:0]   xb_m_arlen;
  wire [2:0]   xb_m_arsize;
  wire [1:0]   xb_m_arburst;
  wire         xb_m_arlock;
  wire [3:0]   xb_m_arcache;
  wire [2:0]   xb_m_arprot;
  wire [3:0]   xb_m_arqos;
  wire         xb_m_arvalid;
  wire         xb_m_arready;
  wire [20:0]  xb_m_rid;
  wire [255:0] xb_m_rdata;
  wire [1:0]   xb_m_rresp;
  wire         xb_m_rlast;
  wire         xb_m_rvalid;
  wire         xb_m_rready;

  axi_crossbar_alveo u_xbar_alveo (
    .aclk     (aclk),
    .aresetn  (aresetn),

    // SI = {SI[1] = s_axi_hbm, SI[0] = dw_m_*} per Xilinx concat order.
    // s_axi_hbm: 4 b ID zero-extended to 20 b; 64 b addr; 8 b len.
    // dw_m_*  : 20 b ID; 32 b addr zero-extended to 64 b; 8 b len.
    .s_axi_awid     ({{16'b0, s_axi_hbm_awid}, dw_m_awid}),
    .s_axi_awaddr   ({s_axi_hbm_awaddr,        {32'b0, dw_m_awaddr}}),
    .s_axi_awlen    ({s_axi_hbm_awlen,         dw_m_awlen}),
    .s_axi_awsize   ({s_axi_hbm_awsize,        dw_m_awsize}),
    .s_axi_awburst  ({s_axi_hbm_awburst,       dw_m_awburst}),
    .s_axi_awlock   ({s_axi_hbm_awlock,        dw_m_awlock}),
    .s_axi_awcache  ({s_axi_hbm_awcache,       dw_m_awcache}),
    .s_axi_awprot   ({s_axi_hbm_awprot,        dw_m_awprot}),
    .s_axi_awqos    ({s_axi_hbm_awqos,         dw_m_awqos}),
    .s_axi_awvalid  ({s_axi_hbm_awvalid,       dw_m_awvalid}),
    .s_axi_awready  ({s_axi_hbm_awready,       dw_m_awready}),
    .s_axi_wdata    ({s_axi_hbm_wdata,         dw_m_wdata}),
    .s_axi_wstrb    ({s_axi_hbm_wstrb,         dw_m_wstrb}),
    .s_axi_wlast    ({s_axi_hbm_wlast,         dw_m_wlast}),
    .s_axi_wvalid   ({s_axi_hbm_wvalid,        dw_m_wvalid}),
    .s_axi_wready   ({s_axi_hbm_wready,        dw_m_wready}),
    .s_axi_bid      ({s_axi_hbm_bid_20b,       dw_m_bid}),
    .s_axi_bresp    ({s_axi_hbm_bresp,         dw_m_bresp}),
    .s_axi_bvalid   ({s_axi_hbm_bvalid,        dw_m_bvalid}),
    .s_axi_bready   ({s_axi_hbm_bready,        dw_m_bready}),
    .s_axi_arid     ({{16'b0, s_axi_hbm_arid}, dw_m_arid}),
    .s_axi_araddr   ({s_axi_hbm_araddr,        {32'b0, dw_m_araddr}}),
    .s_axi_arlen    ({s_axi_hbm_arlen,         dw_m_arlen}),
    .s_axi_arsize   ({s_axi_hbm_arsize,        dw_m_arsize}),
    .s_axi_arburst  ({s_axi_hbm_arburst,       dw_m_arburst}),
    .s_axi_arlock   ({s_axi_hbm_arlock,        dw_m_arlock}),
    .s_axi_arcache  ({s_axi_hbm_arcache,       dw_m_arcache}),
    .s_axi_arprot   ({s_axi_hbm_arprot,        dw_m_arprot}),
    .s_axi_arqos    ({s_axi_hbm_arqos,         dw_m_arqos}),
    .s_axi_arvalid  ({s_axi_hbm_arvalid,       dw_m_arvalid}),
    .s_axi_arready  ({s_axi_hbm_arready,       dw_m_arready}),
    .s_axi_rid      ({s_axi_hbm_rid_20b,       dw_m_rid}),
    .s_axi_rdata    ({s_axi_hbm_rdata,         dw_m_rdata}),
    .s_axi_rresp    ({s_axi_hbm_rresp,         dw_m_rresp}),
    .s_axi_rlast    ({s_axi_hbm_rlast,         dw_m_rlast}),
    .s_axi_rvalid   ({s_axi_hbm_rvalid,        dw_m_rvalid}),
    .s_axi_rready   ({s_axi_hbm_rready,        dw_m_rready}),

    .m_axi_awid     (xb_m_awid),
    .m_axi_awaddr   (xb_m_awaddr),
    .m_axi_awlen    (xb_m_awlen),
    .m_axi_awsize   (xb_m_awsize),
    .m_axi_awburst  (xb_m_awburst),
    .m_axi_awlock   (xb_m_awlock),
    .m_axi_awcache  (xb_m_awcache),
    .m_axi_awprot   (xb_m_awprot),
    .m_axi_awqos    (xb_m_awqos),
    .m_axi_awvalid  (xb_m_awvalid),
    .m_axi_awready  (xb_m_awready),
    .m_axi_wdata    (xb_m_wdata),
    .m_axi_wstrb    (xb_m_wstrb),
    .m_axi_wlast    (xb_m_wlast),
    .m_axi_wvalid   (xb_m_wvalid),
    .m_axi_wready   (xb_m_wready),
    .m_axi_bid      (xb_m_bid),
    .m_axi_bresp    (xb_m_bresp),
    .m_axi_bvalid   (xb_m_bvalid),
    .m_axi_bready   (xb_m_bready),
    .m_axi_arid     (xb_m_arid),
    .m_axi_araddr   (xb_m_araddr),
    .m_axi_arlen    (xb_m_arlen),
    .m_axi_arsize   (xb_m_arsize),
    .m_axi_arburst  (xb_m_arburst),
    .m_axi_arlock   (xb_m_arlock),
    .m_axi_arcache  (xb_m_arcache),
    .m_axi_arprot   (xb_m_arprot),
    .m_axi_arqos    (xb_m_arqos),
    .m_axi_arvalid  (xb_m_arvalid),
    .m_axi_arready  (xb_m_arready),
    .m_axi_rid      (xb_m_rid),
    .m_axi_rdata    (xb_m_rdata),
    .m_axi_rresp    (xb_m_rresp),
    .m_axi_rlast    (xb_m_rlast),
    .m_axi_rvalid   (xb_m_rvalid),
    .m_axi_rready   (xb_m_rready)
  );

  axi_bram_ctrl_alveo u_bram_ctrl_alveo (
    .s_axi_aclk     (aclk),
    .s_axi_aresetn  (aresetn),

    .s_axi_awid     (xb_m_awid),
    .s_axi_awaddr   (xb_m_awaddr[15:0]),
    .s_axi_awlen    (xb_m_awlen),
    .s_axi_awsize   (xb_m_awsize),
    .s_axi_awburst  (xb_m_awburst),
    .s_axi_awlock   (xb_m_awlock),
    .s_axi_awcache  (xb_m_awcache),
    .s_axi_awprot   (xb_m_awprot),
    .s_axi_awvalid  (xb_m_awvalid),
    .s_axi_awready  (xb_m_awready),

    .s_axi_wdata    (xb_m_wdata),
    .s_axi_wstrb    (xb_m_wstrb),
    .s_axi_wlast    (xb_m_wlast),
    .s_axi_wvalid   (xb_m_wvalid),
    .s_axi_wready   (xb_m_wready),

    .s_axi_bid      (xb_m_bid),
    .s_axi_bresp    (xb_m_bresp),
    .s_axi_bvalid   (xb_m_bvalid),
    .s_axi_bready   (xb_m_bready),

    .s_axi_arid     (xb_m_arid),
    .s_axi_araddr   (xb_m_araddr[15:0]),
    .s_axi_arlen    (xb_m_arlen),
    .s_axi_arsize   (xb_m_arsize),
    .s_axi_arburst  (xb_m_arburst),
    .s_axi_arlock   (xb_m_arlock),
    .s_axi_arcache  (xb_m_arcache),
    .s_axi_arprot   (xb_m_arprot),
    .s_axi_arvalid  (xb_m_arvalid),
    .s_axi_arready  (xb_m_arready),

    .s_axi_rid      (xb_m_rid),
    .s_axi_rdata    (xb_m_rdata),
    .s_axi_rresp    (xb_m_rresp),
    .s_axi_rlast    (xb_m_rlast),
    .s_axi_rvalid   (xb_m_rvalid),
    .s_axi_rready   (xb_m_rready)
  );

endmodule
