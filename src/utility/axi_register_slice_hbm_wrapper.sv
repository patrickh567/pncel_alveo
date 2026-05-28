// *************************************************************************
//
// Thin wrapper around `axi_register_slice_hbm` — a 256b AXI3 register
// slice used between each RM-driven HBM port and the HBM IP (see
// src/hbm/hbm_wrapper.sv).
//
// Width translation handled here:
//
//   * AWLEN / ARLEN: the axi_if is parameterised to LEN_W=4 on the HBM
//     ports, matching AXI3 — direct wires.
//
//   * AWLOCK / ARLOCK: AXI3 is 2-bit, the project's axi_if carries
//     1-bit lock (AXI4 convention).  Zero-extend the axi_if 1-bit lock
//     into the IP's 2-bit input; truncate the IP's 2-bit lock output
//     back to the 1-bit interface field (HBM IP ignores LOCK anyway,
//     so the dropped upper bit is consequence-free).
//
//   * AWREGION / ARREGION: AXI3 has no REGION.  The axi_if.awregion /
//     arregion fields stay unconnected on the slave side (no input to
//     the IP) and tied to 0 on the master side.
//
// *************************************************************************
`timescale 1ns/1ps
module axi_register_slice_hbm_wrapper (
  input         aclk,
  input         aresetn,

  axi_if.slave  s,
  axi_if.master m
);

  // 1-bit ↔ 2-bit LOCK conversion — see module header.
  wire [1:0] ip_s_awlock = {1'b0, s.awlock};
  wire [1:0] ip_s_arlock = {1'b0, s.arlock};
  wire [1:0] ip_m_awlock;
  wire [1:0] ip_m_arlock;
  assign m.awlock   = ip_m_awlock[0];
  assign m.arlock   = ip_m_arlock[0];

  // AXI3 has no REGION — downstream HBM IP doesn't consume it either.
  assign m.awregion = 4'b0;
  assign m.arregion = 4'b0;

  axi_register_slice_hbm u_rs (
    .aclk          (aclk),
    .aresetn       (aresetn),

    // Slave side
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
    .s_axi_wid     (s.awid),
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

    // Master side
    .m_axi_awid    (m.awid),
    .m_axi_awaddr  (m.awaddr),
    .m_axi_awlen   (m.awlen),
    .m_axi_awsize  (m.awsize),
    .m_axi_awburst (m.awburst),
    .m_axi_awlock  (ip_m_awlock),
    .m_axi_awcache (m.awcache),
    .m_axi_awprot  (m.awprot),
    .m_axi_awqos   (m.awqos),
    .m_axi_awvalid (m.awvalid),
    .m_axi_awready (m.awready),
    .m_axi_wid     (),
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
    .m_axi_arlock  (ip_m_arlock),
    .m_axi_arcache (m.arcache),
    .m_axi_arprot  (m.arprot),
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

endmodule
