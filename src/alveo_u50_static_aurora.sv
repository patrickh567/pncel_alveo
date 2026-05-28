// *************************************************************************
//
// Copyright 2020 Xilinx, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// *************************************************************************
`timescale 1ns/1ps
module alveo_u50_static_aurora #(
  parameter [31:0] BUILD_TIMESTAMP = 32'h01010000
) (
`ifndef SIMULATION
  // PCIe reference clock and reset
  input               pcie_refclk_p,
  input               pcie_refclk_n,
  input               pcie_rstn,

  // PCIe lanes
  output       [15:0] pci_exp_txp,
  output       [15:0] pci_exp_txn,
  input        [15:0] pci_exp_rxp,
  input        [15:0] pci_exp_rxn,
`else
  // Simulation clock and reset (replaces XDMA-generated clock)
  input               aclk,
  input               aresetn,

  // Direct AXI interfaces for testbench access
  axi_if.slave        sim_axil,
  axi_if.slave        sim_axi_dma,

  // HBM reference clock — simulation only.  In synthesis it's generated
  // internally by the `clk_wiz_hbm` MMCM below (dividing axi_aclk down
  // to 100 MHz).
  input               hbm_ref_clk_sim,
`endif

  // Satellite controller
  input               satellite_uart_0_rxd,
  output              satellite_uart_0_txd,
  input         [1:0] satellite_gpio_0,

  // 250 MHz host clock / reset driven out so a parent wrapper can use
  // them when declaring the axi_if interfaces below.  In synthesis this
  // is sourced from XDMA; in simulation it's forwarded from the aclk /
  // aresetn input ports.
  output              axi_aclk,
  output              axi_aresetn,

  // PR-decouple control.  Driven by bit 0 of static register 0
  // (host BAR offset 0x0); the parent wrapper feeds this into the
  // per-interface axi_decoupler instances on the dynamic-region boundary.
  // Host software asserts this before triggering partial reconfiguration
  // and deasserts it once the new bitstream is loaded.
  output              decouple,

  // Dynamic-region reset.  Active-low.  Equal to `periph_aresetn` when
  // the software-controlled reset bit (static reg 0, bit 1) is 0, and
  // forced low whenever that bit is 1.  The parent wrapper drives this
  // into the dynamic region's `aresetn` input and uses it as the
  // `aresetn` binding for every PR-boundary axi_if on the dynamic side.
  // Host software pulses the register bit to reset the freshly loaded
  // PR partition after reconfiguration (or any time during operation).
  output              dyn_aresetn,

  // Dynamic region interfaces
  axi_if.master       m_axil_dynamic,

  // HBM AXI ports — direct RM masters land on ports 00..30 (1-to-1
  // by port number); s_axi_hbm_31 is the muxed XDMA+RM path.
  axi_if.slave        s_axi_hbm_00,
  axi_if.slave        s_axi_hbm_01,
  axi_if.slave        s_axi_hbm_02,
  axi_if.slave        s_axi_hbm_03,
  axi_if.slave        s_axi_hbm_04,
  axi_if.slave        s_axi_hbm_05,
  axi_if.slave        s_axi_hbm_06,
  axi_if.slave        s_axi_hbm_07,
  axi_if.slave        s_axi_hbm_08,
  axi_if.slave        s_axi_hbm_09,
  axi_if.slave        s_axi_hbm_10,
  axi_if.slave        s_axi_hbm_11,
  axi_if.slave        s_axi_hbm_12,
  axi_if.slave        s_axi_hbm_13,
  axi_if.slave        s_axi_hbm_14,
  axi_if.slave        s_axi_hbm_15,
  axi_if.slave        s_axi_hbm_16,
  axi_if.slave        s_axi_hbm_17,
  axi_if.slave        s_axi_hbm_18,
  axi_if.slave        s_axi_hbm_19,
  axi_if.slave        s_axi_hbm_20,
  axi_if.slave        s_axi_hbm_21,
  axi_if.slave        s_axi_hbm_22,
  axi_if.slave        s_axi_hbm_23,
  axi_if.slave        s_axi_hbm_24,
  axi_if.slave        s_axi_hbm_25,
  axi_if.slave        s_axi_hbm_26,
  axi_if.slave        s_axi_hbm_27,
  axi_if.slave        s_axi_hbm_28,
  axi_if.slave        s_axi_hbm_29,
  axi_if.slave        s_axi_hbm_30,

  // HBM port 31 — muxed XDMA+RM path (4-bit ID, AXI3/256).  The RM
  // leg of this port goes through the static-side
  // axi_protocol_converter_0 + axi_dwidth_converter_0 chain (256→512)
  // before reaching axi_hbm_switch.s01 and HBM port 31.
  axi_if.slave        s_axi_hbm_31,

  // QSFP28 GT — refclk diff pair + 4 lanes (TX/RX) wired straight
  // from the package to `aurora_static`.  The aurora_64b66b_0 core
  // lives here in the static region so the dynamic-region partition
  // doesn't have to satisfy GT-pad placement on every RM.
  input               qsfp_refclk_p,
  input               qsfp_refclk_n,
  input        [3:0]  qsfp_rxp,
  input        [3:0]  qsfp_rxn,
  output       [3:0]  qsfp_txp,
  output       [3:0]  qsfp_txn,

  // Aurora user-side stream + the aurora-generated clock / reset.
  // Exposed as separate output ports because they're needed at the
  // top-level to construct the `aurora_if` instance (interfaces
  // consume their clock/reset at instantiation).
  output              aurora_user_clk,
  output              aurora_user_aresetn,
  aurora_if.st        aurora
);

  // =========================================================================
  // Clock, reset, and AXI source
  //
  // Reset tree:
  //   XDMA / sim TB → xdma_aresetn → proc_sys_reset_0 → {
  //     interconnect_aresetn → every AXI switch wrapper
  //     peripheral_aresetn   → everything else (HBM, CDCs, APB bridge,
  //                            system_config, the static reg map, and
  //                            exported out the module boundary as the
  //                            module-level axi_aresetn output port)
  //   }
  //
  // axi_aclk is still driven straight from XDMA (or from the testbench
  // in simulation) — proc_sys_reset doesn't gate the clock.
  // =========================================================================
  wire xdma_aresetn;     // raw XDMA / sim reset, input to proc_sys_reset
  wire intercon_aresetn; // interconnect (switch) reset
  wire periph_aresetn;   // peripheral / endpoint reset (also drives
                         //   the module-level axi_aresetn output)

  assign axi_aresetn = periph_aresetn;

  axi_if #(
    .ADDR_W (64),
    .DATA_W (512),
    .ID_W   (4)
  ) axi_dma (.aclk(axi_aclk), .aresetn(axi_aresetn));

  axi_if #(
    .ADDR_W (32),
    .DATA_W (32),
    .ID_W   (1)
  ) axil_host (.aclk(axi_aclk), .aresetn(axi_aresetn));

`ifndef SIMULATION
  // =========================================================================
  // PCIe reference clock buffer
  // =========================================================================
  wire pcie_refclk;
  wire pcie_refclk_gt;

  IBUFDS_GTE4 #(
    .REFCLK_HROW_CK_SEL (2'b00)
  ) pcie_refclk_buf (
    .O     (pcie_refclk_gt),
    .ODIV2 (pcie_refclk),
    .CEB   (1'b0),
    .I     (pcie_refclk_p),
    .IB    (pcie_refclk_n)
  );

  // =========================================================================
  // HBM reference clock (100 MHz) — generated by a dedicated MMCM
  // (`clk_wiz_hbm`) from `axi_aclk` (XDMA's 250 MHz user clock).
  //
  // Earlier revisions tried a direct BUFG_GT on pcie_refclk's ODIV2
  // output.  That hit [BFGTL-1 bad_BUFG_GT_muxing] because XDMA already
  // has a BUFG_GT on the same ODIV2 net with different CE/CLR drivers
  // (XDMA's internal sync_sc_ce/clr), and Xilinx requires shared-input
  // BUFG_GTs to share CE/CLR too.  Using an MMCM on a different source
  // avoids that rule entirely.
  //
  // The Alveo U50 has no dedicated external HBM reference-clock pin,
  // so the HBM IP is fed from this internal fabric clock.  HBM init
  // is gated on axi_aclk stability (i.e., after PCIe link), which is
  // fine since the host only touches HBM over DMA after link-up.
  // =========================================================================
  wire hbm_ref_clk;

  clk_wiz_hbm clk_wiz_hbm_inst (
    .clk_in1  (axi_aclk),
    .clk_out1 (hbm_ref_clk)
  );

  // =========================================================================
  // XDMA
  // =========================================================================
  wire user_lnk_up;

  xdma_wrapper xdma_inst (
    .sys_clk                (pcie_refclk),
    .sys_clk_gt             (pcie_refclk_gt),
    .sys_rst_n              (pcie_rstn),

    .pci_exp_txp            (pci_exp_txp),
    .pci_exp_txn            (pci_exp_txn),
    .pci_exp_rxp            (pci_exp_rxp),
    .pci_exp_rxn            (pci_exp_rxn),

    .axi_aclk               (axi_aclk),
    .axi_aresetn             (xdma_aresetn),
    .user_lnk_up             (user_lnk_up),

    .m_axi                   (axi_dma),
    .m_axil                  (axil_host),

    .usr_irq_req             (1'b0),
    .usr_irq_ack             (),
    .msi_enable              (),
    .msi_vector_width        (),

    .cfg_mgmt_addr           (19'b0),
    .cfg_mgmt_write          (1'b0),
    .cfg_mgmt_write_data     (32'b0),
    .cfg_mgmt_byte_enable    (4'b0),
    .cfg_mgmt_read           (1'b0),
    .cfg_mgmt_read_data      (),
    .cfg_mgmt_read_write_done()
  );

`else
  // =========================================================================
  // Simulation: clock/reset from ports, testbench drives AXI directly.
  // Drive xdma_aresetn (not the module-level axi_aresetn output) so the
  // proc_sys_reset_0 instance below still sequences the interconnect
  // and peripheral resets the same way it does in synthesis.
  // =========================================================================
  assign axi_aclk     = aclk;
  assign xdma_aresetn = aresetn;

  // HBM reference clock — from testbench in sim (no BUFG_GT available).
  wire hbm_ref_clk;
  assign hbm_ref_clk = hbm_ref_clk_sim;

  // Connect testbench AXI-Lite to axil_host
  assign axil_host.awaddr  = sim_axil.awaddr;
  assign axil_host.awprot  = sim_axil.awprot;
  assign axil_host.awvalid = sim_axil.awvalid;
  assign sim_axil.awready  = axil_host.awready;
  assign axil_host.wdata   = sim_axil.wdata;
  assign axil_host.wstrb   = sim_axil.wstrb;
  assign axil_host.wvalid  = sim_axil.wvalid;
  assign sim_axil.wready   = axil_host.wready;
  assign sim_axil.bresp    = axil_host.bresp;
  assign sim_axil.bvalid   = axil_host.bvalid;
  assign axil_host.bready  = sim_axil.bready;
  assign axil_host.araddr  = sim_axil.araddr;
  assign axil_host.arprot  = sim_axil.arprot;
  assign axil_host.arvalid = sim_axil.arvalid;
  assign sim_axil.arready  = axil_host.arready;
  assign sim_axil.rdata    = axil_host.rdata;
  assign sim_axil.rresp    = axil_host.rresp;
  assign sim_axil.rvalid   = axil_host.rvalid;
  assign axil_host.rready  = sim_axil.rready;

  // Connect testbench AXI DMA to axi_dma
  assign axi_dma.awid    = sim_axi_dma.awid;
  assign axi_dma.awaddr  = sim_axi_dma.awaddr;
  assign axi_dma.awlen   = sim_axi_dma.awlen;
  assign axi_dma.awsize  = sim_axi_dma.awsize;
  assign axi_dma.awburst = sim_axi_dma.awburst;
  assign axi_dma.awlock  = sim_axi_dma.awlock;
  assign axi_dma.awcache = sim_axi_dma.awcache;
  assign axi_dma.awprot  = sim_axi_dma.awprot;
  assign axi_dma.awqos   = sim_axi_dma.awqos;
  assign axi_dma.awregion = sim_axi_dma.awregion;
  assign axi_dma.awvalid = sim_axi_dma.awvalid;
  assign sim_axi_dma.awready = axi_dma.awready;
  assign axi_dma.wdata   = sim_axi_dma.wdata;
  assign axi_dma.wstrb   = sim_axi_dma.wstrb;
  assign axi_dma.wlast   = sim_axi_dma.wlast;
  assign axi_dma.wvalid  = sim_axi_dma.wvalid;
  assign sim_axi_dma.wready = axi_dma.wready;
  assign sim_axi_dma.bid    = axi_dma.bid;
  assign sim_axi_dma.bresp  = axi_dma.bresp;
  assign sim_axi_dma.bvalid = axi_dma.bvalid;
  assign axi_dma.bready  = sim_axi_dma.bready;
  assign axi_dma.arid    = sim_axi_dma.arid;
  assign axi_dma.araddr  = sim_axi_dma.araddr;
  assign axi_dma.arlen   = sim_axi_dma.arlen;
  assign axi_dma.arsize  = sim_axi_dma.arsize;
  assign axi_dma.arburst = sim_axi_dma.arburst;
  assign axi_dma.arlock  = sim_axi_dma.arlock;
  assign axi_dma.arcache = sim_axi_dma.arcache;
  assign axi_dma.arprot  = sim_axi_dma.arprot;
  assign axi_dma.arqos   = sim_axi_dma.arqos;
  assign axi_dma.arregion = sim_axi_dma.arregion;
  assign axi_dma.arvalid = sim_axi_dma.arvalid;
  assign sim_axi_dma.arready = axi_dma.arready;
  assign sim_axi_dma.rid    = axi_dma.rid;
  assign sim_axi_dma.rdata  = axi_dma.rdata;
  assign sim_axi_dma.rresp  = axi_dma.rresp;
  assign sim_axi_dma.rlast  = axi_dma.rlast;
  assign sim_axi_dma.rvalid = axi_dma.rvalid;
  assign axi_dma.rready  = sim_axi_dma.rready;
`endif

  // =========================================================================
  // Processor System Reset
  //
  // Takes the raw XDMA (or simulation-driven) reset `xdma_aresetn` and
  // produces two staged, synchronized, minimum-pulse-width resets:
  //
  //   interconnect_aresetn → drives every AXI switch's `aresetn` port
  //                          (comes out of reset first so the fabric is
  //                          ready when endpoints start sending traffic)
  //   peripheral_aresetn   → drives every endpoint IP (HBM, CDCs, APB
  //                          bridge, system_config, the static reg map)
  //                          and is exported out the module boundary as
  //                          `axi_aresetn`
  //
  // `dcm_locked` is tied high because XDMA's axi_aclk is already locked
  // whenever the user clock is present.
  // =========================================================================
  proc_sys_reset_0 proc_sys_reset_inst (
    .slowest_sync_clk     (axi_aclk),
    .ext_reset_in         (xdma_aresetn),
    .aux_reset_in         (1'b1),
    .mb_debug_sys_rst     (1'b0),
    .dcm_locked           (1'b1),

    .mb_reset             (),
    .bus_struct_reset     (),
    .peripheral_reset     (),
    .interconnect_aresetn (intercon_aresetn),
    .peripheral_aresetn   (periph_aresetn)
  );

  // =========================================================================
  // AXI Full Switch (1 slave -> 2 masters) for DMA path
  //
  // Host-DMA address map (see src/utility/vivado_ip/axi_dma_switch.tcl):
  //   0x0000_0000_0000_0000 - 0x0000_0001_FFFF_FFFF   M00 → HBM (8 GB,  512 b)
  //   0x0000_0002_0000_0000 - 0x0000_0002_0000_FFFF   M01 → HBICAP (64 KB, 32 b)
  //
  // The DMA→RM master that this switch used to expose was removed when
  // the dynamic-region DMA slave went away — the RM now does its own
  // HBM access without needing an XDMA-driven AXI4 slave.
  // =========================================================================
  axi_if #(
    .ADDR_W (64),
    .DATA_W (512),
    .ID_W   (4)
  ) axi_dma_hbm (.aclk(axi_aclk), .aresetn(axi_aresetn));

  // M01 is narrower (32-bit data) — the AXI Switch handles data-width
  // conversion at this port internally.
  axi_if #(
    .ADDR_W (64),
    .DATA_W (32),
    .ID_W   (4)
  ) axi_dma_hbicap (.aclk(axi_aclk), .aresetn(axi_aresetn));

  axi_dma_switch_wrapper axi_dma_switch_inst (
    .aclk         (axi_aclk),
    .aresetn      (intercon_aresetn),
    .s00          (axi_dma),
    .m00          (axi_dma_hbm),
    .m01          (axi_dma_hbicap),
    .aresetn_out  (),
    .pc_asserted  (),
    .pc_status    ()
  );

  // =========================================================================
  // AXI Full Switch (2 slaves -> 1 master) for HBM
  //
  // The HBM IP's native AXI port is 33-bit addr / 256-bit data /
  // 6-bit ID / 4-bit awlen (AXI3).  The switch's M00 output matches
  // that width (axi_hbm_switch.tcl: M00_AXI_DATA_WIDTH=256,
  // M00_AXI_PROTOCOL=AXI3), so this intermediate interface is sized
  // to match HBM natively.  The switch handles the 512→256 packing
  // and AXI4→AXI3 burst splitting from the 512-bit host DMA path
  // internally.  ID_W is 6 to match the HBM IP's 6-bit port IDs;
  // the switch's actual M00 ID is only 1 bit wide (NUM_SI=1) so the
  // switch-wrapper does explicit pad/truncate between m00 and the
  // IP on the ID signals.
  // =========================================================================
  axi_if #(
    .ADDR_W (64),
    .DATA_W (256),
    .ID_W   (6),
    .LEN_W  (4)
  ) axi_hbm_mux (.aclk(axi_aclk), .aresetn(axi_aresetn));

  // axi_hbm_switch multiplexes two AXI4/512 input buses down onto
  // HBM port 31 (the muxed landing — direct RM port 31 is 4-bit ID
  // and arrives on s01 after AXI3/256→AXI4/512; XDMA-direct path
  // comes in on s00).  The switch is uniform AXI4/512 on both slave
  // ports — Vivado's axi_switch IP forces both S ports to share one
  // protocol/width when NUM_SI > 1, and the natural choice here is
  // the XDMA-shape (AXI4/512) since the XDMA path comes in at
  // exactly that.  The s01 leg has to be lifted from its native
  // AXI3/256 up to AXI4/512 before reaching the switch:
  //
  //   s00  axi_dma_hbm                                   — AXI4/512
  //   s01  s_axi_hbm_mux_axi4_512                        — AXI4/512
  //                                                       (RM port 31 after
  //                                                        AXI3→AXI4 +
  //                                                        256→512 chain)
  //   m00  axi_hbm_mux                                   — AXI3/256
  //
  // The two-IP s01 chain (axi_protocol_converter_0_inst →
  // axi_dwidth_converter_0_inst) handles AXI3→AXI4 and 256→512 on
  // the RM-side branch.  The switch's internal AXI4→AXI3 / 512→256
  // conversion on the m00 branch then drops both inputs onto HBM
  // port 31.

  // RM path: AXI3/256 → AXI4/256 (protocol) → AXI4/512 (width).
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    s_axi_hbm_mux_axi4_256 (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_protocol_converter_0_wrapper axi_hbm_mux_proto_inst (
    .aclk    (axi_aclk),
    .aresetn (intercon_aresetn),
    .s       (s_axi_hbm_31),
    .m       (s_axi_hbm_mux_axi4_256)
  );

  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4))
    s_axi_hbm_mux_axi4_512 (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_dwidth_converter_0_wrapper axi_hbm_mux_dwidth_inst (
    .aclk    (axi_aclk),
    .aresetn (intercon_aresetn),
    .s       (s_axi_hbm_mux_axi4_256),
    .m       (s_axi_hbm_mux_axi4_512)
  );

  axi_hbm_switch_wrapper axi_hbm_switch_inst (
    .aclk         (axi_aclk),
    .aresetn      (intercon_aresetn),
    .s00          (axi_dma_hbm),
    .s01          (s_axi_hbm_mux_axi4_512),
    .m00          (axi_hbm_mux),
    .aresetn_out  (),
    .pc_asserted  (),
    .pc_status    ()
  );

  // =========================================================================
  // AXI-Lite control-plane clock domain
  //
  // The entire control-plane switch network runs on icap_clk (100 MHz)
  // instead of axi_aclk (250 MHz).  Rationale:
  //
  //   * SYSMONE4's DCLK is rated to 250 MHz max; at exactly 4.0 ns
  //     period the intra-IP DCLK→FDRE paths had no routing slack and
  //     produced the worst-negative-setup violations.
  //   * The rest of the control plane (static regmap, HBICAP, CMS/QSPI
  //     via their own CDCs, HBM APB via icap_clk) is already happy at
  //     ≤ 100 MHz.
  //   * Dropping the switch to 100 MHz removes an unnecessarily tight
  //     domain; paths that actually need 250 MHz (XDMA DMA, HBM fabric,
  //     axi_dma_switch) are unaffected.
  //
  // Front-end CDC takes XDMA's 250 MHz axil_host down to the switch's
  // 100 MHz domain.  An M02 reverse CDC (100 → 250 MHz) reconverts on
  // the way out to m_axil_dynamic so the dynamic region can keep using
  // axi_aclk internally without being disturbed by this refactor.
  // =========================================================================
  wire icap_clk;
  wire icap_aresetn;

  // Switch-side (100 MHz) input bus — fed by the front-end CDC.
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axil_host_100 (.aclk(icap_clk), .aresetn(icap_aresetn));

  axi_lite_clock_converter axil_front_cdc_inst (
    .s_axi_aclk    (axi_aclk),
    .s_axi_aresetn (axi_aresetn),
    .s_axi_awaddr  (axil_host.awaddr),
    .s_axi_awprot  (axil_host.awprot),
    .s_axi_awvalid (axil_host.awvalid),
    .s_axi_awready (axil_host.awready),
    .s_axi_wdata   (axil_host.wdata),
    .s_axi_wstrb   (axil_host.wstrb),
    .s_axi_wvalid  (axil_host.wvalid),
    .s_axi_wready  (axil_host.wready),
    .s_axi_bresp   (axil_host.bresp),
    .s_axi_bvalid  (axil_host.bvalid),
    .s_axi_bready  (axil_host.bready),
    .s_axi_araddr  (axil_host.araddr),
    .s_axi_arprot  (axil_host.arprot),
    .s_axi_arvalid (axil_host.arvalid),
    .s_axi_arready (axil_host.arready),
    .s_axi_rdata   (axil_host.rdata),
    .s_axi_rresp   (axil_host.rresp),
    .s_axi_rvalid  (axil_host.rvalid),
    .s_axi_rready  (axil_host.rready),

    .m_axi_aclk    (icap_clk),
    .m_axi_aresetn (icap_aresetn),
    .m_axi_awaddr  (axil_host_100.awaddr),
    .m_axi_awprot  (axil_host_100.awprot),
    .m_axi_awvalid (axil_host_100.awvalid),
    .m_axi_awready (axil_host_100.awready),
    .m_axi_wdata   (axil_host_100.wdata),
    .m_axi_wstrb   (axil_host_100.wstrb),
    .m_axi_wvalid  (axil_host_100.wvalid),
    .m_axi_wready  (axil_host_100.wready),
    .m_axi_bresp   (axil_host_100.bresp),
    .m_axi_bvalid  (axil_host_100.bvalid),
    .m_axi_bready  (axil_host_100.bready),
    .m_axi_araddr  (axil_host_100.araddr),
    .m_axi_arprot  (axil_host_100.arprot),
    .m_axi_arvalid (axil_host_100.arvalid),
    .m_axi_arready (axil_host_100.arready),
    .m_axi_rdata   (axil_host_100.rdata),
    .m_axi_rresp   (axil_host_100.rresp),
    .m_axi_rvalid  (axil_host_100.rvalid),
    .m_axi_rready  (axil_host_100.rready)
  );

  // =========================================================================
  // AXI Switch (1 slave -> 4 masters), at 100 MHz
  // =========================================================================
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m00 (.aclk(icap_clk), .aresetn(icap_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m01 (.aclk(icap_clk), .aresetn(icap_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m02 (.aclk(icap_clk), .aresetn(icap_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m03 (.aclk(icap_clk), .aresetn(icap_aresetn));

  axil_host_switch_wrapper axil_host_switch_inst (
    .aclk         (icap_clk),
    .aresetn      (icap_aresetn),
    .s00          (axil_host_100),
    .m00          (axi_sw_m00),
    .m01          (axi_sw_m01),
    .m02          (axi_sw_m02),
    .m03          (axi_sw_m03),
    .aresetn_out  (),
    .pc_asserted  (),
    .pc_status    ()
  );

  // =========================================================================
  // M02 reverse CDC: switch (100 MHz) → m_axil_dynamic (axi_aclk, 250 MHz).
  //
  // Keeps the PR partition's s_axil on axi_aclk so the dynamic-region
  // hierarchy doesn't need re-clocking — only the static switch network
  // moves to 100 MHz.
  // =========================================================================
  axi_lite_clock_converter axil_dyn_cdc_inst (
    .s_axi_aclk    (icap_clk),
    .s_axi_aresetn (icap_aresetn),
    .s_axi_awaddr  (axi_sw_m02.awaddr),
    .s_axi_awprot  (axi_sw_m02.awprot),
    .s_axi_awvalid (axi_sw_m02.awvalid),
    .s_axi_awready (axi_sw_m02.awready),
    .s_axi_wdata   (axi_sw_m02.wdata),
    .s_axi_wstrb   (axi_sw_m02.wstrb),
    .s_axi_wvalid  (axi_sw_m02.wvalid),
    .s_axi_wready  (axi_sw_m02.wready),
    .s_axi_bresp   (axi_sw_m02.bresp),
    .s_axi_bvalid  (axi_sw_m02.bvalid),
    .s_axi_bready  (axi_sw_m02.bready),
    .s_axi_araddr  (axi_sw_m02.araddr),
    .s_axi_arprot  (axi_sw_m02.arprot),
    .s_axi_arvalid (axi_sw_m02.arvalid),
    .s_axi_arready (axi_sw_m02.arready),
    .s_axi_rdata   (axi_sw_m02.rdata),
    .s_axi_rresp   (axi_sw_m02.rresp),
    .s_axi_rvalid  (axi_sw_m02.rvalid),
    .s_axi_rready  (axi_sw_m02.rready),

    .m_axi_aclk    (axi_aclk),
    .m_axi_aresetn (axi_aresetn),
    .m_axi_awaddr  (m_axil_dynamic.awaddr),
    .m_axi_awprot  (m_axil_dynamic.awprot),
    .m_axi_awvalid (m_axil_dynamic.awvalid),
    .m_axi_awready (m_axil_dynamic.awready),
    .m_axi_wdata   (m_axil_dynamic.wdata),
    .m_axi_wstrb   (m_axil_dynamic.wstrb),
    .m_axi_wvalid  (m_axil_dynamic.wvalid),
    .m_axi_wready  (m_axil_dynamic.wready),
    .m_axi_bresp   (m_axil_dynamic.bresp),
    .m_axi_bvalid  (m_axil_dynamic.bvalid),
    .m_axi_bready  (m_axil_dynamic.bready),
    .m_axi_araddr  (m_axil_dynamic.araddr),
    .m_axi_arprot  (m_axil_dynamic.arprot),
    .m_axi_arvalid (m_axil_dynamic.arvalid),
    .m_axi_arready (m_axil_dynamic.arready),
    .m_axi_rdata   (m_axil_dynamic.rdata),
    .m_axi_rresp   (m_axil_dynamic.rresp),
    .m_axi_rvalid  (m_axil_dynamic.rvalid),
    .m_axi_rready  (m_axil_dynamic.rready)
  );

  // m_axil_dynamic carries full AXI4-ID/len fields (axi_if #(.ID_W(1))).
  // The clock converter only handles AXI-Lite; tie off the AXI4-only
  // master-side fields with valid single-beat defaults.
  assign m_axil_dynamic.awid     = '0;
  assign m_axil_dynamic.awlen    = '0;
  assign m_axil_dynamic.awsize   = 3'b010;  // 4 bytes/beat
  assign m_axil_dynamic.awburst  = 2'b01;   // INCR
  assign m_axil_dynamic.awlock   = 1'b0;
  assign m_axil_dynamic.awcache  = '0;
  assign m_axil_dynamic.awqos    = '0;
  assign m_axil_dynamic.awregion = '0;
  assign m_axil_dynamic.wlast    = 1'b1;
  assign m_axil_dynamic.arid     = '0;
  assign m_axil_dynamic.arlen    = '0;
  assign m_axil_dynamic.arsize   = 3'b010;
  assign m_axil_dynamic.arburst  = 2'b01;
  assign m_axil_dynamic.arlock   = 1'b0;
  assign m_axil_dynamic.arcache  = '0;
  assign m_axil_dynamic.arqos    = '0;
  assign m_axil_dynamic.arregion = '0;

  // =========================================================================
  // AXI-to-APB Bridge for HBM configuration (runs on icap_clk, 100 MHz).
  //
  // axi_sw_m03 is now already on icap_clk directly (via the front-end
  // CDC), so the APB-path CDC that used to live here is no longer
  // needed.
  // =========================================================================
  apb_if #(.ADDR_W(32)) apb_hbm_0 (.pclk(icap_clk), .preset_n(icap_aresetn));
  apb_if #(.ADDR_W(32)) apb_hbm_1 (.pclk(icap_clk), .preset_n(icap_aresetn));

  axi_apb_bridge_wrapper apb_bridge_inst (
    .s_axi   (axi_sw_m03),
    .m_apb_0 (apb_hbm_0),
    .m_apb_1 (apb_hbm_1)
  );

  // =========================================================================
  // HBM
  // =========================================================================
  wire        hbm_cattrip;
  wire  [6:0] hbm_temp_1;
  wire  [6:0] hbm_temp_2;

  hbm_wrapper hbm_inst (
    .hbm_ref_clk          (hbm_ref_clk),

    // Direct 1-to-1 mapping: HBM port NN ← s_axi_hbm_NN for NN=00..30.
    // Port 31 is the muxed landing (XDMA-direct + RM via axi_hbm_switch).
    .s_axi_00             (s_axi_hbm_00),
    .s_axi_01             (s_axi_hbm_01),
    .s_axi_02             (s_axi_hbm_02),
    .s_axi_03             (s_axi_hbm_03),
    .s_axi_04             (s_axi_hbm_04),
    .s_axi_05             (s_axi_hbm_05),
    .s_axi_06             (s_axi_hbm_06),
    .s_axi_07             (s_axi_hbm_07),
    .s_axi_08             (s_axi_hbm_08),
    .s_axi_09             (s_axi_hbm_09),
    .s_axi_10             (s_axi_hbm_10),
    .s_axi_11             (s_axi_hbm_11),
    .s_axi_12             (s_axi_hbm_12),
    .s_axi_13             (s_axi_hbm_13),
    .s_axi_14             (s_axi_hbm_14),
    .s_axi_15             (s_axi_hbm_15),
    .s_axi_16             (s_axi_hbm_16),
    .s_axi_17             (s_axi_hbm_17),
    .s_axi_18             (s_axi_hbm_18),
    .s_axi_19             (s_axi_hbm_19),
    .s_axi_20             (s_axi_hbm_20),
    .s_axi_21             (s_axi_hbm_21),
    .s_axi_22             (s_axi_hbm_22),
    .s_axi_23             (s_axi_hbm_23),
    .s_axi_24             (s_axi_hbm_24),
    .s_axi_25             (s_axi_hbm_25),
    .s_axi_26             (s_axi_hbm_26),
    .s_axi_27             (s_axi_hbm_27),
    .s_axi_28             (s_axi_hbm_28),
    .s_axi_29             (s_axi_hbm_29),
    .s_axi_30             (s_axi_hbm_30),
    // Port 31: output of axi_hbm_switch_inst — XDMA-direct (s00) muxed
    // with the RM's s_axi_hbm_31 leg (s01 after the protocol+dwidth
    // converter chain).
    .s_axi_31             (axi_hbm_mux),

    .apb_0_pclk           (apb_hbm_0.pclk),
    .apb_0_preset_n       (apb_hbm_0.preset_n),
    .apb_0_psel           (apb_hbm_0.psel),
    .apb_0_penable        (apb_hbm_0.penable),
    .apb_0_pwrite         (apb_hbm_0.pwrite),
    .apb_0_paddr          (apb_hbm_0.paddr[21:0]),
    .apb_0_pwdata         (apb_hbm_0.pwdata),
    .apb_0_prdata         (apb_hbm_0.prdata),
    .apb_0_pready         (apb_hbm_0.pready),
    .apb_0_pslverr        (apb_hbm_0.pslverr),

    .apb_1_pclk           (apb_hbm_1.pclk),
    .apb_1_preset_n       (apb_hbm_1.preset_n),
    .apb_1_psel           (apb_hbm_1.psel),
    .apb_1_penable        (apb_hbm_1.penable),
    .apb_1_pwrite         (apb_hbm_1.pwrite),
    .apb_1_paddr          (apb_hbm_1.paddr[21:0]),
    .apb_1_pwdata         (apb_hbm_1.pwdata),
    .apb_1_prdata         (apb_hbm_1.prdata),
    .apb_1_pready         (apb_hbm_1.pready),
    .apb_1_pslverr        (apb_hbm_1.pslverr),

    .dram_0_stat_cattrip  (hbm_cattrip),
    .dram_0_stat_temp     (hbm_temp_1),
    .dram_1_stat_cattrip  (),
    .dram_1_stat_temp     (hbm_temp_2),

    .apb_complete_0       (),
    .apb_complete_1       ()
  );

  // =========================================================================
  // System config (card management): scfg_reg + sysmon + CMS + QSPI flash
  // + HBICAP, fanned out via system_config_axi_crossbar.  Owns its own
  // 50/100 MHz clocks and CDCs internally.
  //
  // Stubbed out under `SIMULATION` because the module pulls in half a
  // dozen Xilinx IPs (including a Microblaze inside CMS) that are heavy
  // or unavailable in pure RTL sim.  The stub ties off both AXI slaves
  // so the rest of the design can simulate without hanging.
  // =========================================================================
`ifndef SIMULATION
  system_config system_config_inst (
    .s_axil                  (axi_sw_m00),
    .s_axi_hbicap_data       (axi_dma_hbicap),

    .satellite_uart_0_rxd    (satellite_uart_0_rxd),
    .satellite_uart_0_txd    (satellite_uart_0_txd),
    .satellite_gpio_0        (satellite_gpio_0),

    .hbm_temp_1_0            (hbm_temp_1),
    .hbm_temp_2_0            (hbm_temp_2),
    .interrupt_hbm_cattrip_0 (hbm_cattrip),

    .interrupt_host          (),

    // clk_wiz_50Mhz's MMCM reference: must stay on the 250 MHz XDMA
    // clock because its clk_out2 IS the 100 MHz icap_clk that now
    // drives system_config's s_axil — feeding s_axil's clock back in
    // would create a clocking loop.
    .aclk_ref                (axi_aclk),

    .icap_clk_out            (icap_clk),
    .icap_aresetn_out        (icap_aresetn)
  );
`else
  // ----- Simulation stub for system_config -----
  // AXI-Lite control slave (axi_sw_m00) — permanent not-ready.
  // Any testbench access to the system_config BAR window will stall;
  // the TB should avoid those addresses or add a timeout.
  assign axi_sw_m00.awready = 1'b0;
  assign axi_sw_m00.wready  = 1'b0;
  assign axi_sw_m00.bvalid  = 1'b0;
  assign axi_sw_m00.bresp   = 2'b00;
  assign axi_sw_m00.arready = 1'b0;
  assign axi_sw_m00.rvalid  = 1'b0;
  assign axi_sw_m00.rdata   = '0;
  assign axi_sw_m00.rresp   = 2'b00;

  // AXI4-Full HBICAP data slave (axi_dma_hbicap) — permanent not-ready.
  assign axi_dma_hbicap.awready = 1'b0;
  assign axi_dma_hbicap.wready  = 1'b0;
  assign axi_dma_hbicap.bid     = '0;
  assign axi_dma_hbicap.bvalid  = 1'b0;
  assign axi_dma_hbicap.bresp   = 2'b00;
  assign axi_dma_hbicap.arready = 1'b0;
  assign axi_dma_hbicap.rid     = '0;
  assign axi_dma_hbicap.rvalid  = 1'b0;
  assign axi_dma_hbicap.rdata   = '0;
  assign axi_dma_hbicap.rresp   = 2'b00;
  assign axi_dma_hbicap.rlast   = 1'b0;

  // Output pins — safe idle values.
  assign satellite_uart_0_txd = 1'b1;  // UART idle

  // system_config owns icap_clk / icap_aresetn in synthesis; in sim
  // forward the testbench clock/reset so the APB-path clock converter
  // still has a valid clock domain.  Becomes trivially same-clock.
  assign icap_clk     = axi_aclk;
  assign icap_aresetn = axi_aresetn;
`endif

  // =========================================================================
  // Static region register map (4 registers, host BAR offsets 0x0..0xC)
  //
  //   Reg 0 (offset 0x0)  — control register
  //                          bit 0    : decouple   (1 = isolate PR boundary)
  //                          bit 1    : dyn_reset  (1 = hold dynamic region
  //                                                 in reset; 0 = let
  //                                                 dyn_aresetn follow
  //                                                 periph_aresetn)
  //                          bits 31:2: reserved
  //   Reg 1 (offset 0x4)  — scratch / loopback
  //   Reg 2 (offset 0x8)  — scratch / loopback
  //   Reg 3 (offset 0xC)  — scratch / loopback
  //
  // Reads return whatever was last written.
  // =========================================================================
  localparam int NUM_STATIC_REGS = 4;

  logic [NUM_STATIC_REGS-1:0][31:0] static_reg_out;
  logic [NUM_STATIC_REGS-1:0][31:0] static_reg_in;
  logic [NUM_STATIC_REGS-1:0]       static_reg_wr;

  axil_reg_map #(
    .NUM_REGS  (NUM_STATIC_REGS)
  ) static_reg_map_inst (
    .s_axil    (axi_sw_m01),
    .reg_out   (static_reg_out),
    .reg_in    (static_reg_in),
    .reg_wr    (static_reg_wr)
  );

  assign static_reg_in = static_reg_out;

  // =========================================================================
  // Aurora 64b/66b — QSFP28 lane 0.
  //
  // GT primitive lives in the static region so partial reconfiguration
  // doesn't have to deal with GT-pad placement constraints in every RM.
  // The user-side AXI-Stream / AXI-Lite ports of aurora_64b66b_0 are
  // currently tied off inside aurora_static; wiring them across the
  // partition boundary to the dynamic region is a future step.
  //
  // Init clock reuses `hbm_ref_clk` (100 MHz from clk_wiz_hbm).
  // =========================================================================
  // Aurora user-side streams cross the PR boundary in the aurora
  // design — see src/dynamic/aurora/aurora_region.sv.  Wire them
  // through the aurora_if port to the dynamic region.
  aurora_static aurora_inst (
    .init_clk     (hbm_ref_clk),
    .gt_refclk1_p (qsfp_refclk_p),
    .gt_refclk1_n (qsfp_refclk_n),
    .rxp          (qsfp_rxp),
    .rxn          (qsfp_rxn),
    .txp          (qsfp_txp),
    .txn          (qsfp_txn),

    .user_clk     (aurora_user_clk),
    .user_aresetn (aurora_user_aresetn),
    .channel_up   (aurora.channel_up),

    .tx_tdata     (aurora.tx_tdata),
    .tx_tkeep     (aurora.tx_tkeep),
    .tx_tlast     (aurora.tx_tlast),
    .tx_tvalid    (aurora.tx_tvalid),
    .tx_tready    (aurora.tx_tready),

    .rx_tdata     (aurora.rx_tdata),
    .rx_tkeep     (aurora.rx_tkeep),
    .rx_tlast     (aurora.rx_tlast),
    .rx_tvalid    (aurora.rx_tvalid),

    .user_k_tx_tdata  (aurora.user_k_tx_tdata),
    .user_k_tx_tvalid (aurora.user_k_tx_tvalid),
    .user_k_tx_tready (aurora.user_k_tx_tready),
    .user_k_rx_tdata  (aurora.user_k_rx_tdata),
    .user_k_rx_tvalid (aurora.user_k_rx_tvalid)
  );

  // PR-boundary decouple control — bit 0 of reg 0.
  assign decouple = static_reg_out[0][0];

  // Dynamic-region reset — bit 1 of reg 0 ANDed with the system
  // peripheral reset.  Writing a 1 forces dyn_aresetn low regardless
  // of peripheral reset state; writing a 0 lets it track periph_aresetn.
  assign dyn_aresetn = periph_aresetn & ~static_reg_out[0][1];

endmodule: alveo_u50_static_aurora
