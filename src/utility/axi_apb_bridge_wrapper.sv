// *************************************************************************
//
// Wrapper around Xilinx AXI-to-APB Bridge IP (1 AXI-Lite slave, 2 APB masters)
//
// *************************************************************************
`timescale 1ns/1ps
module axi_apb_bridge_wrapper (
  // AXI-Lite slave
  axi_if.slave    s_axi,

  // APB master ports
  apb_if.master   m_apb_0,
  apb_if.master   m_apb_1
);

  // Internal wires for multi-port APB signals
  wire  [1:0] psel;
  wire  [1:0] pready;
  wire  [1:0] pslverr;

  assign m_apb_0.psel = psel[0];
  assign m_apb_1.psel = psel[1];
  assign pready  = {m_apb_1.pready,  m_apb_0.pready};
  assign pslverr = {m_apb_1.pslverr, m_apb_0.pslverr};

  axi_apb_bridge_0 u_axi_apb_bridge (
    .s_axi_aclk    (s_axi.aclk),
    .s_axi_aresetn (s_axi.aresetn),

    .s_axi_awaddr  (s_axi.awaddr),
    .s_axi_awvalid (s_axi.awvalid),
    .s_axi_awready (s_axi.awready),
    .s_axi_wdata   (s_axi.wdata),
    .s_axi_wvalid  (s_axi.wvalid),
    .s_axi_wready  (s_axi.wready),
    .s_axi_bresp   (s_axi.bresp),
    .s_axi_bvalid  (s_axi.bvalid),
    .s_axi_bready  (s_axi.bready),
    .s_axi_araddr  (s_axi.araddr),
    .s_axi_arvalid (s_axi.arvalid),
    .s_axi_arready (s_axi.arready),
    .s_axi_rdata   (s_axi.rdata),
    .s_axi_rresp   (s_axi.rresp),
    .s_axi_rvalid  (s_axi.rvalid),
    .s_axi_rready  (s_axi.rready),

    .m_apb_paddr   (m_apb_0.paddr),
    .m_apb_psel    (psel),
    .m_apb_penable (m_apb_0.penable),
    .m_apb_pwrite  (m_apb_0.pwrite),
    .m_apb_pwdata  (m_apb_0.pwdata),
    .m_apb_pready  (pready),
    .m_apb_prdata  (m_apb_0.prdata),
    .m_apb_prdata2 (m_apb_1.prdata),
    .m_apb_pslverr (pslverr)
  );

  // Shared signals: penable, pwrite, paddr, pwdata are common to both APB ports
  assign m_apb_1.penable = m_apb_0.penable;
  assign m_apb_1.pwrite  = m_apb_0.pwrite;
  assign m_apb_1.paddr   = m_apb_0.paddr;
  assign m_apb_1.pwdata  = m_apb_0.pwdata;

endmodule: axi_apb_bridge_wrapper
