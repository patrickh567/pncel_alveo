// *************************************************************************
//
// Alveo U50 dynamic PR partition — default RM (HBM read-write-read
// traffic generator).
//
// Two `loopback_block` instances exercise every HBM pseudo-channel in
// parallel:
//
//   block A  — HBM ports 0..15:
//                m_ch00..m_ch15 → m_axi_hbm_00..m_axi_hbm_15  (ports 0..15)
//
//   block B  — HBM ports 16..31:
//                m_ch00..m_ch14 → m_axi_hbm_16..m_axi_hbm_30  (ports 16..30)
//                m_ch15 → m_axi_hbm_31  (HBM port 31, AXI3 256 b via the
//                                        static-side axi_hbm_switch.s01;
//                                        4-bit ID matches the switch)
//
// All 32 HBM pseudo-channels are exercised by 16 + 16 = 32 channel
// state machines.  The mux path lands on HBM port 31 which is also
// reachable from the host DMA direct path through axi_hbm_switch.s00,
// so software is responsible for not running both this RM and DMA
// traffic against HBM page 31 concurrently — the static-side switch
// arbitrates the port but the loopback's read-write-read sequence
// can't tolerate concurrent writes from another master.
//
// The mux flat port uses a 4-bit ID (a leftover of the pad-to-4 chain
// into the static-side axi_hbm_switch.s01 ID width); the loopback
// engine uses 6-bit IDs to match the rest of the HBM boundary.  Block
// B's m_ch15 ↔ m_axi_hbm_31 connection is shimmed by-hand for ID
// width — the engine always emits ID=0 so the truncation /
// zero-extension is benign.
//
// Each block runs the same per-channel loop:
//
//   1. issue a 16-beat AXI3 read at the current address, buffering all
//      16 × 256 b beats locally
//   2. issue a 16-beat write at the same address with the buffered data
//      (loopback: the write payload is exactly what was just read)
//   3. issue a second 16-beat read at the same address and compare each
//      returned beat to the buffered original — any mismatch latches the
//      channel's `error` flag for the lifetime of this RM load
//   4. advance the address by one burst (512 B) and repeat for
//      NUM_BURSTS bursts; when the sweep finishes, wrap back to
//      BASE_ADDR and (if `start` is still high) keep going
//
// Software control over the AXI-Lite s_axil port:
//
//   0x00 (R/W) ctrl:    bit 0 — start_a (block A — HBM 0..15)
//                       bit 1 — start_b (block B — HBM 16..31)
//                              Both are level signals; channels run
//                              while the bit is 1 and idle out after
//                              the in-flight burst when it drops.
//   0x04 (R)   status:  bit 0 — error_a (sticky OR of block A)
//                       bit 1 — error_b (sticky OR of block B)
//                       bit 2 — busy_a  (any A channel not in S_IDLE)
//                       bit 3 — busy_b  (any B channel not in S_IDLE)
//                       Errors clear only on aresetn (host pulses
//                       static reg 0 bit 1 to drop dyn_aresetn).
//
// Each channel exercises its own private HBM pseudo-channel — the
// static-side HBM IP routes by port, not by address — so the channels
// test 32 disjoint HBM regions concurrently.
//
// The DFX boundary is flat Verilog ports.  No DMA slave port — the
// XDMA→RM AXI4 path was removed; this RM does its own HBM access.
// Every HBM master is driven; nothing is tied off.
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

`define AXI_MASTER_FLAT_PORTS(PFX, AW, DW, IW, LW)    \
  output wire [IW-1:0]     PFX``_awid,                \
  output wire [AW-1:0]     PFX``_awaddr,              \
  output wire [LW-1:0]     PFX``_awlen,               \
  output wire [2:0]        PFX``_awsize,              \
  output wire [1:0]        PFX``_awburst,             \
  output wire              PFX``_awlock,              \
  output wire [3:0]        PFX``_awcache,             \
  output wire [2:0]        PFX``_awprot,              \
  output wire [3:0]        PFX``_awqos,               \
  output wire [3:0]        PFX``_awregion,            \
  output wire              PFX``_awvalid,             \
  input  wire              PFX``_awready,             \
  output wire [DW-1:0]     PFX``_wdata,               \
  output wire [(DW/8)-1:0] PFX``_wstrb,               \
  output wire              PFX``_wlast,               \
  output wire              PFX``_wvalid,              \
  input  wire              PFX``_wready,              \
  input  wire [IW-1:0]     PFX``_bid,                 \
  input  wire [1:0]        PFX``_bresp,               \
  input  wire              PFX``_bvalid,              \
  output wire              PFX``_bready,              \
  output wire [IW-1:0]     PFX``_arid,                \
  output wire [AW-1:0]     PFX``_araddr,              \
  output wire [LW-1:0]     PFX``_arlen,               \
  output wire [2:0]        PFX``_arsize,              \
  output wire [1:0]        PFX``_arburst,             \
  output wire              PFX``_arlock,              \
  output wire [3:0]        PFX``_arcache,             \
  output wire [2:0]        PFX``_arprot,              \
  output wire [3:0]        PFX``_arqos,               \
  output wire [3:0]        PFX``_arregion,            \
  output wire              PFX``_arvalid,             \
  input  wire              PFX``_arready,             \
  input  wire [IW-1:0]     PFX``_rid,                 \
  input  wire [DW-1:0]     PFX``_rdata,               \
  input  wire [1:0]        PFX``_rresp,               \
  input  wire              PFX``_rlast,               \
  input  wire              PFX``_rvalid,              \
  output wire              PFX``_rready

// =========================================================================
// Per-channel read-write-read state machine.
//
// Drives a single 256 b AXI3 master with hardcoded 16-beat INCR bursts
// (max for AXI3's 4-bit AWLEN).  All AXI signaling is registered so the
// outputs sit on flops at the channel boundary.
// =========================================================================
module loopback_channel #(
  parameter logic [63:0] BASE_ADDR  = 64'h0,
  parameter int          NUM_BURSTS = 256
) (
  input  wire aclk,
  input  wire aresetn,

  input  wire start,    // level — channel runs while high
  output reg  busy,     // FSM not in S_IDLE
  output reg  error,    // sticky; latched on first verify-read mismatch

  `AXI_MASTER_FLAT_PORTS(m, 64, 256, 6, 4)
);

  localparam int          BURST_LEN   = 16;
  localparam int          BURST_BYTES = BURST_LEN * (256 / 8);
  localparam logic [3:0]  AXLEN       = BURST_LEN - 1;
  localparam logic [2:0]  SIZE_32B    = 3'b101;       // 2^5 = 32 B / beat
  localparam logic [1:0]  BURST_INCR  = 2'b01;

  // ---- Constant AXI fields (same on every burst) ----
  assign m_awid     = '0;
  assign m_awsize   = SIZE_32B;
  assign m_awburst  = BURST_INCR;
  assign m_awlock   = 1'b0;
  assign m_awcache  = 4'b0011;     // bufferable + modifiable
  assign m_awprot   = '0;
  assign m_awqos    = '0;
  assign m_awregion = '0;
  assign m_awlen    = AXLEN;

  assign m_arid     = '0;
  assign m_arsize   = SIZE_32B;
  assign m_arburst  = BURST_INCR;
  assign m_arlock   = 1'b0;
  assign m_arcache  = 4'b0011;
  assign m_arprot   = '0;
  assign m_arqos    = '0;
  assign m_arregion = '0;
  assign m_arlen    = AXLEN;

  assign m_wstrb    = {(256/8){1'b1}};

  // ---- FSM ----
  typedef enum logic [3:0] {
    S_IDLE,
    S_AR1, S_R1,
    S_AW,  S_W,  S_B,
    S_AR2, S_R2,
    S_NEXT
  } state_t;

  state_t       state;
  logic [3:0]   beat_idx;
  logic [31:0]  burst_idx;
  logic [63:0]  cur_addr;
  logic [255:0] data_buf [0:BURST_LEN-1];

  logic         arvalid_r, awvalid_r, wvalid_r, rready_r, bready_r;
  logic [255:0] wdata_r;
  logic         wlast_r;

  assign m_arvalid = arvalid_r;
  assign m_awvalid = awvalid_r;
  assign m_wvalid  = wvalid_r;
  assign m_rready  = rready_r;
  assign m_bready  = bready_r;
  assign m_araddr  = cur_addr;
  assign m_awaddr  = cur_addr;
  assign m_wdata   = wdata_r;
  assign m_wlast   = wlast_r;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state     <= S_IDLE;
      busy      <= 1'b0;
      error     <= 1'b0;
      beat_idx  <= '0;
      burst_idx <= '0;
      cur_addr  <= BASE_ADDR;
      arvalid_r <= 1'b0;
      awvalid_r <= 1'b0;
      wvalid_r  <= 1'b0;
      rready_r  <= 1'b0;
      bready_r  <= 1'b0;
      wdata_r   <= '0;
      wlast_r   <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            state     <= S_AR1;
            busy      <= 1'b1;
            burst_idx <= '0;
            cur_addr  <= BASE_ADDR;
            arvalid_r <= 1'b1;
          end
        end

        S_AR1: begin
          if (m_arready) begin
            arvalid_r <= 1'b0;
            rready_r  <= 1'b1;
            beat_idx  <= '0;
            state     <= S_R1;
          end
        end

        S_R1: begin
          if (m_rvalid) begin
            data_buf[beat_idx] <= m_rdata;
            beat_idx <= beat_idx + 4'd1;
            if (m_rlast) begin
              rready_r  <= 1'b0;
              awvalid_r <= 1'b1;
              state     <= S_AW;
            end
          end
        end

        S_AW: begin
          if (m_awready) begin
            awvalid_r <= 1'b0;
            wvalid_r  <= 1'b1;
            wdata_r   <= data_buf[0];
            wlast_r   <= (BURST_LEN == 1);
            beat_idx  <= 4'd0;
            state     <= S_W;
          end
        end

        S_W: begin
          if (m_wready) begin
            if (beat_idx == AXLEN) begin
              wvalid_r <= 1'b0;
              wlast_r  <= 1'b0;
              bready_r <= 1'b1;
              state    <= S_B;
            end else begin
              beat_idx <= beat_idx + 4'd1;
              wdata_r  <= data_buf[beat_idx + 4'd1];
              wlast_r  <= ((beat_idx + 4'd1) == AXLEN);
            end
          end
        end

        S_B: begin
          if (m_bvalid) begin
            bready_r  <= 1'b0;
            arvalid_r <= 1'b1;
            state     <= S_AR2;
          end
        end

        S_AR2: begin
          if (m_arready) begin
            arvalid_r <= 1'b0;
            rready_r  <= 1'b1;
            beat_idx  <= '0;
            state     <= S_R2;
          end
        end

        S_R2: begin
          if (m_rvalid) begin
            // Latch error on the first mismatch and stay sticky for the
            // life of this RM load.  bresp / rresp are intentionally not
            // checked — they're a separate failure class.
            if (m_rdata != data_buf[beat_idx]) error <= 1'b1;
            beat_idx <= beat_idx + 4'd1;
            if (m_rlast) begin
              rready_r <= 1'b0;
              state    <= S_NEXT;
            end
          end
        end

        S_NEXT: begin
          if (burst_idx == NUM_BURSTS - 1) begin
            // Sweep complete.  Wrap and continue if start still high;
            // otherwise drop busy and idle out.
            if (start) begin
              burst_idx <= '0;
              cur_addr  <= BASE_ADDR;
              arvalid_r <= 1'b1;
              state     <= S_AR1;
            end else begin
              busy  <= 1'b0;
              state <= S_IDLE;
            end
          end else begin
            burst_idx <= burst_idx + 32'd1;
            cur_addr  <= cur_addr + BURST_BYTES;
            arvalid_r <= 1'b1;
            state     <= S_AR1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

// =========================================================================
// 16-channel loopback block.
//
// Bundles up to 16 `loopback_channel` instances under one start / busy /
// error envelope.  `NUM_CHANNELS` selects how many of the 16 flat HBM
// master port groups (`m_ch00..m_ch15`) are actively driven; channels
// from index NUM_CHANNELS upward are held in S_IDLE (their start input
// is gated low) and contribute neither to busy nor to error.  Their
// flat ports stay at safe idle from the channel's reset state, so the
// parent module is free to leave them connected to a tied-off bus.
// =========================================================================
module loopback_block #(
  parameter int NUM_CHANNELS = 16
) (
  input  wire aclk,
  input  wire aresetn,

  input  wire start,
  output wire busy,
  output wire error,

  `AXI_MASTER_FLAT_PORTS(m_ch00, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch01, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch02, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch03, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch04, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch05, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch06, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch07, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch08, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch09, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch10, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch11, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch12, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch13, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch14, 64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_ch15, 64, 256, 6, 4)
);

  logic [15:0] ch_busy;
  logic [15:0] ch_error;
  logic [15:0] ch_enable;

  always_comb begin
    for (int j = 0; j < 16; j++) ch_enable[j] = (j < NUM_CHANNELS);
  end

  assign busy  = |(ch_busy  & ch_enable);
  assign error = |(ch_error & ch_enable);

  `define BLOCK_CHANNEL(IDX, PFX)                                \
    loopback_channel u_ch_``PFX (                                \
      .aclk       (aclk),                                        \
      .aresetn    (aresetn),                                     \
      .start      (start && ch_enable[IDX]),                     \
      .busy       (ch_busy[IDX]),                                \
      .error      (ch_error[IDX]),                               \
      .m_awid     (PFX``_awid),                                  \
      .m_awaddr   (PFX``_awaddr),                                \
      .m_awlen    (PFX``_awlen),                                 \
      .m_awsize   (PFX``_awsize),                                \
      .m_awburst  (PFX``_awburst),                               \
      .m_awlock   (PFX``_awlock),                                \
      .m_awcache  (PFX``_awcache),                               \
      .m_awprot   (PFX``_awprot),                                \
      .m_awqos    (PFX``_awqos),                                 \
      .m_awregion (PFX``_awregion),                              \
      .m_awvalid  (PFX``_awvalid),                               \
      .m_awready  (PFX``_awready),                               \
      .m_wdata    (PFX``_wdata),                                 \
      .m_wstrb    (PFX``_wstrb),                                 \
      .m_wlast    (PFX``_wlast),                                 \
      .m_wvalid   (PFX``_wvalid),                                \
      .m_wready   (PFX``_wready),                                \
      .m_bid      (PFX``_bid),                                   \
      .m_bresp    (PFX``_bresp),                                 \
      .m_bvalid   (PFX``_bvalid),                                \
      .m_bready   (PFX``_bready),                                \
      .m_arid     (PFX``_arid),                                  \
      .m_araddr   (PFX``_araddr),                                \
      .m_arlen    (PFX``_arlen),                                 \
      .m_arsize   (PFX``_arsize),                                \
      .m_arburst  (PFX``_arburst),                               \
      .m_arlock   (PFX``_arlock),                                \
      .m_arcache  (PFX``_arcache),                               \
      .m_arprot   (PFX``_arprot),                                \
      .m_arqos    (PFX``_arqos),                                 \
      .m_arregion (PFX``_arregion),                              \
      .m_arvalid  (PFX``_arvalid),                               \
      .m_arready  (PFX``_arready),                               \
      .m_rid      (PFX``_rid),                                   \
      .m_rdata    (PFX``_rdata),                                 \
      .m_rresp    (PFX``_rresp),                                 \
      .m_rlast    (PFX``_rlast),                                 \
      .m_rvalid   (PFX``_rvalid),                                \
      .m_rready   (PFX``_rready)                                 \
    )

  `BLOCK_CHANNEL( 0, m_ch00);
  `BLOCK_CHANNEL( 1, m_ch01);
  `BLOCK_CHANNEL( 2, m_ch02);
  `BLOCK_CHANNEL( 3, m_ch03);
  `BLOCK_CHANNEL( 4, m_ch04);
  `BLOCK_CHANNEL( 5, m_ch05);
  `BLOCK_CHANNEL( 6, m_ch06);
  `BLOCK_CHANNEL( 7, m_ch07);
  `BLOCK_CHANNEL( 8, m_ch08);
  `BLOCK_CHANNEL( 9, m_ch09);
  `BLOCK_CHANNEL(10, m_ch10);
  `BLOCK_CHANNEL(11, m_ch11);
  `BLOCK_CHANNEL(12, m_ch12);
  `BLOCK_CHANNEL(13, m_ch13);
  `BLOCK_CHANNEL(14, m_ch14);
  `BLOCK_CHANNEL(15, m_ch15);

  `undef BLOCK_CHANNEL

endmodule

// =========================================================================
// PR-partition top — flat-port boundary.  This is the default RM.
// =========================================================================
module alveo_u50_dynamic_region (
  input wire aclk,
  input wire aresetn,

  `AXI_SLAVE_FLAT_PORTS (s_axil,        32,  32, 1, 8),

  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_00,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_01,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_02,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_03,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_04,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_05,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_06,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_07,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_08,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_09,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_10,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_11,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_12,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_13,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_14,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_15,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_16,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_17,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_18,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_19,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_20,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_21,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_22,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_23,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_24,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_25,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_26,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_27,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_28,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_29,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_30,  64, 256, 6, 4),
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_31,  64, 256, 4, 4)
);

  // ---- Per-block status ----
  wire busy_a, busy_b;
  wire error_a, error_b;

  // ---- Inline AXI-Lite slave (2 registers) ----
  // Single-beat AXI-Lite only — the master is XDMA's M_AXIL via the
  // static-side switch network, which never bursts on AXI-Lite.
  logic        ctrl_start_a;     // 0x00 bit 0
  logic        ctrl_start_b;     // 0x00 bit 1
  logic        awready_r, wready_r, bvalid_r;
  logic        arready_r, rvalid_r;
  logic [31:0] awaddr_l;
  logic [31:0] rdata_r;

  typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } w_state_t;
  typedef enum logic       { R_IDLE, R_RESP }         r_state_t;
  w_state_t wstate;
  r_state_t rstate;

  assign s_axil_awready = awready_r;
  assign s_axil_wready  = wready_r;
  assign s_axil_bvalid  = bvalid_r;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_bid     = '0;
  assign s_axil_arready = arready_r;
  assign s_axil_rvalid  = rvalid_r;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_rdata   = rdata_r;
  assign s_axil_rid     = '0;
  assign s_axil_rlast   = 1'b1;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wstate       <= W_IDLE;
      awready_r    <= 1'b0;
      wready_r     <= 1'b0;
      bvalid_r     <= 1'b0;
      awaddr_l     <= '0;
      ctrl_start_a <= 1'b0;
      ctrl_start_b <= 1'b0;
    end else begin
      case (wstate)
        W_IDLE: begin
          if (s_axil_awvalid) begin
            awaddr_l  <= s_axil_awaddr;
            awready_r <= 1'b1;
            wstate    <= W_DATA;
          end
        end
        W_DATA: begin
          awready_r <= 1'b0;
          if (s_axil_wvalid) begin
            wready_r <= 1'b1;
            // 0x00 ctrl is the only writable register; 0x04 status is
            // RO so writes there are silently dropped.
            if (awaddr_l[7:0] == 8'h00) begin
              ctrl_start_a <= s_axil_wdata[0];
              ctrl_start_b <= s_axil_wdata[1];
            end
            bvalid_r <= 1'b1;
            wstate   <= W_RESP;
          end
        end
        W_RESP: begin
          wready_r <= 1'b0;
          if (s_axil_bready) begin
            bvalid_r <= 1'b0;
            wstate   <= W_IDLE;
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rstate    <= R_IDLE;
      arready_r <= 1'b0;
      rvalid_r  <= 1'b0;
      rdata_r   <= '0;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (s_axil_arvalid) begin
            arready_r <= 1'b1;
            case (s_axil_araddr[7:0])
              8'h00:   rdata_r <= {30'b0, ctrl_start_b, ctrl_start_a};
              8'h04:   rdata_r <= {28'b0, busy_b, busy_a, error_b, error_a};
              default: rdata_r <= '0;
            endcase
            rvalid_r <= 1'b1;
            rstate   <= R_RESP;
          end
        end
        R_RESP: begin
          arready_r <= 1'b0;
          if (s_axil_rready) begin
            rvalid_r <= 1'b0;
            rstate   <= R_IDLE;
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // ---- Block-port wiring helper macro ----
  // Connects one of the block's 16 m_chXX flat port groups to an HBM
  // master flat port group — used for every channel where the IDs
  // are 6 bits on both sides.
  `define BLOCK_PORTS(N16, N31)                                        \
    .m_ch``N16``_awid     (m_axi_hbm_``N31``_awid),                    \
    .m_ch``N16``_awaddr   (m_axi_hbm_``N31``_awaddr),                  \
    .m_ch``N16``_awlen    (m_axi_hbm_``N31``_awlen),                   \
    .m_ch``N16``_awsize   (m_axi_hbm_``N31``_awsize),                  \
    .m_ch``N16``_awburst  (m_axi_hbm_``N31``_awburst),                 \
    .m_ch``N16``_awlock   (m_axi_hbm_``N31``_awlock),                  \
    .m_ch``N16``_awcache  (m_axi_hbm_``N31``_awcache),                 \
    .m_ch``N16``_awprot   (m_axi_hbm_``N31``_awprot),                  \
    .m_ch``N16``_awqos    (m_axi_hbm_``N31``_awqos),                   \
    .m_ch``N16``_awregion (m_axi_hbm_``N31``_awregion),                \
    .m_ch``N16``_awvalid  (m_axi_hbm_``N31``_awvalid),                 \
    .m_ch``N16``_awready  (m_axi_hbm_``N31``_awready),                 \
    .m_ch``N16``_wdata    (m_axi_hbm_``N31``_wdata),                   \
    .m_ch``N16``_wstrb    (m_axi_hbm_``N31``_wstrb),                   \
    .m_ch``N16``_wlast    (m_axi_hbm_``N31``_wlast),                   \
    .m_ch``N16``_wvalid   (m_axi_hbm_``N31``_wvalid),                  \
    .m_ch``N16``_wready   (m_axi_hbm_``N31``_wready),                  \
    .m_ch``N16``_bid      (m_axi_hbm_``N31``_bid),                     \
    .m_ch``N16``_bresp    (m_axi_hbm_``N31``_bresp),                   \
    .m_ch``N16``_bvalid   (m_axi_hbm_``N31``_bvalid),                  \
    .m_ch``N16``_bready   (m_axi_hbm_``N31``_bready),                  \
    .m_ch``N16``_arid     (m_axi_hbm_``N31``_arid),                    \
    .m_ch``N16``_araddr   (m_axi_hbm_``N31``_araddr),                  \
    .m_ch``N16``_arlen    (m_axi_hbm_``N31``_arlen),                   \
    .m_ch``N16``_arsize   (m_axi_hbm_``N31``_arsize),                  \
    .m_ch``N16``_arburst  (m_axi_hbm_``N31``_arburst),                 \
    .m_ch``N16``_arlock   (m_axi_hbm_``N31``_arlock),                  \
    .m_ch``N16``_arcache  (m_axi_hbm_``N31``_arcache),                 \
    .m_ch``N16``_arprot   (m_axi_hbm_``N31``_arprot),                  \
    .m_ch``N16``_arqos    (m_axi_hbm_``N31``_arqos),                   \
    .m_ch``N16``_arregion (m_axi_hbm_``N31``_arregion),                \
    .m_ch``N16``_arvalid  (m_axi_hbm_``N31``_arvalid),                 \
    .m_ch``N16``_arready  (m_axi_hbm_``N31``_arready),                 \
    .m_ch``N16``_rid      (m_axi_hbm_``N31``_rid),                     \
    .m_ch``N16``_rdata    (m_axi_hbm_``N31``_rdata),                   \
    .m_ch``N16``_rresp    (m_axi_hbm_``N31``_rresp),                   \
    .m_ch``N16``_rlast    (m_axi_hbm_``N31``_rlast),                   \
    .m_ch``N16``_rvalid   (m_axi_hbm_``N31``_rvalid),                  \
    .m_ch``N16``_rready   (m_axi_hbm_``N31``_rready)

  // ---- ID-width shim for block B's m_ch15 ↔ m_axi_hbm_31 connection ----
  // The block exposes 6-bit IDs (HBM-port shape); the m_axi_hbm_31
  // partition flat port carries 4-bit IDs (matching axi_hbm_switch.s01
  // on the static side).  The loopback channel always emits ID=0 so
  // truncation / zero-extension is benign.
  wire [5:0] block_b_p31_awid_6b;
  wire [5:0] block_b_p31_arid_6b;
  wire [5:0] block_b_p31_bid_6b;
  wire [5:0] block_b_p31_rid_6b;
  assign m_axi_hbm_31_awid = block_b_p31_awid_6b[3:0];
  assign m_axi_hbm_31_arid = block_b_p31_arid_6b[3:0];
  assign block_b_p31_bid_6b = {2'b00, m_axi_hbm_31_bid};
  assign block_b_p31_rid_6b = {2'b00, m_axi_hbm_31_rid};

  // Pipeline stage on aresetn at each traffic-generator boundary so
  // the partition-input reset doesn't have to fan all the way into
  // each block's per-channel FSMs in a single timing path.  One flop
  // per block, sampled synchronously on aclk; both assert and
  // deassert lag the partition input by one cycle.
  reg aresetn_a_q;
  reg aresetn_b_q;
  always_ff @(posedge aclk) begin
    aresetn_a_q <= aresetn;
    aresetn_b_q <= aresetn;
  end

  // ---- Block A — HBM ports 0..15 (one direct channel per HBM port) ----
  loopback_block #(.NUM_CHANNELS(16)) u_block_a (
    .aclk    (aclk),
    .aresetn (aresetn_a_q),
    .start   (ctrl_start_a),
    .busy    (busy_a),
    .error   (error_a),

    `BLOCK_PORTS(00, 00),
    `BLOCK_PORTS(01, 01),
    `BLOCK_PORTS(02, 02),
    `BLOCK_PORTS(03, 03),
    `BLOCK_PORTS(04, 04),
    `BLOCK_PORTS(05, 05),
    `BLOCK_PORTS(06, 06),
    `BLOCK_PORTS(07, 07),
    `BLOCK_PORTS(08, 08),
    `BLOCK_PORTS(09, 09),
    `BLOCK_PORTS(10, 10),
    `BLOCK_PORTS(11, 11),
    `BLOCK_PORTS(12, 12),
    `BLOCK_PORTS(13, 13),
    `BLOCK_PORTS(14, 14),
    `BLOCK_PORTS(15, 15)
  );

  // ---- Block B — HBM ports 16..31 ----
  // m_ch00..m_ch14 drive HBM ports 16..30 directly; m_ch15 lands on
  // HBM port 31 via the m_axi_hbm_31 partition flat port (which
  // goes through the static-side axi_hbm_switch.s01).  The mux flat
  // port has a 4-bit ID (matching the switch); the loopback channel
  // uses 6-bit IDs, so the ID-width shim above does the truncation /
  // zero-extension.
  loopback_block #(.NUM_CHANNELS(16)) u_block_b (
    .aclk    (aclk),
    .aresetn (aresetn_b_q),
    .start   (ctrl_start_b),
    .busy    (busy_b),
    .error   (error_b),

    `BLOCK_PORTS(00, 16),
    `BLOCK_PORTS(01, 17),
    `BLOCK_PORTS(02, 18),
    `BLOCK_PORTS(03, 19),
    `BLOCK_PORTS(04, 20),
    `BLOCK_PORTS(05, 21),
    `BLOCK_PORTS(06, 22),
    `BLOCK_PORTS(07, 23),
    `BLOCK_PORTS(08, 24),
    `BLOCK_PORTS(09, 25),
    `BLOCK_PORTS(10, 26),
    `BLOCK_PORTS(11, 27),
    `BLOCK_PORTS(12, 28),
    `BLOCK_PORTS(13, 29),
    `BLOCK_PORTS(14, 30),

    // m_ch15 → m_axi_hbm_31 (HBM port 31, with ID width shim)
    .m_ch15_awid     (block_b_p31_awid_6b),
    .m_ch15_awaddr   (m_axi_hbm_31_awaddr),
    .m_ch15_awlen    (m_axi_hbm_31_awlen),
    .m_ch15_awsize   (m_axi_hbm_31_awsize),
    .m_ch15_awburst  (m_axi_hbm_31_awburst),
    .m_ch15_awlock   (m_axi_hbm_31_awlock),
    .m_ch15_awcache  (m_axi_hbm_31_awcache),
    .m_ch15_awprot   (m_axi_hbm_31_awprot),
    .m_ch15_awqos    (m_axi_hbm_31_awqos),
    .m_ch15_awregion (m_axi_hbm_31_awregion),
    .m_ch15_awvalid  (m_axi_hbm_31_awvalid),
    .m_ch15_awready  (m_axi_hbm_31_awready),
    .m_ch15_wdata    (m_axi_hbm_31_wdata),
    .m_ch15_wstrb    (m_axi_hbm_31_wstrb),
    .m_ch15_wlast    (m_axi_hbm_31_wlast),
    .m_ch15_wvalid   (m_axi_hbm_31_wvalid),
    .m_ch15_wready   (m_axi_hbm_31_wready),
    .m_ch15_bid      (block_b_p31_bid_6b),
    .m_ch15_bresp    (m_axi_hbm_31_bresp),
    .m_ch15_bvalid   (m_axi_hbm_31_bvalid),
    .m_ch15_bready   (m_axi_hbm_31_bready),
    .m_ch15_arid     (block_b_p31_arid_6b),
    .m_ch15_araddr   (m_axi_hbm_31_araddr),
    .m_ch15_arlen    (m_axi_hbm_31_arlen),
    .m_ch15_arsize   (m_axi_hbm_31_arsize),
    .m_ch15_arburst  (m_axi_hbm_31_arburst),
    .m_ch15_arlock   (m_axi_hbm_31_arlock),
    .m_ch15_arcache  (m_axi_hbm_31_arcache),
    .m_ch15_arprot   (m_axi_hbm_31_arprot),
    .m_ch15_arqos    (m_axi_hbm_31_arqos),
    .m_ch15_arregion (m_axi_hbm_31_arregion),
    .m_ch15_arvalid  (m_axi_hbm_31_arvalid),
    .m_ch15_arready  (m_axi_hbm_31_arready),
    .m_ch15_rid      (block_b_p31_rid_6b),
    .m_ch15_rdata    (m_axi_hbm_31_rdata),
    .m_ch15_rresp    (m_axi_hbm_31_rresp),
    .m_ch15_rlast    (m_axi_hbm_31_rlast),
    .m_ch15_rvalid   (m_axi_hbm_31_rvalid),
    .m_ch15_rready   (m_axi_hbm_31_rready)
  );

  `undef BLOCK_PORTS

endmodule : alveo_u50_dynamic_region

`undef AXI_SLAVE_FLAT_PORTS
`undef AXI_MASTER_FLAT_PORTS
