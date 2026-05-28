// *************************************************************************
//
// mini_dice_alveo dynamic region — axi_if-to-flat shim.
//
// Mirrors pncel_dynamic.sv: takes axi_if-style ports from the parent
// (mini_dice_alveo.sv) and forwards them as flat Verilog ports into the
// PR partition body (`mini_dice_alveo_dynamic_region`).  Vivado's DFX
// flow requires flat ports on the partition boundary.
//
// No aurora ports here — this image doesn't have an Aurora link.  XDMA's
// AXI-Lite path (s_axil_ctrl) drives the chip's CSR/launch FIFO directly.
//
// *************************************************************************
`timescale 1ns/1ps

`define AXI_IF_TO_FLAT(PFX)               \
  .PFX``_awid     (PFX.awid),             \
  .PFX``_awaddr   (PFX.awaddr),           \
  .PFX``_awlen    (PFX.awlen),            \
  .PFX``_awsize   (PFX.awsize),           \
  .PFX``_awburst  (PFX.awburst),          \
  .PFX``_awlock   (PFX.awlock),           \
  .PFX``_awcache  (PFX.awcache),          \
  .PFX``_awprot   (PFX.awprot),           \
  .PFX``_awqos    (PFX.awqos),            \
  .PFX``_awregion (PFX.awregion),         \
  .PFX``_awvalid  (PFX.awvalid),          \
  .PFX``_awready  (PFX.awready),          \
  .PFX``_wdata    (PFX.wdata),            \
  .PFX``_wstrb    (PFX.wstrb),            \
  .PFX``_wlast    (PFX.wlast),            \
  .PFX``_wvalid   (PFX.wvalid),           \
  .PFX``_wready   (PFX.wready),           \
  .PFX``_bid      (PFX.bid),              \
  .PFX``_bresp    (PFX.bresp),            \
  .PFX``_bvalid   (PFX.bvalid),           \
  .PFX``_bready   (PFX.bready),           \
  .PFX``_arid     (PFX.arid),             \
  .PFX``_araddr   (PFX.araddr),           \
  .PFX``_arlen    (PFX.arlen),            \
  .PFX``_arsize   (PFX.arsize),           \
  .PFX``_arburst  (PFX.arburst),          \
  .PFX``_arlock   (PFX.arlock),           \
  .PFX``_arcache  (PFX.arcache),          \
  .PFX``_arprot   (PFX.arprot),           \
  .PFX``_arqos    (PFX.arqos),            \
  .PFX``_arregion (PFX.arregion),         \
  .PFX``_arvalid  (PFX.arvalid),          \
  .PFX``_arready  (PFX.arready),          \
  .PFX``_rid      (PFX.rid),              \
  .PFX``_rdata    (PFX.rdata),            \
  .PFX``_rresp    (PFX.rresp),            \
  .PFX``_rlast    (PFX.rlast),            \
  .PFX``_rvalid   (PFX.rvalid),           \
  .PFX``_rready   (PFX.rready)

module mini_dice_alveo_dynamic (
  input          aresetn,

  axi_if.slave   s_axi_data,    // 256-b AXI4 (currently unused — stubbed in RM)
  axi_if.slave   s_axi_hbm,     // 256-b AXI4 from XDMA → BRAM crossbar SI[1]
  axi_if.slave   s_axil_ctrl,   // 32-b AXI-Lite from XDMA → chip CSR / launch FIFO

  output wire    hbm_cattrip    // tied to 0 inside (no HBM IP)

`ifdef SIM_CHIP_STUB
  // Pass-through for the chip-side stub interface — TB injects
  // FPGA→chip flits via sim_chip_tx_* and consumes chip→FPGA flits
  // via sim_chip_rx_*.
  ,input  wire [31:0] sim_chip_tx_data_i
  ,input  wire        sim_chip_tx_valid_i
  ,output wire        sim_chip_tx_ready_o
  ,output wire [31:0] sim_chip_rx_data_o
  ,output wire        sim_chip_rx_valid_o
  ,output wire        sim_chip_rx_last_o
  ,input  wire        sim_chip_rx_ready_i
`endif
);

  mini_dice_alveo_dynamic_region u_region (
    .aclk         (s_axi_data.aclk),
    .aresetn      (aresetn),

    `AXI_IF_TO_FLAT(s_axi_data),
    `AXI_IF_TO_FLAT(s_axi_hbm),
    `AXI_IF_TO_FLAT(s_axil_ctrl),
    .hbm_cattrip  (hbm_cattrip)

`ifdef SIM_CHIP_STUB
    ,.sim_chip_tx_data_i  (sim_chip_tx_data_i)
    ,.sim_chip_tx_valid_i (sim_chip_tx_valid_i)
    ,.sim_chip_tx_ready_o (sim_chip_tx_ready_o)
    ,.sim_chip_rx_data_o  (sim_chip_rx_data_o)
    ,.sim_chip_rx_valid_o (sim_chip_rx_valid_o)
    ,.sim_chip_rx_last_o  (sim_chip_rx_last_o)
    ,.sim_chip_rx_ready_i (sim_chip_rx_ready_i)
`endif
  );

endmodule : mini_dice_alveo_dynamic

`undef AXI_IF_TO_FLAT
