// *************************************************************************
//
// Aurora-stream reconfig module — same partition signature as
// `alveo_u50_dynamic_region` (DFX requires every RM on a single
// partition to match the partition def's boundary exactly), with the
// aurora user-side stream brought in for the RM to use.
//
// Default behavior in this scaffold: HBM masters and the AXI-Lite
// slave are tied off, and the aurora link is left idle (TX driven to
// 0/idle, RX ignored).  Replace the idle block at the bottom of this
// file with the RM's real logic that consumes / produces aurora
// stream traffic.
//
// All aurora_* signals are synchronous to `aurora_user_clk`, which is
// a separate clock domain from `aclk` (the AXI clock used by the HBM
// and AXI-Lite ports).  CDC across the boundary is the RM's
// responsibility.
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

`define AXI_MASTER_TIEOFF(PFX)          \
  assign PFX``_awid     = '0;           \
  assign PFX``_awaddr   = '0;           \
  assign PFX``_awlen    = '0;           \
  assign PFX``_awsize   = '0;           \
  assign PFX``_awburst  = '0;           \
  assign PFX``_awlock   = 1'b0;         \
  assign PFX``_awcache  = '0;           \
  assign PFX``_awprot   = '0;           \
  assign PFX``_awqos    = '0;           \
  assign PFX``_awregion = '0;           \
  assign PFX``_awvalid  = 1'b0;         \
  assign PFX``_wdata    = '0;           \
  assign PFX``_wstrb    = '0;           \
  assign PFX``_wlast    = 1'b0;         \
  assign PFX``_wvalid   = 1'b0;         \
  assign PFX``_bready   = 1'b1;         \
  assign PFX``_arid     = '0;           \
  assign PFX``_araddr   = '0;           \
  assign PFX``_arlen    = '0;           \
  assign PFX``_arsize   = '0;           \
  assign PFX``_arburst  = '0;           \
  assign PFX``_arlock   = 1'b0;         \
  assign PFX``_arcache  = '0;           \
  assign PFX``_arprot   = '0;           \
  assign PFX``_arqos    = '0;           \
  assign PFX``_arregion = '0;           \
  assign PFX``_arvalid  = 1'b0;         \
  assign PFX``_rready   = 1'b1

module aurora_region (
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
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_31,  64, 256, 4, 4),

  // Aurora 64b/66b user-side stream — clocked by aurora_user_clk
  // (not aclk).  Bring traffic across this RM by adding logic that
  // drives aurora_tx_* and consumes aurora_rx_*; cross-domain
  // handshakes between aclk and aurora_user_clk are the RM's
  // responsibility.
  input  wire         aurora_user_clk,
  input  wire         aurora_user_aresetn,
  input  wire         aurora_channel_up,
  output wire [255:0] aurora_tx_tdata,
  output wire  [31:0] aurora_tx_tkeep,
  output wire         aurora_tx_tlast,
  output wire         aurora_tx_tvalid,
  input  wire         aurora_tx_tready,
  input  wire [255:0] aurora_rx_tdata,
  input  wire  [31:0] aurora_rx_tkeep,
  input  wire         aurora_rx_tlast,
  input  wire         aurora_rx_tvalid,
  output wire [255:0] aurora_user_k_tx_tdata,
  output wire         aurora_user_k_tx_tvalid,
  input  wire         aurora_user_k_tx_tready,
  input  wire [255:0] aurora_user_k_rx_tdata,
  input  wire         aurora_user_k_rx_tvalid
);

  // ------------------------------------------------------------------
  // Partition-boundary tie-offs.  No HBM traffic; AXI-Lite slave idle.
  // ------------------------------------------------------------------
  `AXI_SLAVE_TIEOFF(s_axil);

  `AXI_MASTER_TIEOFF(m_axi_hbm_00);
  `AXI_MASTER_TIEOFF(m_axi_hbm_01);
  `AXI_MASTER_TIEOFF(m_axi_hbm_02);
  `AXI_MASTER_TIEOFF(m_axi_hbm_03);
  `AXI_MASTER_TIEOFF(m_axi_hbm_04);
  `AXI_MASTER_TIEOFF(m_axi_hbm_05);
  `AXI_MASTER_TIEOFF(m_axi_hbm_06);
  `AXI_MASTER_TIEOFF(m_axi_hbm_07);
  `AXI_MASTER_TIEOFF(m_axi_hbm_08);
  `AXI_MASTER_TIEOFF(m_axi_hbm_09);
  `AXI_MASTER_TIEOFF(m_axi_hbm_10);
  `AXI_MASTER_TIEOFF(m_axi_hbm_11);
  `AXI_MASTER_TIEOFF(m_axi_hbm_12);
  `AXI_MASTER_TIEOFF(m_axi_hbm_13);
  `AXI_MASTER_TIEOFF(m_axi_hbm_14);
  `AXI_MASTER_TIEOFF(m_axi_hbm_15);
  `AXI_MASTER_TIEOFF(m_axi_hbm_16);
  `AXI_MASTER_TIEOFF(m_axi_hbm_17);
  `AXI_MASTER_TIEOFF(m_axi_hbm_18);
  `AXI_MASTER_TIEOFF(m_axi_hbm_19);
  `AXI_MASTER_TIEOFF(m_axi_hbm_20);
  `AXI_MASTER_TIEOFF(m_axi_hbm_21);
  `AXI_MASTER_TIEOFF(m_axi_hbm_22);
  `AXI_MASTER_TIEOFF(m_axi_hbm_23);
  `AXI_MASTER_TIEOFF(m_axi_hbm_24);
  `AXI_MASTER_TIEOFF(m_axi_hbm_25);
  `AXI_MASTER_TIEOFF(m_axi_hbm_26);
  `AXI_MASTER_TIEOFF(m_axi_hbm_27);
  `AXI_MASTER_TIEOFF(m_axi_hbm_28);
  `AXI_MASTER_TIEOFF(m_axi_hbm_29);
  `AXI_MASTER_TIEOFF(m_axi_hbm_30);
  `AXI_MASTER_TIEOFF(m_axi_hbm_31);

  // ------------------------------------------------------------------
  // Aurora user-side scaffold.  The link is up (or coming up) thanks
  // to aurora_static in the static region; this RM has visibility but
  // doesn't transmit anything yet.  Replace the idle block below with
  // real producer / consumer logic when extending this RM.
  // ------------------------------------------------------------------
  assign aurora_tx_tdata        = 256'h0;
  assign aurora_tx_tkeep        = 32'h0;
  assign aurora_tx_tlast        = 1'b0;
  assign aurora_tx_tvalid       = 1'b0;
  assign aurora_user_k_tx_tdata  = 256'h0;
  assign aurora_user_k_tx_tvalid = 1'b0;

  // RX: nothing consumes the stream yet.  aurora_rx_tdata / tkeep /
  // tlast / tvalid arrive at line rate when the link is up; they're
  // currently sunk implicitly (no tready on Aurora's RX side).

endmodule : aurora_region

`undef AXI_SLAVE_FLAT_PORTS
`undef AXI_MASTER_FLAT_PORTS
`undef AXI_SLAVE_TIEOFF
`undef AXI_MASTER_TIEOFF
