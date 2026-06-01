// *************************************************************************
//
// pncel-alveo static region — minimal version.
//
// Only XDMA + system_config (which owns HBICAP) + the AXI splitters that
// must stay live during PR live here.  HBM, the HBM/control AXI fabric,
// MMCM, and proc_sys_reset moved into the dynamic region, so this static
// region is roughly 1/5 the size of the original alveo_u50_static.sv.
//
// Boundary to the parent wrapper (pncel_top):
//
//   axi_aclk / axi_aresetn — host clock / reset (XDMA-sourced)
//   decouple                — 1 bit, drives both axi_decoupler instances
//   dyn_aresetn             — active-low dynamic-region reset
//
//   m_axi_dynamic   — 256 b AXI4, XDMA data fanout's M00 leg.  Carries
//                     every host-DMA transaction that lands outside the
//                     HBICAP window (0x0_0000_0000 .. 0x1_FFFF_FFFF →
//                     dynamic region).  Decoupled by axi_decoupler in
//                     pncel_top.
//   m_axil_dynamic  — 32 b AXI-Lite, XDMA control fanout's M02 leg.
//                     Carries everything in 0x00100000-0x001FFFFF.
//                     Decoupled by axi_decoupler in pncel_top.
//
// Why each piece is still here:
//
//   * xdma_wrapper            — PCIe master; cannot be in PR (must stay
//                                live during reconfig so the host keeps
//                                its link).
//   * system_config            — owns HBICAP, which performs the partial
//                                reconfig itself.  Folding the
//                                PR-decouple register inside scfg_reg
//                                eliminates the need for a separate
//                                axil_reg_map in static.
//   * axi_dwidth_converter_0   — XDMA outputs 512 b; HBICAP / decoupler
//                                use 256 b.  The narrow happens once,
//                                here, so the decoupler's 256 b boundary
//                                is sized to match (vs a fat 512 b
//                                boundary that would burn fabric).
//   * axi_dma_switch (1→2)     — fans XDMA-256b to {HBICAP@32b, dynamic
//                                @256b}.  M01 is the HBICAP leg; the
//                                switch handles 256→32 narrow internally.
//                                Must be static: M01 carries the
//                                bitstream into HBICAP and HBICAP must
//                                stay reachable while decouple is high.
//   * axil_host_switch (1→4)   — only M00 (→ system_config) and M02 (→
//                                dynamic, decoupled) are connected.  M01
//                                and M03 dangle; their address ranges
//                                will return DECERR.  Same IP config as
//                                today's alveo_u50_host so the existing
//                                axil_host_switch.tcl can be reused.
//
// Note: no separate proc_sys_reset_0 here.  XDMA's axi_aresetn output is
// already synchronized to axi_aclk (the IP guarantees that), so a flat
// `assign axi_aresetn = xdma_aresetn` is sufficient for the half-dozen
// IPs that live in static.  The dynamic region instantiates its own
// proc_sys_reset_0 for its own fabric.
//
// Sim-mode (`define SIMULATION`) stub keeps the same `aclk` / `aresetn`
// + direct AXI input pattern as alveo_u50_static.sv so existing
// testbenches port over with minimal changes.
//
// *************************************************************************
`timescale 1ns/1ps
module pncel_static #(
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
`endif

`ifndef SIMULATION
  // Satellite controller link to the CMS uC.  Dropped in SIMULATION
  // because system_config (which uses these) is stubbed out, so the
  // pins would be dead-ends and trigger TFIPC warnings at the
  // pncel_top boundary.
  input               satellite_uart_0_rxd,
  output              satellite_uart_0_txd,
  input         [1:0] satellite_gpio_0,
`endif

  // Host clock / reset out to the parent wrapper (used to declare the
  // boundary axi_if interfaces).  Sourced from XDMA (or sim ports).
  output              axi_aclk,
  output              axi_aresetn,

  // PR-decouple control — bit 0 of system_config's REG_PR_CTRL.
  output              decouple,

  // Dynamic-region reset — periph_aresetn ANDed with ~bit-1 of REG_PR_CTRL.
  // Active-low.  pncel_top feeds this into the dynamic region's aresetn
  // input and uses it as the aresetn binding for every PR-boundary axi_if
  // on the dynamic side.
  output              dyn_aresetn,

  // 256 b AXI4 master to the PR partition, post-dwidth + post-switch.
  // pncel_top puts an axi_decoupler between this and the dynamic region.
  axi_if.master       m_axi_dynamic,

  // 256 b AXI4 master from axi_dma_switch M02 — XDMA's direct path to
  // HBM port 31 (address window 0x4_0000_0000-0x4_0FFF_FFFF, 256 MB).
  // Decoupled in pncel_top; protocol-converted from AXI4 to AXI3 inside
  // the RM before reaching the HBM IP.
  axi_if.master       m_axi_hbm,

  // 32 b AXI-Lite master to the PR partition, post-host-switch M02.
  // Also decoupled in pncel_top.
  axi_if.master       m_axil_dynamic,

  // Legacy J18 cattrip telemetry input — wired up by pncel_top from
  // the dynamic-region output.  Now permanently 0 (no HBM IP in the
  // partition any more), but kept so system_config's interrupt input
  // still has a defined driver.
  input wire          hbm_cattrip_i
);

  // ---------------------------------------------------------------------
  // Reset
  //
  // XDMA's axi_aresetn output (or the testbench's `aresetn` input in sim)
  // is already aclk-synchronous.  No proc_sys_reset needed for the
  // half-dozen IPs in static.  The dynamic region instantiates its own
  // proc_sys_reset for the larger fabric inside it.
  // ---------------------------------------------------------------------
  wire xdma_aresetn;
  assign axi_aresetn = xdma_aresetn;

  // ---------------------------------------------------------------------
  // axi_dma — XDMA's 512 b AXI4 high-bandwidth output.  This is what gets
  // narrowed to 256 b by axi_dwidth_converter_0 and then fans out via
  // axi_dma_switch into the HBICAP and decoupler branches.
  //
  // axil_host — XDMA's 32 b AXI-Lite control output.  Fans out via
  // axil_host_switch into system_config (M00) and the decoupler-bound
  // dynamic leg (M02).
  // ---------------------------------------------------------------------
  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4))
    axi_dma (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axil_host (.aclk(axi_aclk), .aresetn(axi_aresetn));

`ifndef SIMULATION
  // -------------------------------------------------------------------
  // PCIe reference clock buffer
  // -------------------------------------------------------------------
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

  // -------------------------------------------------------------------
  // XDMA
  // -------------------------------------------------------------------
  wire user_lnk_up;

  xdma_wrapper xdma_inst (
    .sys_clk                 (pcie_refclk),
    .sys_clk_gt              (pcie_refclk_gt),
    .sys_rst_n               (pcie_rstn),

    .pci_exp_txp             (pci_exp_txp),
    .pci_exp_txn             (pci_exp_txn),
    .pci_exp_rxp             (pci_exp_rxp),
    .pci_exp_rxn             (pci_exp_rxn),

    .axi_aclk                (axi_aclk),
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
  // -------------------------------------------------------------------
  // Simulation: clock/reset from ports, testbench drives AXI directly.
  // -------------------------------------------------------------------
  assign axi_aclk     = aclk;
  assign xdma_aresetn = aresetn;

  // Connect testbench AXI-Lite to axil_host
  assign axil_host.awaddr   = sim_axil.awaddr;
  assign axil_host.awprot   = sim_axil.awprot;
  assign axil_host.awvalid  = sim_axil.awvalid;
  assign sim_axil.awready   = axil_host.awready;
  assign axil_host.wdata    = sim_axil.wdata;
  assign axil_host.wstrb    = sim_axil.wstrb;
  assign axil_host.wvalid   = sim_axil.wvalid;
  assign sim_axil.wready    = axil_host.wready;
  assign sim_axil.bresp     = axil_host.bresp;
  assign sim_axil.bvalid    = axil_host.bvalid;
  assign axil_host.bready   = sim_axil.bready;
  assign axil_host.araddr   = sim_axil.araddr;
  assign axil_host.arprot   = sim_axil.arprot;
  assign axil_host.arvalid  = sim_axil.arvalid;
  assign sim_axil.arready   = axil_host.arready;
  assign sim_axil.rdata     = axil_host.rdata;
  assign sim_axil.rresp     = axil_host.rresp;
  assign sim_axil.rvalid    = axil_host.rvalid;
  assign axil_host.rready   = sim_axil.rready;

  // Connect testbench AXI4 DMA to axi_dma
  assign axi_dma.awid       = sim_axi_dma.awid;
  assign axi_dma.awaddr     = sim_axi_dma.awaddr;
  assign axi_dma.awlen      = sim_axi_dma.awlen;
  assign axi_dma.awsize     = sim_axi_dma.awsize;
  assign axi_dma.awburst    = sim_axi_dma.awburst;
  assign axi_dma.awlock     = sim_axi_dma.awlock;
  assign axi_dma.awcache    = sim_axi_dma.awcache;
  assign axi_dma.awprot     = sim_axi_dma.awprot;
  assign axi_dma.awqos      = sim_axi_dma.awqos;
  assign axi_dma.awregion   = sim_axi_dma.awregion;
  assign axi_dma.awvalid    = sim_axi_dma.awvalid;
  assign sim_axi_dma.awready = axi_dma.awready;
  assign axi_dma.wdata      = sim_axi_dma.wdata;
  assign axi_dma.wstrb      = sim_axi_dma.wstrb;
  assign axi_dma.wlast      = sim_axi_dma.wlast;
  assign axi_dma.wvalid     = sim_axi_dma.wvalid;
  assign sim_axi_dma.wready = axi_dma.wready;
  assign sim_axi_dma.bid    = axi_dma.bid;
  assign sim_axi_dma.bresp  = axi_dma.bresp;
  assign sim_axi_dma.bvalid = axi_dma.bvalid;
  assign axi_dma.bready     = sim_axi_dma.bready;
  assign axi_dma.arid       = sim_axi_dma.arid;
  assign axi_dma.araddr     = sim_axi_dma.araddr;
  assign axi_dma.arlen      = sim_axi_dma.arlen;
  assign axi_dma.arsize     = sim_axi_dma.arsize;
  assign axi_dma.arburst    = sim_axi_dma.arburst;
  assign axi_dma.arlock     = sim_axi_dma.arlock;
  assign axi_dma.arcache    = sim_axi_dma.arcache;
  assign axi_dma.arprot     = sim_axi_dma.arprot;
  assign axi_dma.arqos      = sim_axi_dma.arqos;
  assign axi_dma.arregion   = sim_axi_dma.arregion;
  assign axi_dma.arvalid    = sim_axi_dma.arvalid;
  assign sim_axi_dma.arready = axi_dma.arready;
  assign sim_axi_dma.rid    = axi_dma.rid;
  assign sim_axi_dma.rdata  = axi_dma.rdata;
  assign sim_axi_dma.rresp  = axi_dma.rresp;
  assign sim_axi_dma.rlast  = axi_dma.rlast;
  assign sim_axi_dma.rvalid = axi_dma.rvalid;
  assign axi_dma.rready     = sim_axi_dma.rready;
`endif

  // ---------------------------------------------------------------------
  // Data path: 512 → 256 dwidth → 1→2 switch (HBICAP + dynamic)
  // ---------------------------------------------------------------------
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4))
    axi_dma_256 (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_dwidth_converter_0_wrapper axi_dma_dwidth_inst (
    .aclk    (axi_aclk),
    .aresetn (axi_aresetn),
    .s       (axi_dma),
    .m       (axi_dma_256)
  );

  // M01 is HBICAP's bitstream slave (32 b).  Switch handles 256→32
  // narrow internally — see axi_dma_switch.tcl (M01_AXI_DATA_WIDTH=32).
  axi_if #(.ADDR_W(64), .DATA_W(32), .ID_W(4))
    axi_dma_hbicap (.aclk(axi_aclk), .aresetn(axi_aresetn));

  axi_dma_switch_wrapper axi_dma_switch_inst (
    .aclk         (axi_aclk),
    .aresetn      (axi_aresetn),
    .s00          (axi_dma_256),
    .m00          (m_axi_dynamic),   // 256 b → decoupler → dynamic (aurora bridge)
    .m01          (axi_dma_hbicap),  // 32 b  → system_config HBICAP
    .m02          (m_axi_hbm),       // 256 b → decoupler → dynamic (HBM port 31)
    .aresetn_out  (),
    .pc_asserted  (),
    .pc_status    ()
  );

  // ---------------------------------------------------------------------
  // Control path: XDMA AXI-Lite → 1→4 switch (only M00/M02 used)
  //
  //   M00 — 0x0030_0000..0x003F_FFFF → system_config (HBICAP ctrl,
  //                                                    SYSMON, CMS,
  //                                                    scfg_reg incl.
  //                                                    REG_PR_CTRL)
  //   M01 — 0x0000_0000..0x0000_0FFF → unused (was static_reg_map)
  //   M02 — 0x0010_0000..0x001F_FFFF → dynamic via axi_decoupler
  //   M03 — 0x0040_0000..0x007F_FFFF → unused (was HBM APB; HBM IP
  //                                            removed entirely)
  //
  // Same axil_host_switch IP as the original alveo_u50_host design —
  // reusing the existing TCL avoids creating a parallel 1→2 IP.  Unused
  // M01/M03 are tied off below; their address ranges will hit a DECERR
  // if software pokes them.
  // ---------------------------------------------------------------------
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m00 (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m01 (.aclk(axi_aclk), .aresetn(axi_aresetn));
  axi_if #(.ADDR_W(32), .DATA_W(32), .ID_W(1))
    axi_sw_m03 (.aclk(axi_aclk), .aresetn(axi_aresetn));

  axil_host_switch_wrapper axil_host_switch_inst (
    .aclk         (axi_aclk),
    .aresetn      (axi_aresetn),
    .s00          (axil_host),
    .m00          (axi_sw_m00),     // → system_config
    .m01          (axi_sw_m01),     // unused
    .m02          (m_axil_dynamic), // → decoupler → dynamic
    .m03          (axi_sw_m03),     // unused (was HBM APB)
    .aresetn_out  (),
    .pc_asserted  (),
    .pc_status    ()
  );

  // (axil_host_switch_wrapper already drives the AXI4 ID/LEN/burst/lock/
  //  cache/qos/region fields on m_axil_dynamic.  Adding our own tie-offs
  //  here causes multi-driver critical warnings during synth.)

  // Tie off unused switch master ports M01 and M03.  Slave side of the
  // dangling master reports permanent not-ready so unmapped accesses
  // don't hang.
  assign axi_sw_m01.awready = 1'b0;
  assign axi_sw_m01.wready  = 1'b0;
  assign axi_sw_m01.bvalid  = 1'b0;
  assign axi_sw_m01.bresp   = 2'b00;
  assign axi_sw_m01.arready = 1'b0;
  assign axi_sw_m01.rvalid  = 1'b0;
  assign axi_sw_m01.rdata   = '0;
  assign axi_sw_m01.rresp   = 2'b00;
  assign axi_sw_m03.awready = 1'b0;
  assign axi_sw_m03.wready  = 1'b0;
  assign axi_sw_m03.bvalid  = 1'b0;
  assign axi_sw_m03.bresp   = 2'b00;
  assign axi_sw_m03.arready = 1'b0;
  assign axi_sw_m03.rvalid  = 1'b0;
  assign axi_sw_m03.rdata   = '0;
  assign axi_sw_m03.rresp   = 2'b00;

  // ---------------------------------------------------------------------
  // system_config
  //
  // Owns HBICAP, SYSMON, CMS, and the scfg-reg map (which now includes
  // REG_PR_CTRL).  pr_decouple / pr_dyn_reset come from REG_PR_CTRL
  // bits [0] / [1] and drive this module's `decouple` output and the
  // local dyn_aresetn AND gate.
  //
  // HBM-temperature / cattrip inputs are tied off (HBM moved to dynamic,
  // so static CMS no longer has direct visibility into HBM state).
  // ---------------------------------------------------------------------
  wire pr_decouple_w;
  wire pr_dyn_reset_w;

  // ---------------------------------------------------------------------
  // Clock island — MMCM + BUFGs + reset synchronizers extracted out of
  // system_config so the MMCM lives outside any subsystem that's stubbed
  // in sim.  In HW, identical clocking behavior to having the MMCM inside
  // system_config.  In sim, clk_wiz_50Mhz's behavioral model still runs
  // (because system_config is stubbed but clk_island isn't), producing a
  // real 100 MHz cache_clk that's actually asynchronous to aclk — which
  // lets the cache_clk-domain CDCs be exercised in cosim instead of
  // running at the same rate as aclk.
  // ---------------------------------------------------------------------
  wire cms_clk;
  wire icap_clk;
  wire cms_locked;
  wire cms_aresetn;
  wire icap_aresetn;

  clk_island u_clk_island (
    .aclk_ref     (axi_aclk),
    .cms_clk      (cms_clk),
    .icap_clk     (icap_clk),
    .cms_locked   (cms_locked),
    .cms_aresetn  (cms_aresetn),
    .icap_aresetn (icap_aresetn)
  );

  // cache_clk port to the parent wrapper is driven by clk_island's
  // 100 MHz output regardless of SIMULATION mode.  Used to be assigned
  // inside the SIMULATION stub as `assign cache_clk = aclk` (a hack
  // because system_config — which held the MMCM — was stubbed).  No
  // longer needed.
  assign cache_clk = icap_clk;

`ifndef SIMULATION
  system_config #(
    .BUILD_TIMESTAMP (BUILD_TIMESTAMP)
  ) system_config_inst (
    .s_axil                  (axi_sw_m00),
    .s_axi_hbicap_data       (axi_dma_hbicap),

    .satellite_uart_0_rxd    (satellite_uart_0_rxd),
    .satellite_uart_0_txd    (satellite_uart_0_txd),
    .satellite_gpio_0        (satellite_gpio_0),

    // HBM moved to dynamic — CMS doesn't have a direct path to HBM
    // temperature any more, so temp reads stay tied to 0.  The
    // cattrip alarm is routed back across the PR boundary via
    // pncel_top so the CMS subsystem still sees real shutdown
    // events (and the J18 board pin gets driven, per Vivado DRC
    // PPURQ-1).
    .hbm_temp_1_0            (7'b0),
    .hbm_temp_2_0            (7'b0),
    .interrupt_hbm_cattrip_0 (hbm_cattrip_i),

    .interrupt_host          (),

    .aclk_ref                (axi_aclk),

    // Clocks + resets driven externally by clk_island (above).
    .cms_clk                 (cms_clk),
    .icap_clk                (icap_clk),
    .cms_locked              (cms_locked),
    .cms_aresetn             (cms_aresetn),
    .icap_aresetn            (icap_aresetn),

    .pr_decouple             (pr_decouple_w),
    .pr_dyn_reset            (pr_dyn_reset_w),

    // Debug-only: routed to u_ila_mmcm_lock inside system_config so the
    // MMCM-lock ILA capture also shows PCIe link state.
    .user_lnk_up_dbg         (user_lnk_up)
  );
`else
  // Simulation stub — system_config pulls in CMS Microblaze etc., heavy
  // for pure RTL sim.  Tie off both AXI slaves to permanent not-ready;
  // testbenches should avoid the system_config BAR window.  Default
  // pr_decouple/pr_dyn_reset both low so the PR boundary is live and the
  // dynamic region is out of reset for testbench traffic.
  assign axi_sw_m00.awready     = 1'b0;
  assign axi_sw_m00.wready      = 1'b0;
  assign axi_sw_m00.bvalid      = 1'b0;
  assign axi_sw_m00.bresp       = 2'b00;
  assign axi_sw_m00.arready     = 1'b0;
  assign axi_sw_m00.rvalid      = 1'b0;
  assign axi_sw_m00.rdata       = '0;
  assign axi_sw_m00.rresp       = 2'b00;

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

  assign pr_decouple_w          = 1'b0;
  assign pr_dyn_reset_w         = 1'b0;

  // cache_clk is no longer assigned here — clk_island (above the
  // ifndef SIMULATION block) drives it via icap_clk in both sim and
  // HW.  Sim now sees a real 100 MHz cache_clk from the clk_wiz_50Mhz
  // behavioral model.
`endif

  assign decouple = pr_decouple_w;

  // ---------------------------------------------------------------------
  // dyn_aresetn — XDMA reset ANDed with ~REG_PR_CTRL[1].  Software writes
  // bit 1 high to hold the dynamic region in reset (independent of system
  // reset), low to let it follow xdma_aresetn.
  // ---------------------------------------------------------------------
  assign dyn_aresetn = xdma_aresetn & ~pr_dyn_reset_w;

endmodule: pncel_static
