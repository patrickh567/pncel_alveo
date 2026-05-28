// *************************************************************************
//
// Thin wrapper around the `axi_protocol_converter_0` IP.
//
// Lifts the RM mux path from AXI3/256 (RM-native, matches the loopback
// engine's HBM-port shape) to AXI4/256.  Paired with
// `axi_dwidth_converter_0_wrapper` immediately downstream, which then
// widens the AXI4 bus to 512b for axi_hbm_switch.s01 — the hbm switch
// IP forces uniform protocol/width on both slave ports, so the RM
// branch has to climb up to s00's native AXI4/512 shape before
// reaching the switch.
//
// Width is 256 b on both sides (this IP is protocol-only).  AXI3
// quirks handled here:
//
//   * AWLOCK / ARLOCK: the slave-side IP port is 2-bit AXI3 lock;
//     zero-extend from the axi_if's 1-bit AXI4 lock.
//
//   * AWLEN / ARLEN: AXI3 = 4-bit, the slave axi_if uses LEN_W=4 too,
//     so direct connection.
//
//   * AWREGION / ARREGION: AXI3 has no REGION on the slave side.  The
//     AXI4 master side does — tied to 0 since the upstream RM doesn't
//     drive region.
//
// *************************************************************************
`timescale 1ns/1ps
module axi_protocol_converter_0_wrapper (
  input         aclk,
  input         aresetn,

  axi_if.slave  s,    // AXI3, 256 b, 64-bit addr, 4-bit ID, 4-bit AWLEN
  axi_if.master m     // AXI4, 256 b, 64-bit addr, 4-bit ID, 8-bit AWLEN
);

  // 1-bit ↔ 2-bit LOCK conversion on the AXI3 slave side.
  wire [1:0] ip_s_awlock = {1'b0, s.awlock};
  wire [1:0] ip_s_arlock = {1'b0, s.arlock};

  axi_protocol_converter_0 u_pc (
    .aclk          (aclk),
    .aresetn       (aresetn),

    // Slave side (AXI3 / 256 b)
    .s_axi_awid    (s.awid),
    .s_axi_awaddr  (s.awaddr),
    .s_axi_awlen   (s.awlen),
    .s_axi_awsize  (s.awsize),
    .s_axi_awburst (s.awburst),
    .s_axi_awlock  (ip_s_awlock),
    .s_axi_awcache (s.awcache),
    .s_axi_awprot  (s.awprot),
    .s_axi_awqos   (s.awqos),
    .s_axi_awvalid (s.awvalid),
    .s_axi_awready (s.awready),
    .s_axi_wid     (s.awid),       // AXI3 wid; not interleaved
    .s_axi_wdata   (s.wdata),
    .s_axi_wstrb   (s.wstrb),
    .s_axi_wlast   (s.wlast),
    .s_axi_wvalid  (s.wvalid),
    .s_axi_wready  (s.wready),
    .s_axi_bid     (s.bid),
    .s_axi_bresp   (s.bresp),
    .s_axi_bvalid  (s.bvalid),
    .s_axi_bready  (s.bready),
    .s_axi_arid    (s.arid),
    .s_axi_araddr  (s.araddr),
    .s_axi_arlen   (s.arlen),
    .s_axi_arsize  (s.arsize),
    .s_axi_arburst (s.arburst),
    .s_axi_arlock  (ip_s_arlock),
    .s_axi_arcache (s.arcache),
    .s_axi_arprot  (s.arprot),
    .s_axi_arqos   (s.arqos),
    .s_axi_arvalid (s.arvalid),
    .s_axi_arready (s.arready),
    .s_axi_rid     (s.rid),
    .s_axi_rdata   (s.rdata),
    .s_axi_rresp   (s.rresp),
    .s_axi_rlast   (s.rlast),
    .s_axi_rvalid  (s.rvalid),
    .s_axi_rready  (s.rready),

    // Master side (AXI4 / 256 b)
    .m_axi_awid    (m.awid),
    .m_axi_awaddr  (m.awaddr),
    .m_axi_awlen   (m.awlen),
    .m_axi_awsize  (m.awsize),
    .m_axi_awburst (m.awburst),
    .m_axi_awlock  (m.awlock),
    .m_axi_awcache (m.awcache),
    .m_axi_awprot  (m.awprot),
    .m_axi_awregion(m.awregion),
    .m_axi_awqos   (m.awqos),
    .m_axi_awvalid (m.awvalid),
    .m_axi_awready (m.awready),
    .m_axi_wdata   (m.wdata),
    .m_axi_wstrb   (m.wstrb),
    .m_axi_wlast   (m.wlast),
    .m_axi_wvalid  (m.wvalid),
    .m_axi_wready  (m.wready),
    .m_axi_bid     (m.bid),
    .m_axi_bresp   (m.bresp),
    .m_axi_bvalid  (m.bvalid),
    .m_axi_bready  (m.bready),
    .m_axi_arid    (m.arid),
    .m_axi_araddr  (m.araddr),
    .m_axi_arlen   (m.arlen),
    .m_axi_arsize  (m.arsize),
    .m_axi_arburst (m.arburst),
    .m_axi_arlock  (m.arlock),
    .m_axi_arcache (m.arcache),
    .m_axi_arprot  (m.arprot),
    .m_axi_arregion(m.arregion),
    .m_axi_arqos   (m.arqos),
    .m_axi_arvalid (m.arvalid),
    .m_axi_arready (m.arready),
    .m_axi_rid     (m.rid),
    .m_axi_rdata   (m.rdata),
    .m_axi_rresp   (m.rresp),
    .m_axi_rlast   (m.rlast),
    .m_axi_rvalid  (m.rvalid),
    .m_axi_rready  (m.rready)
  );

endmodule : axi_protocol_converter_0_wrapper
