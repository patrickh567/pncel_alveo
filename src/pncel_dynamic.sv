// *************************************************************************
//
// pncel-alveo dynamic region — axi_if-to-flat shim.
//
// The PR partition top (`pncel_dynamic_region`) has flat Verilog ports —
// that's the only port style Vivado's DFX flow accepts on a partition
// boundary.  But everywhere else in the project (decouplers, static
// region, etc.) the AXI buses are SystemVerilog `axi_if` interfaces.
//
// This wrapper sits between the two: it accepts axi_if ports and forwards
// them, one field at a time, into the flat-port partition module.  Same
// pattern as alveo_u50_dynamic.sv — preserves an `axi_if`-friendly
// interface for the parent (pncel_top) while keeping the DFX-required
// flat-port shape on the partition itself.
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

module pncel_dynamic (
  input          aresetn,

`ifndef SIMULATION
  // GT physical pins for the QSFP28 quad (refclk + 4 lanes).  Cross the
  // PR boundary unchanged into pncel_dynamic_region's Aurora IP.
  input  wire        gt_refclk1_p,
  input  wire        gt_refclk1_n,
  input  wire [3:0]  rxp,
  input  wire [3:0]  rxn,
  output wire [3:0]  txp,
  output wire [3:0]  txn,
`else
  // Aurora stub interface — see pncel_dynamic_region.sv for semantics.
  input  wire         sim_aurora_user_clk,
  input  wire         sim_aurora_channel_up,
  output wire [255:0] sim_aurora_tx_tdata,
  output wire  [31:0] sim_aurora_tx_tkeep,
  output wire         sim_aurora_tx_tlast,
  output wire         sim_aurora_tx_tvalid,
  input  wire         sim_aurora_tx_tready,
  input  wire [255:0] sim_aurora_rx_tdata,
  input  wire  [31:0] sim_aurora_rx_tkeep,
  input  wire         sim_aurora_rx_tlast,
  input  wire         sim_aurora_rx_tvalid,
  output wire [255:0] sim_aurora_userk_tx_tdata,
  output wire         sim_aurora_userk_tx_tvalid,
  input  wire         sim_aurora_userk_tx_tready,
  input  wire [255:0] sim_aurora_userk_rx_tdata,
  input  wire         sim_aurora_userk_rx_tvalid,
`endif

  axi_if.slave   s_axi_data,    // 256-bit AXI4 data from XDMA (→ aurora bridge)
  axi_if.slave   s_axi_hbm,     // 256-bit AXI4 data from XDMA (→ BRAM crossbar)
  axi_if.slave   s_axil_ctrl,   // 32-bit AXI-Lite control from XDMA

  // Legacy J18 cattrip — kept so pncel_top's OBUF and the CMS interrupt
  // input have a defined driver.  Tied to 0 inside the RM (no HBM IP).
  output wire    hbm_cattrip
);

  pncel_dynamic_region u_region (
    .aclk         (s_axi_data.aclk),
    .aresetn      (aresetn),
`ifndef SIMULATION
    .gt_refclk1_p (gt_refclk1_p),
    .gt_refclk1_n (gt_refclk1_n),
    .rxp          (rxp),
    .rxn          (rxn),
    .txp          (txp),
    .txn          (txn),
`else
    .sim_aurora_user_clk        (sim_aurora_user_clk),
    .sim_aurora_channel_up      (sim_aurora_channel_up),
    .sim_aurora_tx_tdata        (sim_aurora_tx_tdata),
    .sim_aurora_tx_tkeep        (sim_aurora_tx_tkeep),
    .sim_aurora_tx_tlast        (sim_aurora_tx_tlast),
    .sim_aurora_tx_tvalid       (sim_aurora_tx_tvalid),
    .sim_aurora_tx_tready       (sim_aurora_tx_tready),
    .sim_aurora_rx_tdata        (sim_aurora_rx_tdata),
    .sim_aurora_rx_tkeep        (sim_aurora_rx_tkeep),
    .sim_aurora_rx_tlast        (sim_aurora_rx_tlast),
    .sim_aurora_rx_tvalid       (sim_aurora_rx_tvalid),
    .sim_aurora_userk_tx_tdata  (sim_aurora_userk_tx_tdata),
    .sim_aurora_userk_tx_tvalid (sim_aurora_userk_tx_tvalid),
    .sim_aurora_userk_tx_tready (sim_aurora_userk_tx_tready),
    .sim_aurora_userk_rx_tdata  (sim_aurora_userk_rx_tdata),
    .sim_aurora_userk_rx_tvalid (sim_aurora_userk_rx_tvalid),
`endif
    `AXI_IF_TO_FLAT(s_axi_data),
    `AXI_IF_TO_FLAT(s_axi_hbm),
    `AXI_IF_TO_FLAT(s_axil_ctrl),
    .hbm_cattrip  (hbm_cattrip)
  );

endmodule : pncel_dynamic

`undef AXI_IF_TO_FLAT
