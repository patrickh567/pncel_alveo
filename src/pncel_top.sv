// *************************************************************************
//
// pncel-alveo synthesis top.
//
// Wires together the static region (xdma + system_config + AXI splitters)
// and the dynamic region (PR partition), with one `axi_decoupler` per
// bus crossing the partition boundary.  Compared to the original
// alveo_u50_host top (33 decouplers, one per HBM port + control), this
// top only needs TWO decouplers — the only static→dynamic boundary buses
// are XDMA's data path and XDMA's control AXI-Lite.
//
// Decouple control:
//   The decouple bit is sourced from `system_config`'s REG_PR_CTRL[0]
//   (host BAR offset 0x00350_01C, bit 0).  Software writes that bit
//   high before kicking off partial reconfiguration, streams the
//   bitstream into HBICAP, then writes it low.  Both decouplers share
//   this single control signal.
//
// Reset:
//   `dyn_aresetn` is XDMA's reset ANDed with ~REG_PR_CTRL[1].  Software
//   can hold the dynamic region in reset independently of system reset
//   by writing REG_PR_CTRL[1] = 1.
//
// Port surface is exactly the Alveo U50's physical I/O: PCIe + the CMS
// satellite link.  HBM has no top-level pins (the HBM stack is
// on-package; the HBM IP, when added to the dynamic region, drives the
// PHY entirely from inside the fabric).  CMACE4 and the other unused
// hard blocks are left for synthesis to leave alone.
//
// *************************************************************************
`timescale 1ns/1ps
module pncel_top #(
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

  // QSFP28 — 156.25 MHz user reference clock + 4 serial lanes.  Wires
  // directly into the Aurora 64b/66b IP inside pncel_dynamic_region.
  // PACKAGE_PIN mapping lives in constr/au50/pins.xdc:
  //   qsfp_refclk_p/n → N36/N37 (MGTREFCLK0_of_Quad_X0Y7)
  //   qsfp_txp/n      → D42/D43, C40/C41, B42/B43, A40/A41
  //   qsfp_rxp/n      → J45/J46, G45/G46, F43/F44, E45/E46
  input        [0:0]  qsfp_refclk_p,
  input        [0:0]  qsfp_refclk_n,
  output       [3:0]  qsfp_txp,
  output       [3:0]  qsfp_txn,
  input        [3:0]  qsfp_rxp,
  input        [3:0]  qsfp_rxn,

  // Satellite controller (CMS microcontroller link)
  input               satellite_uart_0_rxd,
  output              satellite_uart_0_txd,
  input         [1:0] satellite_gpio_0,

  // HBM catastrophic-over-temperature alarm — Alveo U50 board pin J18
  // (LVCMOS18).  Must be driven (Vivado DRC PPURQ-1) — undriven
  // means a card RMA risk if HBM ever overheats.  Sourced from the
  // HBM IP (in the dynamic region) and gated by ~decouple so it
  // doesn't trip during partial reconfiguration.
  output              hbm_cattrip
`else
  // ===== Simulation interface ========================================
  // Under `+define+SIMULATION` PCIe + QSFP + satellite pins are dropped.
  // The testbench supplies the host clock / reset and drives:
  //   sim_axil    — XDMA's m_axil   (32 b AXI-Lite master into the
  //                  static-side axil_host_switch)
  //   sim_axi_dma — XDMA's m_axi    (512 b AXI4 master into the
  //                  static-side axi_dwidth_converter → axi_dma_switch)
  //
  // For the Aurora side the testbench provides aurora_user_clk and
  // drives the channel_up status; the four user-side streams
  // (sim_aurora_{tx,rx}_data, sim_aurora_userk_{tx,rx}) cross the
  // partition boundary directly so the TB can model the far-end.
  input               aclk,
  input               aresetn,
  axi_if.slave        sim_axil,
  axi_if.slave        sim_axi_dma,

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
  input  wire         sim_aurora_userk_rx_tvalid
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
  // boundary — same role as in alveo_host_top.  Breaks the long timing
  // path on the global reset distribution net inside the RM and gives
  // the partition a clean synchronous reset.
  reg  dyn_aresetn_q;
  always_ff @(posedge axi_aclk) begin
    dyn_aresetn_q <= dyn_aresetn;
  end

  // ---------------------------------------------------------------------
  // PR-boundary axi_if interfaces.
  //
  // Two copies of each bus (per the same convention as alveo_host_top):
  //   `_st` interface attaches to the static side
  //   `_dy` interface attaches to the dynamic side
  // axi_decoupler sits between them and gates *valid / *ready when
  // `decouple` is high.
  //
  // Both interfaces use the same widths and the same clock; only the
  // reset binding differs (the dynamic copy uses dyn_aresetn so internal
  // logic clamps with the dynamic-region reset).
  // ---------------------------------------------------------------------
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_data_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_data_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1))
    axil_ctrl_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1))
    axil_ctrl_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // XDMA → HBM port 31 direct data path (256 b AXI4).  Sourced from
  // axi_dma_switch.M02 (address 0x4_0000_0000-0x4_0FFF_FFFF).
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_hbm_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_hbm_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // ---------------------------------------------------------------------
  // HBM cattrip distribution.
  //
  // The cattrip signal originates inside the RM (HBM IP is in the
  // dynamic region — see pncel_dynamic_region.hbm_cattrip, OR of the
  // two dram_*_stat_cattrip outputs).  Gated with ~decouple so it
  // can't fire spuriously while the dynamic region is mid-reconfig
  // (during PR the HBM IP itself is being torn down/rebuilt, so its
  // cattrip output is not meaningful).  The gated signal then drives
  // two sinks:
  //   1. OBUF → top-level hbm_cattrip → board pin J18 (LVCMOS18).
  //      Required by Vivado DRC PPURQ-1; pin J18 has no driver
  //      otherwise (this is what caused the bitstream failure).
  //   2. pncel_static.cattrip_i → system_config.interrupt_hbm_cattrip_0
  //      → CMS subsystem for telemetry / host alerts.
  //
  // Both wires are declared HERE (before static_inst) so static_inst
  // can consume hbm_cattrip_safe in its port mapping — Verilog's
  // implicit-net rule would otherwise truncate it to 1 bit (a real
  // gotcha seen elsewhere in this design when wires were declared
  // after the consumer instantiation).
  // ---------------------------------------------------------------------
  wire hbm_cattrip_dy;
`ifndef SIMULATION
  wire hbm_cattrip_safe = hbm_cattrip_dy & ~decouple;
`else
  // SIM: HBM physical thermals aren't modelled; tie off the gated
  // signal so static_inst's interrupt_hbm_cattrip_0 sees a defined 0.
  wire hbm_cattrip_safe = 1'b0;
`endif

  // ---------------------------------------------------------------------
  // Static region — XDMA + system_config + AXI splitters.  Drives the
  // host clock / reset and the PR control signals out; talks to the
  // dynamic region through the static-side axi_if copies.
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
    // Sim mode: TB drives aclk/aresetn + AXI-Lite + AXI4 directly into
    // pncel_static where XDMA's outputs normally feed.
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
  // PR-boundary decouplers — one for the data path, one for control.
  // Both are gated by the same `decouple` signal driven by system_config.
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
  // Dynamic region (PR partition).  Reset is the pipelined dyn_aresetn.
  // Connects to the `_dy` side of every decoupler.
  // ---------------------------------------------------------------------
  pncel_dynamic dynamic_inst (
    .aresetn      (dyn_aresetn_q),

`ifndef SIMULATION
    // GT pins straight through from the top-level to Aurora inside the RM.
    // Not decoupled — the PR partition itself owns the GT primitives, so
    // these nets are intrinsic to the partition (they enter and leave on
    // the partition boundary unchanged).
    .gt_refclk1_p (qsfp_refclk_p[0]),
    .gt_refclk1_n (qsfp_refclk_n[0]),
    .rxp          (qsfp_rxp),
    .rxn          (qsfp_rxn),
    .txp          (qsfp_txp),
    .txn          (qsfp_txn),
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

    .s_axi_data   (axi_data_dy),
    .s_axi_hbm    (axi_hbm_dy),
    .s_axil_ctrl  (axil_ctrl_dy),

    .hbm_cattrip  (hbm_cattrip_dy)
  );

`ifndef SIMULATION
  // Drive the J18 board pin from the gated cattrip signal.  Required
  // by Vivado DRC PPURQ-1; J18 has no driver without this OBUF.  See
  // the cattrip section above the static_inst block for the gating
  // rationale.
  OBUF u_hbm_cattrip_obuf (
    .I (hbm_cattrip_safe),
    .O (hbm_cattrip)
  );
`endif

endmodule: pncel_top
