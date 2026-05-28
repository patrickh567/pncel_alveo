// *************************************************************************
//
// Wrapper around the axi_dma_switch IP — AXI4-Full DMA path splitter
// (1 slave, 2 masters).
//
// The XDMA DMA bus fans out to:
//   m00 — 512-bit HBM-direct path (feeds axi_hbm_switch.S00)
//   m01 — 32-bit HBICAP path (the IP handles 512→32 width conversion)
//
// The DMA→RM master that this switch used to expose was removed when the
// dynamic-region DMA slave went away; the RM does its own HBM access
// over m_axi_hbm_00..31 without needing an XDMA-driven AXI4
// slave inside the partition.
//
// *************************************************************************
`timescale 1ns/1ps
module axi_dma_switch_wrapper (
  input        aclk,
  input        aresetn,

  // Slave port
  axi_if.slave  s00,

  // Master ports — m00 is 256-bit (aurora bridge data path / RM), m01 is
  // 32-bit (HBICAP bitstream).  m02 is a new 256-bit AXI4 leg added for
  // pncel's XDMA→HBM-port-31 direct path; binding it is optional —
  // callers that don't need it can pass a dangling axi_if.
  axi_if.master m00,
  axi_if.master m01,
  axi_if.master m02,

  // Switch status
  output       aresetn_out,
  output       pc_asserted,
  output [1:0] pc_status
);

  // The axi_switch IP auto-narrows each master's ID to 1 bit
  // (NUM_SI=1, no slave-tag needed); the interfaces have 4-bit IDs.
  wire m00_awid_1b, m00_arid_1b;
  wire m01_awid_1b, m01_arid_1b;
  wire m02_awid_1b, m02_arid_1b;

  assign m00.awid = { {3{1'b0}}, m00_awid_1b };
  assign m00.arid = { {3{1'b0}}, m00_arid_1b };
  assign m01.awid = { {3{1'b0}}, m01_awid_1b };
  assign m01.arid = { {3{1'b0}}, m01_arid_1b };
  assign m02.awid = { {3{1'b0}}, m02_awid_1b };
  assign m02.arid = { {3{1'b0}}, m02_arid_1b };

  axi_dma_switch u_switch (
    .aclk              (aclk),
    .aresetn           (aresetn),
    .aresetn_out       (aresetn_out),
    .pc_asserted       (pc_asserted),
    .pc_status         (pc_status),

    // Slave port s00
    .s00_axi_awid      (s00.awid),
    .s00_axi_awaddr    (s00.awaddr),
    .s00_axi_awlen     (s00.awlen),
    .s00_axi_awsize    (s00.awsize),
    .s00_axi_awburst   (s00.awburst),
    .s00_axi_awlock    (s00.awlock),
    .s00_axi_awcache   (s00.awcache),
    .s00_axi_awprot    (s00.awprot),
    .s00_axi_awqos     (s00.awqos),
    .s00_axi_awuser    (1'b0),
    .s00_axi_awvalid   (s00.awvalid),
    .s00_axi_awready   (s00.awready),
    .s00_axi_wdata     (s00.wdata),
    .s00_axi_wstrb     (s00.wstrb),
    .s00_axi_wlast     (s00.wlast),
    .s00_axi_wuser     (1'b0),
    .s00_axi_wvalid    (s00.wvalid),
    .s00_axi_wready    (s00.wready),
    .s00_axi_bid       (s00.bid),
    .s00_axi_bresp     (s00.bresp),
    .s00_axi_buser     (),
    .s00_axi_bvalid    (s00.bvalid),
    .s00_axi_bready    (s00.bready),
    .s00_axi_arid      (s00.arid),
    .s00_axi_araddr    (s00.araddr),
    .s00_axi_arlen     (s00.arlen),
    .s00_axi_arsize    (s00.arsize),
    .s00_axi_arburst   (s00.arburst),
    .s00_axi_arlock    (s00.arlock),
    .s00_axi_arcache   (s00.arcache),
    .s00_axi_arprot    (s00.arprot),
    .s00_axi_arqos     (s00.arqos),
    .s00_axi_aruser    (1'b0),
    .s00_axi_arvalid   (s00.arvalid),
    .s00_axi_arready   (s00.arready),
    .s00_axi_rid       (s00.rid),
    .s00_axi_rdata     (s00.rdata),
    .s00_axi_rresp     (s00.rresp),
    .s00_axi_rlast     (s00.rlast),
    .s00_axi_ruser     (),
    .s00_axi_rvalid    (s00.rvalid),
    .s00_axi_rready    (s00.rready),

    // Master port m00 (HBM, 512-bit)
    .m00_axi_awid      (m00_awid_1b),
    .m00_axi_awaddr    (m00.awaddr),
    .m00_axi_awlen     (m00.awlen),
    .m00_axi_awsize    (m00.awsize),
    .m00_axi_awburst   (m00.awburst),
    .m00_axi_awlock    (m00.awlock),
    .m00_axi_awcache   (m00.awcache),
    .m00_axi_awprot    (m00.awprot),
    .m00_axi_awqos     (m00.awqos),
    .m00_axi_awuser    (),
    .m00_axi_awvalid   (m00.awvalid),
    .m00_axi_awready   (m00.awready),
    .m00_axi_wdata     (m00.wdata),
    .m00_axi_wstrb     (m00.wstrb),
    .m00_axi_wlast     (m00.wlast),
    .m00_axi_wuser     (),
    .m00_axi_wvalid    (m00.wvalid),
    .m00_axi_wready    (m00.wready),
    .m00_axi_bid       (m00.bid[0]),
    .m00_axi_bresp     (m00.bresp),
    .m00_axi_buser     (1'b0),
    .m00_axi_bvalid    (m00.bvalid),
    .m00_axi_bready    (m00.bready),
    .m00_axi_arid      (m00_arid_1b),
    .m00_axi_araddr    (m00.araddr),
    .m00_axi_arlen     (m00.arlen),
    .m00_axi_arsize    (m00.arsize),
    .m00_axi_arburst   (m00.arburst),
    .m00_axi_arlock    (m00.arlock),
    .m00_axi_arcache   (m00.arcache),
    .m00_axi_arprot    (m00.arprot),
    .m00_axi_arqos     (m00.arqos),
    .m00_axi_aruser    (),
    .m00_axi_arvalid   (m00.arvalid),
    .m00_axi_arready   (m00.arready),
    .m00_axi_rid       (m00.rid[0]),
    .m00_axi_rdata     (m00.rdata),
    .m00_axi_rresp     (m00.rresp),
    .m00_axi_rlast     (m00.rlast),
    .m00_axi_ruser     (1'b0),
    .m00_axi_rvalid    (m00.rvalid),
    .m00_axi_rready    (m00.rready),

    // Master port m01 (HBICAP, 32-bit data)
    .m01_axi_awid      (m01_awid_1b),
    .m01_axi_awaddr    (m01.awaddr),
    .m01_axi_awlen     (m01.awlen),
    .m01_axi_awsize    (m01.awsize),
    .m01_axi_awburst   (m01.awburst),
    .m01_axi_awlock    (m01.awlock),
    .m01_axi_awcache   (m01.awcache),
    .m01_axi_awprot    (m01.awprot),
    .m01_axi_awqos     (m01.awqos),
    .m01_axi_awuser    (),
    .m01_axi_awvalid   (m01.awvalid),
    .m01_axi_awready   (m01.awready),
    .m01_axi_wdata     (m01.wdata),
    .m01_axi_wstrb     (m01.wstrb),
    .m01_axi_wlast     (m01.wlast),
    .m01_axi_wuser     (),
    .m01_axi_wvalid    (m01.wvalid),
    .m01_axi_wready    (m01.wready),
    .m01_axi_bid       (m01.bid[0]),
    .m01_axi_bresp     (m01.bresp),
    .m01_axi_buser     (1'b0),
    .m01_axi_bvalid    (m01.bvalid),
    .m01_axi_bready    (m01.bready),
    .m01_axi_arid      (m01_arid_1b),
    .m01_axi_araddr    (m01.araddr),
    .m01_axi_arlen     (m01.arlen),
    .m01_axi_arsize    (m01.arsize),
    .m01_axi_arburst   (m01.arburst),
    .m01_axi_arlock    (m01.arlock),
    .m01_axi_arcache   (m01.arcache),
    .m01_axi_arprot    (m01.arprot),
    .m01_axi_arqos     (m01.arqos),
    .m01_axi_aruser    (),
    .m01_axi_arvalid   (m01.arvalid),
    .m01_axi_arready   (m01.arready),
    .m01_axi_rid       (m01.rid[0]),
    .m01_axi_rdata     (m01.rdata),
    .m01_axi_rresp     (m01.rresp),
    .m01_axi_rlast     (m01.rlast),
    .m01_axi_ruser     (1'b0),
    .m01_axi_rvalid    (m01.rvalid),
    .m01_axi_rready    (m01.rready),

    // Master port m02 (XDMA → HBM port 31, 256-bit AXI4)
    .m02_axi_awid      (m02_awid_1b),
    .m02_axi_awaddr    (m02.awaddr),
    .m02_axi_awlen     (m02.awlen),
    .m02_axi_awsize    (m02.awsize),
    .m02_axi_awburst   (m02.awburst),
    .m02_axi_awlock    (m02.awlock),
    .m02_axi_awcache   (m02.awcache),
    .m02_axi_awprot    (m02.awprot),
    .m02_axi_awqos     (m02.awqos),
    .m02_axi_awuser    (),
    .m02_axi_awvalid   (m02.awvalid),
    .m02_axi_awready   (m02.awready),
    .m02_axi_wdata     (m02.wdata),
    .m02_axi_wstrb     (m02.wstrb),
    .m02_axi_wlast     (m02.wlast),
    .m02_axi_wuser     (),
    .m02_axi_wvalid    (m02.wvalid),
    .m02_axi_wready    (m02.wready),
    .m02_axi_bid       (m02.bid[0]),
    .m02_axi_bresp     (m02.bresp),
    .m02_axi_buser     (1'b0),
    .m02_axi_bvalid    (m02.bvalid),
    .m02_axi_bready    (m02.bready),
    .m02_axi_arid      (m02_arid_1b),
    .m02_axi_araddr    (m02.araddr),
    .m02_axi_arlen     (m02.arlen),
    .m02_axi_arsize    (m02.arsize),
    .m02_axi_arburst   (m02.arburst),
    .m02_axi_arlock    (m02.arlock),
    .m02_axi_arcache   (m02.arcache),
    .m02_axi_arprot    (m02.arprot),
    .m02_axi_arqos     (m02.arqos),
    .m02_axi_aruser    (),
    .m02_axi_arvalid   (m02.arvalid),
    .m02_axi_arready   (m02.arready),
    .m02_axi_rid       (m02.rid[0]),
    .m02_axi_rdata     (m02.rdata),
    .m02_axi_rresp     (m02.rresp),
    .m02_axi_rlast     (m02.rlast),
    .m02_axi_ruser     (1'b0),
    .m02_axi_rvalid    (m02.rvalid),
    .m02_axi_rready    (m02.rready)
  );

endmodule: axi_dma_switch_wrapper
