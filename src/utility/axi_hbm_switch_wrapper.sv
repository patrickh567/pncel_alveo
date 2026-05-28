// *************************************************************************
//
// Wrapper around the axi_hbm_switch IP — AXI4-Full HBM access merger
// (2 slaves, 1 master).
//
// *************************************************************************
`timescale 1ns/1ps
module axi_hbm_switch_wrapper (
  input        aclk,
  input        aresetn,

  // Slave ports
  axi_if.slave  s00,
  axi_if.slave  s01,

  // Master port
  axi_if.master m00,

  // Switch status
  output       aresetn_out,
  output       pc_asserted,
  output [2:0] pc_status
);

  // The axi_switch IP auto-narrows the master ID width to 1 bit
  // (NUM_SI=1, no slave-tag required), but the m00 interface has
  // 6-bit IDs to match the downstream HBM IP port.
  //
  // AW/AR direction (switch OUTPUTS): use intermediate wires to
  // capture the IP's 1-bit ID output, then zero-extend to drive the
  // full 6-bit interface field.  A naive `.m00_axi_awid(m00.awid[0])`
  // drives only bit 0 and leaves bits [5:1] floating, which shows up
  // as X on the HBM IP's AWID input and breaks its internal
  // ID-tracking after the first transaction.
  //
  // B/R direction (switch INPUTS): plain bit-select on the port
  // connection is fine — the full 6-bit m00.bid/rid is already
  // driven by the downstream HBM wrapper, and the switch just needs
  // to read bit 0.
  //
  // Lock adaptation: the switch's m00 is AXI3 (2-bit lock), the
  // axi_if uses AXI4 (1-bit lock).  The switch drives a 2-bit output
  // that we truncate to 1 bit via an intermediate wire — the "locked"
  // bit (AXI3 lock[1]) is dropped, keeping only the "exclusive" bit
  // (AXI3 lock[0] == AXI4 lock).  The design doesn't use locked
  // accesses, so this truncation is safe.
  //
  // Both S ports are AXI4/256 (uniform — the IP forces matching slave
  // protocols).  An `axi_dwidth_converter` brings the XDMA AXI4/512
  // path down to 256 ahead of S00; an `axi_protocol_converter` lifts
  // the RM AXI3/256 path up to AXI4/256 ahead of S01.
  wire       m00_awid_1b;
  wire       m00_arid_1b;
  wire [1:0] m00_awlock_axi3;
  wire [1:0] m00_arlock_axi3;

  assign m00.awid   = { {5{1'b0}}, m00_awid_1b };
  assign m00.arid   = { {5{1'b0}}, m00_arid_1b };
  assign m00.awlock = m00_awlock_axi3[0];
  assign m00.arlock = m00_arlock_axi3[0];

  axi_hbm_switch u_switch (
    .aclk              (aclk),
    .aresetn           (aresetn),
    .aresetn_out       (aresetn_out),
    .pc_asserted       (pc_asserted),
    .pc_status         (pc_status),

    // Slave port s00 (AXI4, 256 b — XDMA path after axi_dwidth_converter)
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

    // Slave port s01 (AXI4, 256 b — RM path after axi_protocol_converter)
    .s01_axi_awid      (s01.awid),
    .s01_axi_awaddr    (s01.awaddr),
    .s01_axi_awlen     (s01.awlen),
    .s01_axi_awsize    (s01.awsize),
    .s01_axi_awburst   (s01.awburst),
    .s01_axi_awlock    (s01.awlock),
    .s01_axi_awcache   (s01.awcache),
    .s01_axi_awprot    (s01.awprot),
    .s01_axi_awqos     (s01.awqos),
    .s01_axi_awuser    (1'b0),
    .s01_axi_awvalid   (s01.awvalid),
    .s01_axi_awready   (s01.awready),
    .s01_axi_wdata     (s01.wdata),
    .s01_axi_wstrb     (s01.wstrb),
    .s01_axi_wlast     (s01.wlast),
    .s01_axi_wuser     (1'b0),
    .s01_axi_wvalid    (s01.wvalid),
    .s01_axi_wready    (s01.wready),
    .s01_axi_bid       (s01.bid),
    .s01_axi_bresp     (s01.bresp),
    .s01_axi_buser     (),
    .s01_axi_bvalid    (s01.bvalid),
    .s01_axi_bready    (s01.bready),
    .s01_axi_arid      (s01.arid),
    .s01_axi_araddr    (s01.araddr),
    .s01_axi_arlen     (s01.arlen),
    .s01_axi_arsize    (s01.arsize),
    .s01_axi_arburst   (s01.arburst),
    .s01_axi_arlock    (s01.arlock),
    .s01_axi_arcache   (s01.arcache),
    .s01_axi_arprot    (s01.arprot),
    .s01_axi_arqos     (s01.arqos),
    .s01_axi_aruser    (1'b0),
    .s01_axi_arvalid   (s01.arvalid),
    .s01_axi_arready   (s01.arready),
    .s01_axi_rid       (s01.rid),
    .s01_axi_rdata     (s01.rdata),
    .s01_axi_rresp     (s01.rresp),
    .s01_axi_rlast     (s01.rlast),
    .s01_axi_ruser     (),
    .s01_axi_rvalid    (s01.rvalid),
    .s01_axi_rready    (s01.rready),

    // Master port m00 (AXI3 to HBM)
    .m00_axi_awid      (m00_awid_1b),    // see wire declaration above
    .m00_axi_awaddr    (m00.awaddr),
    .m00_axi_awlen     (m00.awlen),
    .m00_axi_awsize    (m00.awsize),
    .m00_axi_awburst   (m00.awburst),
    .m00_axi_awlock    (m00_awlock_axi3),
    .m00_axi_awcache   (m00.awcache),
    .m00_axi_awprot    (m00.awprot),
    .m00_axi_awqos     (m00.awqos),
    .m00_axi_awuser    (),
    .m00_axi_awvalid   (m00.awvalid),
    .m00_axi_awready   (m00.awready),
    .m00_axi_wdata     (m00.wdata),
    .m00_axi_wid       (),               // AXI3 write-ID: IP output, unused
    .m00_axi_wstrb     (m00.wstrb),
    .m00_axi_wlast     (m00.wlast),
    .m00_axi_wuser     (),
    .m00_axi_wvalid    (m00.wvalid),
    .m00_axi_wready    (m00.wready),
    .m00_axi_bid       (m00.bid[0]),     // 6→1 bit select
    .m00_axi_bresp     (m00.bresp),
    .m00_axi_buser     (1'b0),
    .m00_axi_bvalid    (m00.bvalid),
    .m00_axi_bready    (m00.bready),
    .m00_axi_arid      (m00_arid_1b),    // see wire declaration above
    .m00_axi_araddr    (m00.araddr),
    .m00_axi_arlen     (m00.arlen),
    .m00_axi_arsize    (m00.arsize),
    .m00_axi_arburst   (m00.arburst),
    .m00_axi_arlock    (m00_arlock_axi3),
    .m00_axi_arcache   (m00.arcache),
    .m00_axi_arprot    (m00.arprot),
    .m00_axi_arqos     (m00.arqos),
    .m00_axi_aruser    (),
    .m00_axi_arvalid   (m00.arvalid),
    .m00_axi_arready   (m00.arready),
    .m00_axi_rid       (m00.rid[0]),     // 6→1 bit select
    .m00_axi_rdata     (m00.rdata),
    .m00_axi_rresp     (m00.rresp),
    .m00_axi_rlast     (m00.rlast),
    .m00_axi_ruser     (1'b0),
    .m00_axi_rvalid    (m00.rvalid),
    .m00_axi_rready    (m00.rready)
  );

endmodule: axi_hbm_switch_wrapper
