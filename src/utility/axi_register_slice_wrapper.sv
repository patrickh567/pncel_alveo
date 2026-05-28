// *************************************************************************
//
// Thin wrapper around the `axi_register_slice_rp` IP — translates the
// project's `axi_if` SystemVerilog interface into the IP's flat
// s_axi_* / m_axi_* signal list.
//
// The IP is configured once for 512b AXI4 / 64b addr / 4b ID at
// src/utility/vivado_ip/axi_register_slice_rp.tcl.  The wrapper is
// instantiated twice inside the static region (see alveo_u50_static.sv)
// to cut the combinational paths flowing into and out of the RP
// partition on the DMA buses.
//
// *************************************************************************
`timescale 1ns/1ps
module axi_register_slice_wrapper (
  input         aclk,
  input         aresetn,

  axi_if.slave  s,
  axi_if.master m
);

  axi_register_slice_rp u_rs (
    .aclk          (aclk),
    .aresetn       (aresetn),

    // Slave side
    .s_axi_awid    (s.awid),
    .s_axi_awaddr  (s.awaddr),
    .s_axi_awlen   (s.awlen),
    .s_axi_awsize  (s.awsize),
    .s_axi_awburst (s.awburst),
    .s_axi_awlock  (s.awlock),
    .s_axi_awcache (s.awcache),
    .s_axi_awprot  (s.awprot),
    .s_axi_awqos   (s.awqos),
    .s_axi_awregion(s.awregion),
    .s_axi_awvalid (s.awvalid),
    .s_axi_awready (s.awready),
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
    .s_axi_arlock  (s.arlock),
    .s_axi_arcache (s.arcache),
    .s_axi_arprot  (s.arprot),
    .s_axi_arqos   (s.arqos),
    .s_axi_arregion(s.arregion),
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
    .m_axi_awlock  (m.awlock),
    .m_axi_awcache (m.awcache),
    .m_axi_awprot  (m.awprot),
    .m_axi_awqos   (m.awqos),
    .m_axi_awregion(m.awregion),
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
    .m_axi_arqos   (m.arqos),
    .m_axi_arregion(m.arregion),
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
