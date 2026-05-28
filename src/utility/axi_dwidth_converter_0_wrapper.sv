// *************************************************************************
//
// Thin wrapper around the `axi_dwidth_converter_0` IP.
//
// Widens the RM mux path from 256-bit AXI4 (output of
// axi_protocol_converter_0_wrapper, which lifted the RM's AXI3/256
// output to AXI4/256) to 512-bit AXI4 so it can plug into
// axi_hbm_switch.s01, which is uniform AXI4/512 across both slave
// ports.
//
// This IP is width-only — no protocol change.  Both sides are AXI4.
// The IP packs two 256-bit beats into one 512-bit beat on writes
// (and unpacks 512→256 on reads).
//
// In widening mode (SI < MI) the IP omits the master-side ID ports
// (`m_axi_*id`) — it tracks slave-side IDs internally and reconstructs
// `s_axi_bid` / `s_axi_rid` from its own outstanding-transaction
// FIFO, since the downstream slave responses come back in order.  We
// drive the axi_if's outgoing `m.awid`/`m.arid` to 0 (the downstream
// switch needs *some* ID; the IP just isn't the one supplying it),
// and leave incoming `m.bid`/`m.rid` unconnected — they're driven by
// the downstream slave but ignored here, since the IP regenerates
// the slave-side response IDs internally.
//
// *************************************************************************
`timescale 1ns/1ps
module axi_dwidth_converter_0_wrapper (
  input         aclk,
  input         aresetn,

  axi_if.slave  s,    // AXI4, 256 b, 64-bit addr, 4-bit ID, 8-bit AWLEN
  axi_if.master m     // AXI4, 512 b, 64-bit addr, 4-bit ID (driven to 0), 8-bit AWLEN
);

  // The IP's master side has no ID ports in widening mode.  Drive
  // the axi_if outputs to 0 since the downstream switch still expects
  // a value on awid / arid.
  assign m.awid = '0;
  assign m.arid = '0;

  axi_dwidth_converter_0 u_dw (
    .s_axi_aclk     (aclk),
    .s_axi_aresetn  (aresetn),

    // Slave side (AXI4 / 512 b)
    .s_axi_awid     (s.awid),
    .s_axi_awaddr   (s.awaddr),
    .s_axi_awlen    (s.awlen),
    .s_axi_awsize   (s.awsize),
    .s_axi_awburst  (s.awburst),
    .s_axi_awlock   (s.awlock),
    .s_axi_awcache  (s.awcache),
    .s_axi_awprot   (s.awprot),
    .s_axi_awregion (s.awregion),
    .s_axi_awqos    (s.awqos),
    .s_axi_awvalid  (s.awvalid),
    .s_axi_awready  (s.awready),
    .s_axi_wdata    (s.wdata),
    .s_axi_wstrb    (s.wstrb),
    .s_axi_wlast    (s.wlast),
    .s_axi_wvalid   (s.wvalid),
    .s_axi_wready   (s.wready),
    .s_axi_bid      (s.bid),
    .s_axi_bresp    (s.bresp),
    .s_axi_bvalid   (s.bvalid),
    .s_axi_bready   (s.bready),
    .s_axi_arid     (s.arid),
    .s_axi_araddr   (s.araddr),
    .s_axi_arlen    (s.arlen),
    .s_axi_arsize   (s.arsize),
    .s_axi_arburst  (s.arburst),
    .s_axi_arlock   (s.arlock),
    .s_axi_arcache  (s.arcache),
    .s_axi_arprot   (s.arprot),
    .s_axi_arregion (s.arregion),
    .s_axi_arqos    (s.arqos),
    .s_axi_arvalid  (s.arvalid),
    .s_axi_arready  (s.arready),
    .s_axi_rid      (s.rid),
    .s_axi_rdata    (s.rdata),
    .s_axi_rresp    (s.rresp),
    .s_axi_rlast    (s.rlast),
    .s_axi_rvalid   (s.rvalid),
    .s_axi_rready   (s.rready),

    // Master side (AXI4 / 512 b) — note: no m_axi_*id ports in
    // widening mode; the IP regenerates s_axi_bid / s_axi_rid from
    // its internal outstanding-transaction FIFO.
    .m_axi_awaddr   (m.awaddr),
    .m_axi_awlen    (m.awlen),
    .m_axi_awsize   (m.awsize),
    .m_axi_awburst  (m.awburst),
    .m_axi_awlock   (m.awlock),
    .m_axi_awcache  (m.awcache),
    .m_axi_awprot   (m.awprot),
    .m_axi_awregion (m.awregion),
    .m_axi_awqos    (m.awqos),
    .m_axi_awvalid  (m.awvalid),
    .m_axi_awready  (m.awready),
    .m_axi_wdata    (m.wdata),
    .m_axi_wstrb    (m.wstrb),
    .m_axi_wlast    (m.wlast),
    .m_axi_wvalid   (m.wvalid),
    .m_axi_wready   (m.wready),
    .m_axi_bresp    (m.bresp),
    .m_axi_bvalid   (m.bvalid),
    .m_axi_bready   (m.bready),
    .m_axi_araddr   (m.araddr),
    .m_axi_arlen    (m.arlen),
    .m_axi_arsize   (m.arsize),
    .m_axi_arburst  (m.arburst),
    .m_axi_arlock   (m.arlock),
    .m_axi_arcache  (m.arcache),
    .m_axi_arprot   (m.arprot),
    .m_axi_arregion (m.arregion),
    .m_axi_arqos    (m.arqos),
    .m_axi_arvalid  (m.arvalid),
    .m_axi_arready  (m.arready),
    .m_axi_rdata    (m.rdata),
    .m_axi_rresp    (m.rresp),
    .m_axi_rlast    (m.rlast),
    .m_axi_rvalid   (m.rvalid),
    .m_axi_rready   (m.rready)
  );

endmodule : axi_dwidth_converter_0_wrapper
