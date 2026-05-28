// =============================================================================
// tb_pncel_top.sv
//
// Minimal sim scaffold for the pncel_alveo design.  Drives the
// SIMULATION-only port set of `pncel_top`: clock + reset, XDMA-stand-in
// AXI4 / AXI-Lite slaves, and the Aurora user-side streams.  No real
// stimulus is generated — extend `initial begin ... end` with actual
// requests once the test plan is decided.
//
// Compile-time defines expected:
//   +define+SIMULATION   — required.  Swaps out XDMA + Aurora IPs for
//                          the sim ports added in pncel_top.sv,
//                          pncel_dynamic.sv, pncel_dynamic_region.sv,
//                          and pncel_static.sv.
//
// Module hierarchy reached:
//   tb_pncel_top
//     u_dut : pncel_top
//       static_inst    : pncel_static       (XDMA stubbed)
//       dynamic_inst   : pncel_dynamic
//         u_region     : pncel_dynamic_region (Aurora stubbed,
//                                              clk_wiz_init stubbed)
//
// All decouplers + the protocol / clock / width converters / HBM IP
// still elaborate normally — sim exercises the same logic that synth
// will see, only with the IPs at the partition boundaries replaced by
// TB-visible interfaces.
// =============================================================================
`timescale 1ns/1ps

module tb_pncel_top;

  // ---------------------------------------------------------------------
  // Clocks
  //   aclk           : XDMA's normal 250 MHz user clock (4 ns period)
  //   aurora_clk     : Aurora's user-side clock (~156.25 MHz, 6.4 ns)
  // ---------------------------------------------------------------------
  localparam real ACLK_HALF_NS   = 2.0;     // 250 MHz
  localparam real AURORA_HALF_NS = 3.2;     // ~156.25 MHz

  bit aclk;
  bit aurora_user_clk;

  initial begin
    aclk            = 1'b0;
    aurora_user_clk = 1'b0;
  end

  always #(ACLK_HALF_NS   * 1ns) aclk            = ~aclk;
  always #(AURORA_HALF_NS * 1ns) aurora_user_clk = ~aurora_user_clk;

  // ---------------------------------------------------------------------
  // Reset — assert for the first 20 aclks
  // ---------------------------------------------------------------------
  logic aresetn = 1'b0;
  initial begin
    repeat (20) @(posedge aclk);
    aresetn = 1'b1;
  end

  // ---------------------------------------------------------------------
  // Aurora link-up signal — drive low for the first 200 aurora_user_clk
  // edges, then assert.  Mirrors what aurora's sys_reset_out → channel_up
  // sequence would do after the support layer brings the link up.
  // ---------------------------------------------------------------------
  logic sim_aurora_channel_up = 1'b0;
  initial begin
    repeat (200) @(posedge aurora_user_clk);
    sim_aurora_channel_up = 1'b1;
  end

  // ---------------------------------------------------------------------
  // XDMA-side AXI slaves driven by the TB.  These match pncel_static's
  // SIMULATION-mode `sim_axil` / `sim_axi_dma` axi_if.slave ports.
  // Widths come from pncel_static internals:
  //   sim_axil    : ADDR=32, DATA=32, ID=1   (AXI-Lite)
  //   sim_axi_dma : ADDR=64, DATA=512, ID=4  (AXI4-Full)
  // ---------------------------------------------------------------------
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) sim_axil    (.aclk(aclk), .aresetn(aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4)) sim_axi_dma (.aclk(aclk), .aresetn(aresetn));

  // ---------------------------------------------------------------------
  // Aurora user-side stream nets.  TB:
  //   - observes sim_aurora_tx_* / sim_aurora_userk_tx_* (what the
  //     bridge wants to ship over Aurora)
  //   - drives   sim_aurora_rx_* / sim_aurora_userk_rx_* (what the
  //     far-end ZCU102 would ship back)
  // ---------------------------------------------------------------------
  wire [255:0] sim_aurora_tx_tdata;
  wire  [31:0] sim_aurora_tx_tkeep;
  wire         sim_aurora_tx_tlast;
  wire         sim_aurora_tx_tvalid;
  logic        sim_aurora_tx_tready = 1'b1;       // TB always ready by default

  logic [255:0] sim_aurora_rx_tdata  = '0;
  logic  [31:0] sim_aurora_rx_tkeep  = '0;
  logic         sim_aurora_rx_tlast  = 1'b0;
  logic         sim_aurora_rx_tvalid = 1'b0;

  wire [255:0] sim_aurora_userk_tx_tdata;
  wire         sim_aurora_userk_tx_tvalid;
  logic        sim_aurora_userk_tx_tready = 1'b1;

  logic [255:0] sim_aurora_userk_rx_tdata  = '0;
  logic         sim_aurora_userk_rx_tvalid = 1'b0;

  // ---------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------
  pncel_top u_dut (
    .aclk                       (aclk),
    .aresetn                    (aresetn),
    .sim_axil                   (sim_axil),
    .sim_axi_dma                (sim_axi_dma),

    .sim_aurora_user_clk        (aurora_user_clk),
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
    .sim_aurora_userk_rx_tvalid (sim_aurora_userk_rx_tvalid)
  );

  // ---------------------------------------------------------------------
  // Idle the TB-driven AXI sides until the test plan adds stimulus.
  // ---------------------------------------------------------------------
  initial begin
    sim_axil.awvalid    = 1'b0;
    sim_axil.wvalid     = 1'b0;
    sim_axil.bready     = 1'b1;
    sim_axil.arvalid    = 1'b0;
    sim_axil.rready     = 1'b1;

    sim_axi_dma.awvalid = 1'b0;
    sim_axi_dma.wvalid  = 1'b0;
    sim_axi_dma.bready  = 1'b1;
    sim_axi_dma.arvalid = 1'b0;
    sim_axi_dma.rready  = 1'b1;
  end

  // ---------------------------------------------------------------------
  // Wave dump + finish guard
  // ---------------------------------------------------------------------
  initial begin
    $dumpfile("tb_pncel_top.vcd");
    $dumpvars(0, tb_pncel_top);
    #100us $finish;
  end

endmodule
