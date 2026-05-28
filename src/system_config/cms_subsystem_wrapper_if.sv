// *************************************************************************
//
// Wraps the cms_subsystem_0 IP (xilinx.com:ip:cms_subsystem) using the
// project's axi_lite_if SystemVerilog interface.
//
// Vivado treats cms_subsystem as IPI-only and silently wraps it in a hidden
// block design (`bd_7485` in the .gen tree) when created via create_ip,
// but the resulting `cms_subsystem_0` Verilog module is plain RTL with the
// port list below — we instantiate it directly here so there is no
// stale BD-wrapper file in the source tree.
//
// *************************************************************************
`timescale 1ns/1ps
module cms_subsystem_wrapper_if (
  axi_lite_if.slave s_axil,

  // Satellite controller (microblaze on the card)
  input             satellite_uart_0_rxd,
  output            satellite_uart_0_txd,
  input       [1:0] satellite_gpio_0,

  // HBM temperature monitoring + cattrip alarm
  input       [6:0] hbm_temp_1_0,
  input       [6:0] hbm_temp_2_0,
  input             hbm_cattrip,

  // Interrupt to host
  output            interrupt_host
);

  cms_subsystem_0 u_cms (
    .aclk_ctrl             (s_axil.aclk),
    .aresetn_ctrl          (s_axil.aresetn),

    .satellite_gpio        (satellite_gpio_0),
    .satellite_uart_rxd    (satellite_uart_0_rxd),
    .satellite_uart_txd    (satellite_uart_0_txd),

    .hbm_temp_1            (hbm_temp_1_0),
    .hbm_temp_2            (hbm_temp_2_0),
    .interrupt_hbm_cattrip (hbm_cattrip),

    .interrupt_host        (interrupt_host),

    // AXI4-Lite control (the IP exposes a 32-bit address; host BAR
    // routing only ever drives the low 18 bits, the rest are zero).
    .s_axi_ctrl_awaddr     (s_axil.awaddr),
    .s_axi_ctrl_awprot     (s_axil.awprot),
    .s_axi_ctrl_awvalid    (s_axil.awvalid),
    .s_axi_ctrl_awready    (s_axil.awready),
    .s_axi_ctrl_wdata      (s_axil.wdata),
    .s_axi_ctrl_wstrb      (s_axil.wstrb),
    .s_axi_ctrl_wvalid     (s_axil.wvalid),
    .s_axi_ctrl_wready     (s_axil.wready),
    .s_axi_ctrl_bresp      (s_axil.bresp),
    .s_axi_ctrl_bvalid     (s_axil.bvalid),
    .s_axi_ctrl_bready     (s_axil.bready),
    .s_axi_ctrl_araddr     (s_axil.araddr),
    .s_axi_ctrl_arprot     (s_axil.arprot),
    .s_axi_ctrl_arvalid    (s_axil.arvalid),
    .s_axi_ctrl_arready    (s_axil.arready),
    .s_axi_ctrl_rdata      (s_axil.rdata),
    .s_axi_ctrl_rresp      (s_axil.rresp),
    .s_axi_ctrl_rvalid     (s_axil.rvalid),
    .s_axi_ctrl_rready     (s_axil.rready)
  );

endmodule: cms_subsystem_wrapper_if
