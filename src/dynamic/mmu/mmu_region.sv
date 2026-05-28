// *************************************************************************
//
// MMU reconfig module wrapper for the dynamic PR partition.
//
// This is the top of the MMU reconfig module. Its port list must match
// `alveo_u50_dynamic_region` exactly (flat Verilog ports — required by
// DFX; every RM on a single partition must have an identical interface).
//
// Internally this module:
//   * Declares axi_if instances for the 1 AXI-Lite control slave and the
//     6 HBM master ports that mmu_top actually uses.
//   * Packs / unpacks the flat PR-boundary signals into those axi_if's.
//   * Instantiates mmu_top (one 32×32 instance for now — second
//     instance will land on m_axi_hbm_07..12 when added).
//   * Ties off the 26 HBM flat ports that mmu_top doesn't drive
//     (m_axi_hbm_00 + m_axi_hbm_07..31).  Note: m_axi_hbm_31 is the
//     muxed XDMA+RM path (4-bit ID); the direct ports use 6-bit IDs.
//
// HBM port mapping (flat ← mmu_top):
//
//   m_axi_hbm_01 ← m_axi_hbm_a0     m_axi_hbm_04 ← m_axi_hbm_c1
//   m_axi_hbm_02 ← m_axi_hbm_b0     m_axi_hbm_05 ← m_axi_hbm_c2
//   m_axi_hbm_03 ← m_axi_hbm_c0     m_axi_hbm_06 ← m_axi_hbm_c3
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

// Flat AXI-Lite slave inputs → IF; IF outputs → flat.
`define AXI_SLAVE_FLAT_TO_IF(PFX, IF)          \
  assign IF.awid     = PFX``_awid;             \
  assign IF.awaddr   = PFX``_awaddr;           \
  assign IF.awlen    = PFX``_awlen;            \
  assign IF.awsize   = PFX``_awsize;           \
  assign IF.awburst  = PFX``_awburst;          \
  assign IF.awlock   = PFX``_awlock;           \
  assign IF.awcache  = PFX``_awcache;          \
  assign IF.awprot   = PFX``_awprot;           \
  assign IF.awqos    = PFX``_awqos;            \
  assign IF.awregion = PFX``_awregion;         \
  assign IF.awvalid  = PFX``_awvalid;          \
  assign PFX``_awready = IF.awready;           \
  assign IF.wdata    = PFX``_wdata;            \
  assign IF.wstrb    = PFX``_wstrb;            \
  assign IF.wlast    = PFX``_wlast;            \
  assign IF.wvalid   = PFX``_wvalid;           \
  assign PFX``_wready  = IF.wready;            \
  assign PFX``_bid     = IF.bid;               \
  assign PFX``_bresp   = IF.bresp;             \
  assign PFX``_bvalid  = IF.bvalid;            \
  assign IF.bready   = PFX``_bready;           \
  assign IF.arid     = PFX``_arid;             \
  assign IF.araddr   = PFX``_araddr;           \
  assign IF.arlen    = PFX``_arlen;            \
  assign IF.arsize   = PFX``_arsize;           \
  assign IF.arburst  = PFX``_arburst;          \
  assign IF.arlock   = PFX``_arlock;           \
  assign IF.arcache  = PFX``_arcache;          \
  assign IF.arprot   = PFX``_arprot;           \
  assign IF.arqos    = PFX``_arqos;            \
  assign IF.arregion = PFX``_arregion;         \
  assign IF.arvalid  = PFX``_arvalid;          \
  assign PFX``_arready = IF.arready;           \
  assign PFX``_rid     = IF.rid;               \
  assign PFX``_rdata   = IF.rdata;             \
  assign PFX``_rresp   = IF.rresp;             \
  assign PFX``_rlast   = IF.rlast;             \
  assign PFX``_rvalid  = IF.rvalid;            \
  assign IF.rready   = PFX``_rready

// IF master outputs → flat; flat inputs → IF.
`define AXI_MASTER_IF_TO_FLAT(PFX, IF)         \
  assign PFX``_awid     = IF.awid;             \
  assign PFX``_awaddr   = IF.awaddr;           \
  assign PFX``_awlen    = IF.awlen;            \
  assign PFX``_awsize   = IF.awsize;           \
  assign PFX``_awburst  = IF.awburst;          \
  assign PFX``_awlock   = IF.awlock;           \
  assign PFX``_awcache  = IF.awcache;          \
  assign PFX``_awprot   = IF.awprot;           \
  assign PFX``_awqos    = IF.awqos;            \
  assign PFX``_awregion = IF.awregion;         \
  assign PFX``_awvalid  = IF.awvalid;          \
  assign IF.awready   = PFX``_awready;         \
  assign PFX``_wdata    = IF.wdata;            \
  assign PFX``_wstrb    = IF.wstrb;            \
  assign PFX``_wlast    = IF.wlast;            \
  assign PFX``_wvalid   = IF.wvalid;           \
  assign IF.wready    = PFX``_wready;          \
  assign IF.bid       = PFX``_bid;             \
  assign IF.bresp     = PFX``_bresp;           \
  assign IF.bvalid    = PFX``_bvalid;          \
  assign PFX``_bready   = IF.bready;           \
  assign PFX``_arid     = IF.arid;             \
  assign PFX``_araddr   = IF.araddr;           \
  assign PFX``_arlen    = IF.arlen;            \
  assign PFX``_arsize   = IF.arsize;           \
  assign PFX``_arburst  = IF.arburst;          \
  assign PFX``_arlock   = IF.arlock;           \
  assign PFX``_arcache  = IF.arcache;          \
  assign PFX``_arprot   = IF.arprot;           \
  assign PFX``_arqos    = IF.arqos;            \
  assign PFX``_arregion = IF.arregion;         \
  assign PFX``_arvalid  = IF.arvalid;          \
  assign IF.arready   = PFX``_arready;         \
  assign IF.rid       = PFX``_rid;             \
  assign IF.rdata     = PFX``_rdata;           \
  assign IF.rresp     = PFX``_rresp;           \
  assign IF.rlast     = PFX``_rlast;           \
  assign IF.rvalid    = PFX``_rvalid;          \
  assign PFX``_rready   = IF.rready

module mmu_region (
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
  // m_axi_hbm_31 is 256b AXI3 (4-bit ID, 4-bit AWLEN — see
  // alveo_u50_dynamic_region.sv).
  `AXI_MASTER_FLAT_PORTS(m_axi_hbm_31, 64, 256, 4, 4)
);

  // ------------------------------------------------------------------
  // Internal interface instances
  // ------------------------------------------------------------------
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1))            s_axil_if   (.aclk(aclk), .aresetn(aresetn));

  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_a0_if   (.aclk(aclk), .aresetn(aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_b0_if   (.aclk(aclk), .aresetn(aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_c0_if   (.aclk(aclk), .aresetn(aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_c1_if   (.aclk(aclk), .aresetn(aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_c2_if   (.aclk(aclk), .aresetn(aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_c3_if   (.aclk(aclk), .aresetn(aresetn));

  // ------------------------------------------------------------------
  // Flat <-> interface packing
  // ------------------------------------------------------------------
  `AXI_SLAVE_FLAT_TO_IF  (s_axil,       s_axil_if);

  `AXI_MASTER_IF_TO_FLAT (m_axi_hbm_01, hbm_a0_if);
  `AXI_MASTER_IF_TO_FLAT (m_axi_hbm_02, hbm_b0_if);
  `AXI_MASTER_IF_TO_FLAT (m_axi_hbm_03, hbm_c0_if);
  `AXI_MASTER_IF_TO_FLAT (m_axi_hbm_04, hbm_c1_if);
  `AXI_MASTER_IF_TO_FLAT (m_axi_hbm_05, hbm_c2_if);
  `AXI_MASTER_IF_TO_FLAT (m_axi_hbm_06, hbm_c3_if);

  // ------------------------------------------------------------------
  // MMU
  // ------------------------------------------------------------------
  mmu_top u_mmu (
    .clk           (aclk),
    .aresetn       (aresetn),
    .s_axil        (s_axil_if),
    .m_axi_hbm_a0  (hbm_a0_if),
    .m_axi_hbm_b0  (hbm_b0_if),
    .m_axi_hbm_c0  (hbm_c0_if),
    .m_axi_hbm_c1  (hbm_c1_if),
    .m_axi_hbm_c2  (hbm_c2_if),
    .m_axi_hbm_c3  (hbm_c3_if)
  );

  // ------------------------------------------------------------------
  // Unused partition ports — tie off
  // ------------------------------------------------------------------
  `AXI_MASTER_TIEOFF(m_axi_hbm_00);
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

endmodule : mmu_region

`undef AXI_SLAVE_FLAT_PORTS
`undef AXI_MASTER_FLAT_PORTS
`undef AXI_SLAVE_TIEOFF
`undef AXI_MASTER_TIEOFF
`undef AXI_SLAVE_FLAT_TO_IF
`undef AXI_MASTER_IF_TO_FLAT
