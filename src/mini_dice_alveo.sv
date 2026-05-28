// *************************************************************************
//
// mini_dice_alveo synthesis top.
//
// Variant of `pncel_top` that hosts the zcu102 chip stack
// (mini_dice_top + Vortex caches + L3) directly on the alveo's BRAM
// controller — no Aurora link, no off-board hop.
//
// Wires together the static region (xdma + system_config + AXI splitters,
// shared with the aurora-based pncel_top) and a new dynamic region
// (mini_dice_alveo_dynamic) that contains the chip + L3 + crossbar +
// BRAM.  One `axi_decoupler` per bus crossing the partition boundary.
//
// Decouple control: same convention as pncel_top — REG_PR_CTRL[0] in
// system_config drives `decouple`; REG_PR_CTRL[1] holds dyn_aresetn.
//
// Port surface differences from pncel_top:
//   - QSFP28 GT pins (qsfp_*) are GONE — no Aurora IP in this image.
//   - Sim-only aurora streams (sim_aurora_*) are GONE — the chip's
//     control path is driven through XDMA's AXI-Lite (`sim_axil`).
//
// *************************************************************************
`timescale 1ns/1ps
module mini_dice_alveo #(
  parameter [31:0] BUILD_TIMESTAMP = 32'h01010000
) (
`ifndef SIMULATION
  // PCIe Gen3 x16 reference clock and reset
  input               pcie_refclk_p,
  input               pcie_refclk_n,
  input               pcie_rstn,

  // PCIe lanes
  output       [15:0] pci_exp_txp,
  output       [15:0] pci_exp_txn,
  input        [15:0] pci_exp_rxp,
  input        [15:0] pci_exp_rxn,

  // Satellite controller (CMS microcontroller link)
  input               satellite_uart_0_rxd,
  output              satellite_uart_0_txd,
  input         [1:0] satellite_gpio_0,

  // HBM catastrophic-over-temperature alarm — Alveo U50 board pin J18
  // (LVCMOS18).  Must be driven (Vivado DRC PPURQ-1).  Tied to 0 inside
  // the RM (no HBM IP in this image).
  output              hbm_cattrip
`else
  // ===== Simulation interface ========================================
  // The testbench supplies the host clock / reset and drives:
  //   sim_axil    — XDMA's m_axil   (32 b AXI-Lite, host control path —
  //                  in this image it ultimately reaches axi_lite_fifo
  //                  inside the dynamic region so SW can launch kernels)
  //   sim_axi_dma — XDMA's m_axi    (512 b AXI4 master into the static-
  //                  side axi_dwidth_converter → axi_dma_switch)
  input               aclk,
  input               aresetn,
  axi_if.slave        sim_axil,
  axi_if.slave        sim_axi_dma

`ifdef SIM_CHIP_STUB
  // Chip-side stub interface — TB drives FPGA→chip / observes chip→FPGA
  // flits when the in-fabric mini_dice_top is replaced with a stub.
  ,input  wire [31:0] sim_chip_tx_data_i
  ,input  wire        sim_chip_tx_valid_i
  ,output wire        sim_chip_tx_ready_o
  ,output wire [31:0] sim_chip_rx_data_o
  ,output wire        sim_chip_rx_valid_o
  ,output wire        sim_chip_rx_last_o
  ,input  wire        sim_chip_rx_ready_i
`endif
`endif
);

  // ---------------------------------------------------------------------
  // Host clock / reset / PR control from the static region.
  // ---------------------------------------------------------------------
  wire axi_aclk;
  wire axi_aresetn;
  wire decouple;
  wire dyn_aresetn;

  // One-cycle pipeline stage on dyn_aresetn just before the partition
  // boundary — same role as in pncel_top.  Breaks the long timing path
  // on the global reset distribution net inside the RM.
  reg  dyn_aresetn_q;
  always_ff @(posedge axi_aclk) begin
    dyn_aresetn_q <= dyn_aresetn;
  end

  // ---------------------------------------------------------------------
  // PR-boundary axi_if interfaces (same shape as pncel_top).
  // ---------------------------------------------------------------------
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_data_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_data_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1))
    axil_ctrl_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1))
    axil_ctrl_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // XDMA direct AXI4 path into the BRAM crossbar SI[1].
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_hbm_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_hbm_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // ---------------------------------------------------------------------
  // hbm_cattrip distribution (legacy J18 pin requirement).
  // ---------------------------------------------------------------------
  wire hbm_cattrip_dy;
`ifndef SIMULATION
  wire hbm_cattrip_safe = hbm_cattrip_dy & ~decouple;
`else
  wire hbm_cattrip_safe = 1'b0;
`endif

  // ---------------------------------------------------------------------
  // Static region — XDMA + system_config + AXI splitters.  Reused from
  // pncel_static (unchanged).
  // ---------------------------------------------------------------------
  pncel_static #(
    .BUILD_TIMESTAMP (BUILD_TIMESTAMP)
  ) static_inst (
`ifndef SIMULATION
    .pcie_refclk_p        (pcie_refclk_p),
    .pcie_refclk_n        (pcie_refclk_n),
    .pcie_rstn            (pcie_rstn),
    .pci_exp_txp          (pci_exp_txp),
    .pci_exp_txn          (pci_exp_txn),
    .pci_exp_rxp          (pci_exp_rxp),
    .pci_exp_rxn          (pci_exp_rxn),

    .satellite_uart_0_rxd (satellite_uart_0_rxd),
    .satellite_uart_0_txd (satellite_uart_0_txd),
    .satellite_gpio_0     (satellite_gpio_0),
`else
    .aclk                 (aclk),
    .aresetn              (aresetn),
    .sim_axil             (sim_axil),
    .sim_axi_dma          (sim_axi_dma),
`endif

    .axi_aclk             (axi_aclk),
    .axi_aresetn          (axi_aresetn),
    .decouple             (decouple),
    .dyn_aresetn          (dyn_aresetn),

    .m_axi_dynamic        (axi_data_st),
    .m_axi_hbm            (axi_hbm_st),
    .m_axil_dynamic       (axil_ctrl_st),

    .hbm_cattrip_i        (hbm_cattrip_safe)
  );

  // ---------------------------------------------------------------------
  // PR-boundary decouplers.
  // ---------------------------------------------------------------------
  axi_decoupler u_decouple_data (
    .decouple (decouple),
    .s_axi    (axi_data_st),
    .m_axi    (axi_data_dy)
  );

  axi_decoupler u_decouple_ctrl (
    .decouple (decouple),
    .s_axi    (axil_ctrl_st),
    .m_axi    (axil_ctrl_dy)
  );

  axi_decoupler u_decouple_hbm_data (
    .decouple (decouple),
    .s_axi    (axi_hbm_st),
    .m_axi    (axi_hbm_dy)
  );

  // ---------------------------------------------------------------------
  // Dynamic region (PR partition) — chip stack + BRAM.
  // ---------------------------------------------------------------------
  mini_dice_alveo_dynamic dynamic_inst (
    .aresetn      (dyn_aresetn_q),

    .s_axi_data   (axi_data_dy),
    .s_axi_hbm    (axi_hbm_dy),
    .s_axil_ctrl  (axil_ctrl_dy),

    .hbm_cattrip  (hbm_cattrip_dy)

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

`ifndef SIMULATION
  OBUF u_hbm_cattrip_obuf (
    .I (hbm_cattrip_safe),
    .O (hbm_cattrip)
  );
`endif

endmodule: mini_dice_alveo
