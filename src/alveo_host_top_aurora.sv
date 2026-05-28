// *************************************************************************
//
// Alveo U50 host — top-level wrapper.
//
// Instantiates both the static region (`alveo_u50_static`, which contains
// XDMA / HBM / the switch network / card management) and the dynamic
// region stub (`alveo_u50_dynamic`), with a per-interface `axi_decoupler`
// inserted on every signal that crosses the partial-reconfiguration
// partition boundary.
//
// Decouple control:
//   The static region exposes a single `decouple` output driven by bit 0
//   of static register 0 (host BAR offset 0x0).  Host software writes
//   `1` to this bit to freeze every PR-boundary AXI bus before kicking
//   off partial reconfiguration, then writes `0` once the new bitstream
//   is loaded.  All 33 decoupler instances share this one control bit.
//
// Port surface is limited to the Alveo U50's physical I/O — PCIe, the
// satellite controller link, and the HBM reference clock.  This is the
// module that should be set as the synthesis top.
//
// For RTL simulation, testbenches instantiate `alveo_u50_static` directly
// (with `SIMULATION` defined) and drive its sim-mode AXI inputs.  This
// wrapper is synthesis-only.
//
// *************************************************************************
`timescale 1ns/1ps
module alveo_host_top_aurora #(
  parameter [31:0] BUILD_TIMESTAMP = 32'h01010000
) (
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

  // QSFP28 GT — refclk diff pair + 4-lane TX/RX wired into the static
  // region, where `aurora_static` instantiates the GT primitives.
  input         [0:0] qsfp_refclk_p,
  input         [0:0] qsfp_refclk_n,
  input         [3:0] qsfp_rxp,
  input         [3:0] qsfp_rxn,
  output        [3:0] qsfp_txp,
  output        [3:0] qsfp_txn
);

  // ---------------------------------------------------------------------
  // Host clock / reset and PR control signals exposed by the static
  // region.  All decoupler instances below share `decouple`; everything
  // on the dynamic side of the PR boundary (dynamic module + every `_dy`
  // axi_if's aresetn field) uses `dyn_aresetn`, which is the normal
  // peripheral reset ANDed with a software-controlled bit in static
  // register 0.
  // ---------------------------------------------------------------------
  wire axi_aclk;
  wire axi_aresetn;
  wire decouple;
  wire dyn_aresetn;

  // Pipeline stage on dyn_aresetn placed just before the dynamic-region
  // partition boundary to break the long timing path on the global
  // reset distribution net inside the RM.  Synchronously sampled on
  // axi_aclk; both assert and deassert lag the upstream signal by one
  // cycle.
  reg  dyn_aresetn_q;
  always_ff @(posedge axi_aclk) begin
    dyn_aresetn_q <= dyn_aresetn;
  end

  // ---------------------------------------------------------------------
  // PR-boundary AXI interfaces.
  //
  // Two copies of every boundary bus are needed because each
  // `axi_decoupler` requires its own upstream and downstream `axi_if`:
  //
  //   `_st`  — interface that connects to a port on `alveo_u50_static`
  //   `_dy`  — interface that connects to a port on `alveo_u50_dynamic`
  //
  // For the control bus (master in static, slave in dynamic):
  //   static.m_*  →  *_st  →  decoupler  →  *_dy  →  dynamic.s_*
  //
  // For HBM master buses (master in dynamic, slave in static):
  //   dynamic.m_*  →  *_dy  →  decoupler  →  *_st  →  static.s_*
  //
  // Both copies of each interface use the same widths and the same
  // (axi_aclk, axi_aresetn) clocking.
  // ---------------------------------------------------------------------

  // Control bus (static → dynamic direction).
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) axil_dynamic_st     (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) axil_dynamic_dy     (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // HBM master buses (dynamic → static direction).  Direct ports
  // 00..30 are HBM-shape (256 b AXI3, 6-bit ID, 4-bit LEN) and land
  // on the matching HBM port number.  Port 31 is the muxed XDMA+RM
  // path — 4-bit ID, AXI3/256 — sized to match the static-side
  // axi_hbm_switch.s01 input shape.
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_00_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_00_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_01_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_01_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_02_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_02_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_03_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_03_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_04_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_04_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_05_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_05_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_06_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_06_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_07_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_07_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_08_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_08_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_09_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_09_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_10_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_10_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_11_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_11_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_12_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_12_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_13_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_13_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_14_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_14_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_15_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_15_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_16_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_16_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_17_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_17_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_18_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_18_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_19_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_19_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_20_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_20_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_21_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_21_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_22_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_22_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_23_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_23_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_24_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_24_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_25_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_25_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_26_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_26_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_27_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_27_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_28_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_28_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_29_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_29_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_30_st (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_30_dy (.aclk(axi_aclk), .aresetn(dyn_aresetn));
  // axi_hbm_31_{st,dy} is the PR-partition path into
  // axi_hbm_switch.s01.  256-bit AXI3 (4-bit ID, 4-bit LEN).
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4), .LEN_W(4)) axi_hbm_31_st(.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4), .LEN_W(4)) axi_hbm_31_dy(.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // Boundary-side register slice on the mux path — see alveo_host_top.sv.
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4), .LEN_W(4))
    axi_hbm_31_dy_sliced (.aclk(axi_aclk), .aresetn(dyn_aresetn));

  // Static-side post-decoupler register-slice outputs.  Each direct
  // HBM bus (axi_hbm_00..30) gets one boundary-stage slice between
  // the decoupler and `alveo_u50_static_aurora.s_axi_hbm_NN`.  Port
  // 31 (mux landing) is unsliced (already buffered through the
  // static-side converter chain).  See `hbm_slice_bank_a/_b`.
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_00_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_01_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_02_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_03_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_04_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_05_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_06_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_07_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_08_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_09_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_10_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_11_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_12_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_13_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_14_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_15_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_16_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_17_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_18_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_19_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_20_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_21_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_22_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_23_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_24_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_25_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_26_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_27_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_28_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_29_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) axi_hbm_30_sliced (.aclk(axi_aclk), .aresetn(axi_aresetn));

  // Aurora 64b/66b user-side stream — clocked by the aurora-generated
  // `user_clk` from the static region.  Crosses the PR boundary
  // un-decoupled for now; aurora resyncs after PR completes.
  wire aurora_user_clk;
  wire aurora_user_aresetn;
  aurora_if aurora_bus (
    .user_clk     (aurora_user_clk),
    .user_aresetn (aurora_user_aresetn)
  );

  // ---------------------------------------------------------------------
  // Static region — owns XDMA, HBM, the switch network, and all card
  // management IPs.  Drives axi_aclk / axi_aresetn / decouple out, and
  // talks to the PR partition through the `_st`-suffixed interfaces.
  // ---------------------------------------------------------------------
  alveo_u50_static_aurora #(
    .BUILD_TIMESTAMP (BUILD_TIMESTAMP)
  ) static_inst (
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

    .axi_aclk             (axi_aclk),
    .axi_aresetn          (axi_aresetn),
    .decouple             (decouple),
    .dyn_aresetn          (dyn_aresetn),

    .m_axil_dynamic       (axil_dynamic_st),

    .s_axi_hbm_00         (axi_hbm_00_sliced),
    .s_axi_hbm_01         (axi_hbm_01_sliced),
    .s_axi_hbm_02         (axi_hbm_02_sliced),
    .s_axi_hbm_03         (axi_hbm_03_sliced),
    .s_axi_hbm_04         (axi_hbm_04_sliced),
    .s_axi_hbm_05         (axi_hbm_05_sliced),
    .s_axi_hbm_06         (axi_hbm_06_sliced),
    .s_axi_hbm_07         (axi_hbm_07_sliced),
    .s_axi_hbm_08         (axi_hbm_08_sliced),
    .s_axi_hbm_09         (axi_hbm_09_sliced),
    .s_axi_hbm_10         (axi_hbm_10_sliced),
    .s_axi_hbm_11         (axi_hbm_11_sliced),
    .s_axi_hbm_12         (axi_hbm_12_sliced),
    .s_axi_hbm_13         (axi_hbm_13_sliced),
    .s_axi_hbm_14         (axi_hbm_14_sliced),
    .s_axi_hbm_15         (axi_hbm_15_sliced),
    .s_axi_hbm_16         (axi_hbm_16_sliced),
    .s_axi_hbm_17         (axi_hbm_17_sliced),
    .s_axi_hbm_18         (axi_hbm_18_sliced),
    .s_axi_hbm_19         (axi_hbm_19_sliced),
    .s_axi_hbm_20         (axi_hbm_20_sliced),
    .s_axi_hbm_21         (axi_hbm_21_sliced),
    .s_axi_hbm_22         (axi_hbm_22_sliced),
    .s_axi_hbm_23         (axi_hbm_23_sliced),
    .s_axi_hbm_24         (axi_hbm_24_sliced),
    .s_axi_hbm_25         (axi_hbm_25_sliced),
    .s_axi_hbm_26         (axi_hbm_26_sliced),
    .s_axi_hbm_27         (axi_hbm_27_sliced),
    .s_axi_hbm_28         (axi_hbm_28_sliced),
    .s_axi_hbm_29         (axi_hbm_29_sliced),
    .s_axi_hbm_30         (axi_hbm_30_sliced),

    .s_axi_hbm_31         (axi_hbm_31_st),

    .qsfp_refclk_p        (qsfp_refclk_p[0]),
    .qsfp_refclk_n        (qsfp_refclk_n[0]),
    .qsfp_rxp             (qsfp_rxp),
    .qsfp_rxn             (qsfp_rxn),
    .qsfp_txp             (qsfp_txp),
    .qsfp_txn             (qsfp_txn),

    .aurora_user_clk      (aurora_user_clk),
    .aurora_user_aresetn  (aurora_user_aresetn),
    .aurora               (aurora_bus)
  );

  // ---------------------------------------------------------------------
  // PR-boundary decoupler banks (33 total decouplers, split into two
  // sibling modules so each can be floorplanned next to the half of
  // the static fabric it talks to):
  //
  //   dynamic_decoupler_a — HBM channels 0..15.  Decouples 16 RM-side
  //                          masters (m_axi_hbm_01..15 and m_axi_hbm_00,
  //                          which lands on HBM port 0) onto their
  //                          static-side slaves.
  //
  //   dynamic_decoupler_b — HBM channels 16..31, plus the AXI-Lite
  //                          control plane.  Decouples 16 RM-side
  //                          masters (m_axi_hbm_16..30 and m_axi_hbm_31,
  //                          which lands on HBM port 31) plus the
  //                          static→RM axil_dynamic control bus.
  //
  // Either decoupler module's `decouple` input is shared from the
  // static-region register bit (decouple = static_reg_out[0][0]).
  // ---------------------------------------------------------------------
  dynamic_decoupler_a u_decouple_a (
    .decouple        (decouple),
    .axi_hbm_00_dy   (axi_hbm_00_dy), .axi_hbm_00_st (axi_hbm_00_st),
    .axi_hbm_01_dy   (axi_hbm_01_dy), .axi_hbm_01_st (axi_hbm_01_st),
    .axi_hbm_02_dy   (axi_hbm_02_dy), .axi_hbm_02_st (axi_hbm_02_st),
    .axi_hbm_03_dy   (axi_hbm_03_dy), .axi_hbm_03_st (axi_hbm_03_st),
    .axi_hbm_04_dy   (axi_hbm_04_dy), .axi_hbm_04_st (axi_hbm_04_st),
    .axi_hbm_05_dy   (axi_hbm_05_dy), .axi_hbm_05_st (axi_hbm_05_st),
    .axi_hbm_06_dy   (axi_hbm_06_dy), .axi_hbm_06_st (axi_hbm_06_st),
    .axi_hbm_07_dy   (axi_hbm_07_dy), .axi_hbm_07_st (axi_hbm_07_st),
    .axi_hbm_08_dy   (axi_hbm_08_dy), .axi_hbm_08_st (axi_hbm_08_st),
    .axi_hbm_09_dy   (axi_hbm_09_dy), .axi_hbm_09_st (axi_hbm_09_st),
    .axi_hbm_10_dy   (axi_hbm_10_dy), .axi_hbm_10_st (axi_hbm_10_st),
    .axi_hbm_11_dy   (axi_hbm_11_dy), .axi_hbm_11_st (axi_hbm_11_st),
    .axi_hbm_12_dy   (axi_hbm_12_dy), .axi_hbm_12_st (axi_hbm_12_st),
    .axi_hbm_13_dy   (axi_hbm_13_dy), .axi_hbm_13_st (axi_hbm_13_st),
    .axi_hbm_14_dy   (axi_hbm_14_dy), .axi_hbm_14_st (axi_hbm_14_st),
    .axi_hbm_15_dy   (axi_hbm_15_dy), .axi_hbm_15_st (axi_hbm_15_st)
  );

  dynamic_decoupler_b u_decouple_b (
    .decouple        (decouple),
    .axil_dynamic_st (axil_dynamic_st), .axil_dynamic_dy (axil_dynamic_dy),
    .axi_hbm_16_dy   (axi_hbm_16_dy),   .axi_hbm_16_st   (axi_hbm_16_st),
    .axi_hbm_17_dy   (axi_hbm_17_dy),   .axi_hbm_17_st   (axi_hbm_17_st),
    .axi_hbm_18_dy   (axi_hbm_18_dy),   .axi_hbm_18_st   (axi_hbm_18_st),
    .axi_hbm_19_dy   (axi_hbm_19_dy),   .axi_hbm_19_st   (axi_hbm_19_st),
    .axi_hbm_20_dy   (axi_hbm_20_dy),   .axi_hbm_20_st   (axi_hbm_20_st),
    .axi_hbm_21_dy   (axi_hbm_21_dy),   .axi_hbm_21_st   (axi_hbm_21_st),
    .axi_hbm_22_dy   (axi_hbm_22_dy),   .axi_hbm_22_st   (axi_hbm_22_st),
    .axi_hbm_23_dy   (axi_hbm_23_dy),   .axi_hbm_23_st   (axi_hbm_23_st),
    .axi_hbm_24_dy   (axi_hbm_24_dy),   .axi_hbm_24_st   (axi_hbm_24_st),
    .axi_hbm_25_dy   (axi_hbm_25_dy),   .axi_hbm_25_st   (axi_hbm_25_st),
    .axi_hbm_26_dy   (axi_hbm_26_dy),   .axi_hbm_26_st   (axi_hbm_26_st),
    .axi_hbm_27_dy   (axi_hbm_27_dy),   .axi_hbm_27_st   (axi_hbm_27_st),
    .axi_hbm_28_dy   (axi_hbm_28_dy),   .axi_hbm_28_st   (axi_hbm_28_st),
    .axi_hbm_29_dy   (axi_hbm_29_dy),   .axi_hbm_29_st   (axi_hbm_29_st),
    .axi_hbm_30_dy   (axi_hbm_30_dy),   .axi_hbm_30_st   (axi_hbm_30_st),
    .axi_hbm_31_dy  (axi_hbm_31_dy_sliced),  .axi_hbm_31_st  (axi_hbm_31_st)
  );

  // Mux-path register slice — between partition output (axi_hbm_31_dy)
  // and the decoupler input (axi_hbm_31_dy_sliced).
  axi_register_slice_hbm_mux_wrapper u_slice_axi_hbm_31 (
    .aclk    (axi_aclk),
    .aresetn (dyn_aresetn),
    .s       (axi_hbm_31_dy),
    .m       (axi_hbm_31_dy_sliced)
  );

  // ---------------------------------------------------------------------
  // HBM register-slice banks — one boundary register stage on every
  // direct HBM bus between the decoupler and the static-region's HBM
  // IP.  Mux path is unsliced (already buffered through the static-
  // side converter chain).
  // ---------------------------------------------------------------------
  hbm_slice_bank_a u_slice_a (
    .aclk    (axi_aclk),
    .aresetn (axi_aresetn),
    .axi_hbm_00_st (axi_hbm_00_st), .axi_hbm_00_sliced (axi_hbm_00_sliced),
    .axi_hbm_01_st (axi_hbm_01_st), .axi_hbm_01_sliced (axi_hbm_01_sliced),
    .axi_hbm_02_st (axi_hbm_02_st), .axi_hbm_02_sliced (axi_hbm_02_sliced),
    .axi_hbm_03_st (axi_hbm_03_st), .axi_hbm_03_sliced (axi_hbm_03_sliced),
    .axi_hbm_04_st (axi_hbm_04_st), .axi_hbm_04_sliced (axi_hbm_04_sliced),
    .axi_hbm_05_st (axi_hbm_05_st), .axi_hbm_05_sliced (axi_hbm_05_sliced),
    .axi_hbm_06_st (axi_hbm_06_st), .axi_hbm_06_sliced (axi_hbm_06_sliced),
    .axi_hbm_07_st (axi_hbm_07_st), .axi_hbm_07_sliced (axi_hbm_07_sliced),
    .axi_hbm_08_st (axi_hbm_08_st), .axi_hbm_08_sliced (axi_hbm_08_sliced),
    .axi_hbm_09_st (axi_hbm_09_st), .axi_hbm_09_sliced (axi_hbm_09_sliced),
    .axi_hbm_10_st (axi_hbm_10_st), .axi_hbm_10_sliced (axi_hbm_10_sliced),
    .axi_hbm_11_st (axi_hbm_11_st), .axi_hbm_11_sliced (axi_hbm_11_sliced),
    .axi_hbm_12_st (axi_hbm_12_st), .axi_hbm_12_sliced (axi_hbm_12_sliced),
    .axi_hbm_13_st (axi_hbm_13_st), .axi_hbm_13_sliced (axi_hbm_13_sliced),
    .axi_hbm_14_st (axi_hbm_14_st), .axi_hbm_14_sliced (axi_hbm_14_sliced),
    .axi_hbm_15_st (axi_hbm_15_st), .axi_hbm_15_sliced (axi_hbm_15_sliced)
  );

  hbm_slice_bank_b u_slice_b (
    .aclk    (axi_aclk),
    .aresetn (axi_aresetn),
    .axi_hbm_16_st (axi_hbm_16_st), .axi_hbm_16_sliced (axi_hbm_16_sliced),
    .axi_hbm_17_st (axi_hbm_17_st), .axi_hbm_17_sliced (axi_hbm_17_sliced),
    .axi_hbm_18_st (axi_hbm_18_st), .axi_hbm_18_sliced (axi_hbm_18_sliced),
    .axi_hbm_19_st (axi_hbm_19_st), .axi_hbm_19_sliced (axi_hbm_19_sliced),
    .axi_hbm_20_st (axi_hbm_20_st), .axi_hbm_20_sliced (axi_hbm_20_sliced),
    .axi_hbm_21_st (axi_hbm_21_st), .axi_hbm_21_sliced (axi_hbm_21_sliced),
    .axi_hbm_22_st (axi_hbm_22_st), .axi_hbm_22_sliced (axi_hbm_22_sliced),
    .axi_hbm_23_st (axi_hbm_23_st), .axi_hbm_23_sliced (axi_hbm_23_sliced),
    .axi_hbm_24_st (axi_hbm_24_st), .axi_hbm_24_sliced (axi_hbm_24_sliced),
    .axi_hbm_25_st (axi_hbm_25_st), .axi_hbm_25_sliced (axi_hbm_25_sliced),
    .axi_hbm_26_st (axi_hbm_26_st), .axi_hbm_26_sliced (axi_hbm_26_sliced),
    .axi_hbm_27_st (axi_hbm_27_st), .axi_hbm_27_sliced (axi_hbm_27_sliced),
    .axi_hbm_28_st (axi_hbm_28_st), .axi_hbm_28_sliced (axi_hbm_28_sliced),
    .axi_hbm_29_st (axi_hbm_29_st), .axi_hbm_29_sliced (axi_hbm_29_sliced),
    .axi_hbm_30_st (axi_hbm_30_st), .axi_hbm_30_sliced (axi_hbm_30_sliced)
  );

  // ---------------------------------------------------------------------
  // Dynamic region (PR partition stub).  Connects to the `_dy` side of
  // every decoupler.
  //
  // DONT_TOUCH preserves the instance boundary in non-DFX (flat) builds
  // so the tied-off stub isn't propagated across the boundary and the
  // decoupler fabric + hierarchical names (dynamic_inst/...) survive for
  // floorplanning and debug.  In DFX mode the partition definition
  // already preserves this boundary; the attribute is harmless there.
  // ---------------------------------------------------------------------
  alveo_u50_dynamic_aurora dynamic_inst (
    .aresetn       (dyn_aresetn_q),

    .s_axil        (axil_dynamic_dy),

    .m_axi_hbm_00  (axi_hbm_00_dy),
    .m_axi_hbm_01  (axi_hbm_01_dy),
    .m_axi_hbm_02  (axi_hbm_02_dy),
    .m_axi_hbm_03  (axi_hbm_03_dy),
    .m_axi_hbm_04  (axi_hbm_04_dy),
    .m_axi_hbm_05  (axi_hbm_05_dy),
    .m_axi_hbm_06  (axi_hbm_06_dy),
    .m_axi_hbm_07  (axi_hbm_07_dy),
    .m_axi_hbm_08  (axi_hbm_08_dy),
    .m_axi_hbm_09  (axi_hbm_09_dy),
    .m_axi_hbm_10  (axi_hbm_10_dy),
    .m_axi_hbm_11  (axi_hbm_11_dy),
    .m_axi_hbm_12  (axi_hbm_12_dy),
    .m_axi_hbm_13  (axi_hbm_13_dy),
    .m_axi_hbm_14  (axi_hbm_14_dy),
    .m_axi_hbm_15  (axi_hbm_15_dy),
    .m_axi_hbm_16  (axi_hbm_16_dy),
    .m_axi_hbm_17  (axi_hbm_17_dy),
    .m_axi_hbm_18  (axi_hbm_18_dy),
    .m_axi_hbm_19  (axi_hbm_19_dy),
    .m_axi_hbm_20  (axi_hbm_20_dy),
    .m_axi_hbm_21  (axi_hbm_21_dy),
    .m_axi_hbm_22  (axi_hbm_22_dy),
    .m_axi_hbm_23  (axi_hbm_23_dy),
    .m_axi_hbm_24  (axi_hbm_24_dy),
    .m_axi_hbm_25  (axi_hbm_25_dy),
    .m_axi_hbm_26  (axi_hbm_26_dy),
    .m_axi_hbm_27  (axi_hbm_27_dy),
    .m_axi_hbm_28  (axi_hbm_28_dy),
    .m_axi_hbm_29  (axi_hbm_29_dy),
    .m_axi_hbm_30  (axi_hbm_30_dy),
    .m_axi_hbm_31  (axi_hbm_31_dy),

    .aurora        (aurora_bus)
  );

endmodule: alveo_host_top_aurora
