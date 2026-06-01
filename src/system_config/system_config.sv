// *************************************************************************
//
// Card-management subset of OpenNIC's system_config module.  Provides:
//
//   * `system_config_register`  — build / timestamp registers
//   * `system_management_wiz`   — XADC / on-die SYSMON
//   * `cms_subsystem`           — Card Management Subsystem (satellite uC,
//                                 HBM monitoring, host interrupt)
//   * `axi_hbicap_0`            — ICAP access for partial reconfiguration
//
// All four hang off a single AXI-Lite host slave through the
// `system_config_axi_crossbar` IP.  CMS runs in a 50 MHz clock domain,
// reached via an `axi_lite_clock_converter` CDC between the crossbar
// and the IP.  HBICAP's AXI control and data sides stay in the host
// clock domain; its internal ICAP engine runs at a dedicated 100 MHz
// clock from the same PLL (the IP has its own async CDC,
// `C_ENABLE_ASYNC = 1`).  SCFG-REG and SYSMON live entirely in the
// host clock domain.
//
// Clock tree inside this module:
//   axi_aclk (250 MHz from XDMA)
//     └── clk_wiz_50Mhz
//           ├── clk_out1 → BUFG → cms_clk  (50 MHz)  → CMS
//           └── clk_out2 → BUFG → icap_clk (100 MHz) → HBICAP ICAPE3
//
// Differences from upstream OpenNIC `system_config.sv`:
//   * The QDMA / CMAC / Packet-Adapter / Box0 / Box1 fanout outputs and
//     the `shell_rstn` / `user_rstn` reset coordination ports are gone —
//     this project does not contain any of those subsystems.
//   * `NUM_QDMA` / `NUM_CMAC_PORT` parameters are dropped (always 1, single
//     host AXI-Lite slave).
//   * The host slave is exposed as an `axi_if.slave` interface to match
//     the rest of this project's plumbing; the bodies of the AXI-Lite
//     fanout, the CDCs, and every sub-IP instantiation otherwise mirror
//     OpenNIC's `system_config.sv` line-for-line.
//   * The CMS BD wrapper (`cms_subsystem_wrapper`) is replaced with a
//     thin shim (`cms_subsystem_wrapper_if`) that instantiates the
//     auto-generated `cms_subsystem_0` IP module directly.  This avoids
//     having to ship a real Block-Design build flow for the
//     IPI-only `cms_subsystem` IP.
//
// *************************************************************************
`timescale 1ns/1ps
module system_config #(
  parameter [31:0] BUILD_TIMESTAMP = 32'h01010000
) (
  // Host AXI-Lite control (host clock domain).
  axi_if.slave  s_axil,

  // HBICAP high-bandwidth AXI4-Full data path (64-bit addr / 32-bit data
  // / 4-bit ID).  Driven by axi_dma_switch.M02 in alveo_u50_static.sv;
  // the AXI Switch IP already did the 512→32 data-width conversion.
  // The address is 64 bits on the wire, but HBICAP only uses the lower
  // 32 bits — we slice at the instantiation below.
  axi_if.slave  s_axi_hbicap_data,

  // CMS satellite controller pins (Alveo card I2C uC link).
  input         satellite_uart_0_rxd,
  output        satellite_uart_0_txd,
  input  [1:0]  satellite_gpio_0,

  // HBM temperature monitoring + cattrip alarm (sourced from hbm_wrapper).
  input  [6:0]  hbm_temp_1_0,
  input  [6:0]  hbm_temp_2_0,
  input         interrupt_hbm_cattrip_0,

  // Interrupt to host
  output        interrupt_host,

  // aclk_ref kept for ILA-clock domain inside system_config (currently
  // axi_aclk = 250 MHz from XDMA).  Previously this also fed the
  // internal MMCM; the MMCM has been moved out to pncel_static's
  // clk_island module, and system_config now receives the derived
  // clocks/resets as inputs (see cms_clk / icap_clk / *_aresetn below).
  input         aclk_ref,

  // Clocks + resets generated externally by clk_island in pncel_static.
  // Were previously generated inside this module from clk_wiz_50Mhz +
  // BUFGs + reset sync chains; that block was extracted so that sim
  // (where system_config is stubbed) can still get a real 100 MHz
  // cache_clk via the MMCM behavioral model.
  input         cms_clk,         // 50 MHz, drives CMS subsystem
  input         icap_clk,        // 100 MHz, drives HBICAP + the AXIL chain
  input         cms_locked,      // MMCM PLL lock indicator
  input         cms_aresetn,     // cms_clk-domain reset, active-low
  input         icap_aresetn,    // icap_clk-domain reset, active-low

  // PR-decouple control bits — sourced from scfg_reg's REG_PR_CTRL
  // (host BAR + 0x0005_001C).  pr_decouple drives the axi_decoupler
  // instances at the PR boundary; pr_dyn_reset asserts the dynamic-region
  // reset.  Routed straight out for the parent (pncel_top) to consume.
  output        pr_decouple,
  output        pr_dyn_reset,

  // Debug-only: XDMA's user_lnk_up routed in from pncel_static so the
  // u_ila_mmcm_lock ILA can show PCIe link status alongside cms_locked.
  // Caller must drive it (typically wired to xdma's user_lnk_up output).
  input         user_lnk_up_dbg
);

  // ---------------------------------------------------------------------
  // Convenience aliases for the host clock / reset
  // ---------------------------------------------------------------------
  wire aclk    = s_axil.aclk;
  wire aresetn = s_axil.aresetn;

  // ---------------------------------------------------------------------
  // Per-master AXI-Lite signals after the crossbar (verbose declaration
  // matches the OpenNIC convention so each downstream block reads
  // identically).  Master numbering:
  //   M00 = scfg_reg  (build/version registers)
  //   M01 = sysmon    (XADC / system_management_wiz)
  //   M02 = cms       (50 MHz, behind a CDC)
  //   M03 = hbicap    (host clock domain; ICAP clock runs at 100 MHz
  //                    internally, CDC handled by the IP)
  // ---------------------------------------------------------------------
  wire        axil_scfg_awvalid;
  wire [31:0] axil_scfg_awaddr;
  wire  [2:0] axil_scfg_awprot;
  wire        axil_scfg_awready;
  wire        axil_scfg_wvalid;
  wire [31:0] axil_scfg_wdata;
  wire  [3:0] axil_scfg_wstrb;
  wire        axil_scfg_wready;
  wire        axil_scfg_bvalid;
  wire  [1:0] axil_scfg_bresp;
  wire        axil_scfg_bready;
  wire        axil_scfg_arvalid;
  wire [31:0] axil_scfg_araddr;
  wire  [2:0] axil_scfg_arprot;
  wire        axil_scfg_arready;
  wire        axil_scfg_rvalid;
  wire [31:0] axil_scfg_rdata;
  wire  [1:0] axil_scfg_rresp;
  wire        axil_scfg_rready;

  wire        axil_smon_awvalid;
  wire [31:0] axil_smon_awaddr;
  wire  [2:0] axil_smon_awprot;
  wire        axil_smon_awready;
  wire        axil_smon_wvalid;
  wire [31:0] axil_smon_wdata;
  wire  [3:0] axil_smon_wstrb;
  wire        axil_smon_wready;
  wire        axil_smon_bvalid;
  wire  [1:0] axil_smon_bresp;
  wire        axil_smon_bready;
  wire        axil_smon_arvalid;
  wire [31:0] axil_smon_araddr;
  wire  [2:0] axil_smon_arprot;
  wire        axil_smon_arready;
  wire        axil_smon_rvalid;
  wire [31:0] axil_smon_rdata;
  wire  [1:0] axil_smon_rresp;
  wire        axil_smon_rready;

  wire        axil_cms_awvalid;
  wire [31:0] axil_cms_awaddr;
  wire  [2:0] axil_cms_awprot;
  wire        axil_cms_awready;
  wire        axil_cms_wvalid;
  wire [31:0] axil_cms_wdata;
  wire  [3:0] axil_cms_wstrb;
  wire        axil_cms_wready;
  wire        axil_cms_bvalid;
  wire  [1:0] axil_cms_bresp;
  wire        axil_cms_bready;
  wire        axil_cms_arvalid;
  wire [31:0] axil_cms_araddr;
  wire  [2:0] axil_cms_arprot;
  wire        axil_cms_arready;
  wire        axil_cms_rvalid;
  wire [31:0] axil_cms_rdata;
  wire  [1:0] axil_cms_rresp;
  wire        axil_cms_rready;

  // HBICAP.  Note: the HBICAP IP's s_axi_ctrl slave does NOT expose
  // awprot/arprot ports — those signals come out of the crossbar but
  // dead-end in these local wires, which is fine (Vivado will optimize
  // the dangling outputs away).
  wire        axil_hbicap_awvalid;
  wire [31:0] axil_hbicap_awaddr;
  wire  [2:0] axil_hbicap_awprot;
  wire        axil_hbicap_awready;
  wire        axil_hbicap_wvalid;
  wire [31:0] axil_hbicap_wdata;
  wire  [3:0] axil_hbicap_wstrb;
  wire        axil_hbicap_wready;
  wire        axil_hbicap_bvalid;
  wire  [1:0] axil_hbicap_bresp;
  wire        axil_hbicap_bready;
  wire        axil_hbicap_arvalid;
  wire [31:0] axil_hbicap_araddr;
  wire  [2:0] axil_hbicap_arprot;
  wire        axil_hbicap_arready;
  wire        axil_hbicap_rvalid;
  wire [31:0] axil_hbicap_rdata;
  wire  [1:0] axil_hbicap_rresp;
  wire        axil_hbicap_rready;

  // ---------------------------------------------------------------------
  // 1S:4M AXI-Lite crossbar.  Configured by
  // src/system_config/vivado_ip/system_config_axi_crossbar.tcl with
  // NUM_MI=4 and these address segments (all within host_switch M00,
  // which is now at host BAR 0x000000-0x07FFFF post-BAR-shrink):
  //
  //   M00 scfg_reg  0x00050000-0x00050FFF   (4 KB)   ← REG_PR_CTRL at +0x01C
  //   M01 sysmon    0x00060000-0x00061FFF   (8 KB)
  //   M02 cms       0x00000000-0x0003FFFF   (256 KB) — OpenNIC native
  //   M03 hbicap    0x00070000-0x00070FFF   (4 KB)
  // ---------------------------------------------------------------------
  system_config_axi_crossbar xbar_inst (
    .aclk          (aclk),
    .aresetn       (aresetn),

    .s_axi_awaddr  (s_axil.awaddr),
    .s_axi_awprot  (s_axil.awprot),
    .s_axi_awvalid (s_axil.awvalid),
    .s_axi_awready (s_axil.awready),
    .s_axi_wdata   (s_axil.wdata),
    .s_axi_wstrb   (s_axil.wstrb),
    .s_axi_wvalid  (s_axil.wvalid),
    .s_axi_wready  (s_axil.wready),
    .s_axi_bresp   (s_axil.bresp),
    .s_axi_bvalid  (s_axil.bvalid),
    .s_axi_bready  (s_axil.bready),
    .s_axi_araddr  (s_axil.araddr),
    .s_axi_arprot  (s_axil.arprot),
    .s_axi_arvalid (s_axil.arvalid),
    .s_axi_arready (s_axil.arready),
    .s_axi_rdata   (s_axil.rdata),
    .s_axi_rresp   (s_axil.rresp),
    .s_axi_rvalid  (s_axil.rvalid),
    .s_axi_rready  (s_axil.rready),

    .m_axi_awaddr  ({axil_hbicap_awaddr,  axil_cms_awaddr,  axil_smon_awaddr,  axil_scfg_awaddr}),
    .m_axi_awprot  ({axil_hbicap_awprot,  axil_cms_awprot,  axil_smon_awprot,  axil_scfg_awprot}),
    .m_axi_awvalid ({axil_hbicap_awvalid, axil_cms_awvalid, axil_smon_awvalid, axil_scfg_awvalid}),
    .m_axi_awready ({axil_hbicap_awready, axil_cms_awready, axil_smon_awready, axil_scfg_awready}),
    .m_axi_wdata   ({axil_hbicap_wdata,   axil_cms_wdata,   axil_smon_wdata,   axil_scfg_wdata}),
    .m_axi_wstrb   ({axil_hbicap_wstrb,   axil_cms_wstrb,   axil_smon_wstrb,   axil_scfg_wstrb}),
    .m_axi_wvalid  ({axil_hbicap_wvalid,  axil_cms_wvalid,  axil_smon_wvalid,  axil_scfg_wvalid}),
    .m_axi_wready  ({axil_hbicap_wready,  axil_cms_wready,  axil_smon_wready,  axil_scfg_wready}),
    .m_axi_bresp   ({axil_hbicap_bresp,   axil_cms_bresp,   axil_smon_bresp,   axil_scfg_bresp}),
    .m_axi_bvalid  ({axil_hbicap_bvalid,  axil_cms_bvalid,  axil_smon_bvalid,  axil_scfg_bvalid}),
    .m_axi_bready  ({axil_hbicap_bready,  axil_cms_bready,  axil_smon_bready,  axil_scfg_bready}),
    .m_axi_araddr  ({axil_hbicap_araddr,  axil_cms_araddr,  axil_smon_araddr,  axil_scfg_araddr}),
    .m_axi_arprot  ({axil_hbicap_arprot,  axil_cms_arprot,  axil_smon_arprot,  axil_scfg_arprot}),
    .m_axi_arvalid ({axil_hbicap_arvalid, axil_cms_arvalid, axil_smon_arvalid, axil_scfg_arvalid}),
    .m_axi_arready ({axil_hbicap_arready, axil_cms_arready, axil_smon_arready, axil_scfg_arready}),
    .m_axi_rdata   ({axil_hbicap_rdata,   axil_cms_rdata,   axil_smon_rdata,   axil_scfg_rdata}),
    .m_axi_rresp   ({axil_hbicap_rresp,   axil_cms_rresp,   axil_smon_rresp,   axil_scfg_rresp}),
    .m_axi_rvalid  ({axil_hbicap_rvalid,  axil_cms_rvalid,  axil_smon_rvalid,  axil_scfg_rvalid}),
    .m_axi_rready  ({axil_hbicap_rready,  axil_cms_rready,  axil_smon_rready,  axil_scfg_rready})
  );

  // ---------------------------------------------------------------------
  // M00 → system_config_register (build / timestamp / reset coordination
  // registers).  shell_rstn / user_rstn / *_rst_done are unused in this
  // project; tie *_rst_done to all-1s so the reg's done bits stay
  // asserted, and let synthesis trim shell_rstn / user_rstn outputs.
  // ---------------------------------------------------------------------
  wire [31:0] shell_rstn;
  wire [31:0] user_rstn;

  system_config_register #(
    .BUILD_TIMESTAMP (BUILD_TIMESTAMP)
  ) scfg_reg_inst (
    .s_axil_awvalid (axil_scfg_awvalid),
    .s_axil_awaddr  (axil_scfg_awaddr),
    .s_axil_awready (axil_scfg_awready),
    .s_axil_wvalid  (axil_scfg_wvalid),
    .s_axil_wdata   (axil_scfg_wdata),
    .s_axil_wready  (axil_scfg_wready),
    .s_axil_bvalid  (axil_scfg_bvalid),
    .s_axil_bresp   (axil_scfg_bresp),
    .s_axil_bready  (axil_scfg_bready),
    .s_axil_arvalid (axil_scfg_arvalid),
    .s_axil_araddr  (axil_scfg_araddr),
    .s_axil_arready (axil_scfg_arready),
    .s_axil_rvalid  (axil_scfg_rvalid),
    .s_axil_rdata   (axil_scfg_rdata),
    .s_axil_rresp   (axil_scfg_rresp),
    .s_axil_rready  (axil_scfg_rready),

    .shell_rstn     (shell_rstn),
    .shell_rst_done (32'hFFFFFFFF),
    .user_rstn      (user_rstn),
    .user_rst_done  (32'hFFFFFFFF),

    .pr_decouple    (pr_decouple),
    .pr_dyn_reset   (pr_dyn_reset),

    .aclk           (aclk),
    .aresetn        (aresetn)
  );

  // ---------------------------------------------------------------------
  // M01 → system_management_wiz (XADC, host clock domain).
  // ---------------------------------------------------------------------
  system_management_wiz sysmon_inst (
    .s_axi_aclk    (aclk),
    .s_axi_aresetn (aresetn),

    .s_axi_awaddr  (axil_smon_awaddr),
    .s_axi_awvalid (axil_smon_awvalid),
    .s_axi_awready (axil_smon_awready),
    .s_axi_wdata   (axil_smon_wdata),
    .s_axi_wstrb   (axil_smon_wstrb),
    .s_axi_wvalid  (axil_smon_wvalid),
    .s_axi_wready  (axil_smon_wready),
    .s_axi_bresp   (axil_smon_bresp),
    .s_axi_bvalid  (axil_smon_bvalid),
    .s_axi_bready  (axil_smon_bready),
    .s_axi_araddr  (axil_smon_araddr),
    .s_axi_arvalid (axil_smon_arvalid),
    .s_axi_arready (axil_smon_arready),
    .s_axi_rdata   (axil_smon_rdata),
    .s_axi_rresp   (axil_smon_rresp),
    .s_axi_rvalid  (axil_smon_rvalid),
    .s_axi_rready  (axil_smon_rready),

    // External analog input pins.  The U50 doesn't break these out to
    // any external probe pin, so tie to GND to silence the
    // [Synth 8-4442] BlackBox-unconnected critical warning.
    .vp            (1'b0),
    .vn            (1'b0)
  );

  // ---------------------------------------------------------------------
  // Clock generation has moved out of this module into clk_island.sv
  // (instantiated by pncel_static).  This module receives the derived
  // clocks (cms_clk, icap_clk) and resets (cms_aresetn, icap_aresetn,
  // cms_locked) as input ports — see the port list above.  The
  // ILA below still has access to them, just as inputs now.
  // ---------------------------------------------------------------------

`ifdef ENABLE_XDMA_ILA
  // ---------------------------------------------------------------------
  // Diagnostic ILA on the clk_wiz_50Mhz MMCM lock + derived resets.
  //
  // Clocked on aclk_ref (axi_aclk = 250 MHz) so we can observe the
  // MMCM coming up around PCIe enumeration time.  aclk_ref is the
  // MMCM's input reference, so by definition it's running whenever
  // the AXI fabric is alive.
  //
  // If `cms_locked` stays 0 forever, the entire chip-mem subsystem
  // (cache_clk-domain dynamic region) and sysconfig's internal AXI
  // crossbar are held in reset via icap_aresetn / cms_aresetn — which
  // would make every host BAR read time out as 0xFFFFFFFF.  This ILA
  // proves whether MMCM lock is the culprit in one capture.
  //
  // See src/utility/vivado_ip/ila_mmcm_lock.tcl for trigger recipes.
  // ---------------------------------------------------------------------
  ila_mmcm_lock u_ila_mmcm_lock (
    .clk    (aclk_ref),
    .probe0 (cms_locked),
    .probe1 (icap_aresetn),
    .probe2 (cms_aresetn),
    .probe3 (aresetn),          // XDMA axi_aresetn into the MMCM
    .probe4 (user_lnk_up_dbg)   // XDMA PCIe link-up status
  );
`endif

  // ---------------------------------------------------------------------
  // M02 → CMS (CDC 250 → 50 MHz, then cms_subsystem via wrapper_if shim)
  // ---------------------------------------------------------------------
  wire        axil_cms_int_awvalid;
  wire [31:0] axil_cms_int_awaddr;
  wire  [2:0] axil_cms_int_awprot;
  wire        axil_cms_int_awready;
  wire        axil_cms_int_wvalid;
  wire [31:0] axil_cms_int_wdata;
  wire  [3:0] axil_cms_int_wstrb;
  wire        axil_cms_int_wready;
  wire        axil_cms_int_bvalid;
  wire  [1:0] axil_cms_int_bresp;
  wire        axil_cms_int_bready;
  wire        axil_cms_int_arvalid;
  wire [31:0] axil_cms_int_araddr;
  wire  [2:0] axil_cms_int_arprot;
  wire        axil_cms_int_arready;
  wire        axil_cms_int_rvalid;
  wire [31:0] axil_cms_int_rdata;
  wire  [1:0] axil_cms_int_rresp;
  wire        axil_cms_int_rready;

  axi_lite_clock_converter axi_clock_conv_cms_inst (
    .s_axi_aclk    (aclk),
    .s_axi_aresetn (aresetn),
    .s_axi_awaddr  (axil_cms_awaddr),
    .s_axi_awprot  (axil_cms_awprot),
    .s_axi_awvalid (axil_cms_awvalid),
    .s_axi_awready (axil_cms_awready),
    .s_axi_wdata   (axil_cms_wdata),
    .s_axi_wstrb   (axil_cms_wstrb),
    .s_axi_wvalid  (axil_cms_wvalid),
    .s_axi_wready  (axil_cms_wready),
    .s_axi_bresp   (axil_cms_bresp),
    .s_axi_bvalid  (axil_cms_bvalid),
    .s_axi_bready  (axil_cms_bready),
    .s_axi_araddr  (axil_cms_araddr),
    .s_axi_arprot  (axil_cms_arprot),
    .s_axi_arvalid (axil_cms_arvalid),
    .s_axi_arready (axil_cms_arready),
    .s_axi_rdata   (axil_cms_rdata),
    .s_axi_rresp   (axil_cms_rresp),
    .s_axi_rvalid  (axil_cms_rvalid),
    .s_axi_rready  (axil_cms_rready),

    .m_axi_aclk    (cms_clk),
    .m_axi_aresetn (cms_aresetn),
    .m_axi_awaddr  (axil_cms_int_awaddr),
    .m_axi_awprot  (axil_cms_int_awprot),
    .m_axi_awvalid (axil_cms_int_awvalid),
    .m_axi_awready (axil_cms_int_awready),
    .m_axi_wdata   (axil_cms_int_wdata),
    .m_axi_wstrb   (axil_cms_int_wstrb),
    .m_axi_wvalid  (axil_cms_int_wvalid),
    .m_axi_wready  (axil_cms_int_wready),
    .m_axi_bresp   (axil_cms_int_bresp),
    .m_axi_bvalid  (axil_cms_int_bvalid),
    .m_axi_bready  (axil_cms_int_bready),
    .m_axi_araddr  (axil_cms_int_araddr),
    .m_axi_arprot  (axil_cms_int_arprot),
    .m_axi_arvalid (axil_cms_int_arvalid),
    .m_axi_arready (axil_cms_int_arready),
    .m_axi_rdata   (axil_cms_int_rdata),
    .m_axi_rresp   (axil_cms_int_rresp),
    .m_axi_rvalid  (axil_cms_int_rvalid),
    .m_axi_rready  (axil_cms_int_rready)
  );

  axi_lite_if axil_cms_if (.aclk(cms_clk), .aresetn(cms_aresetn));
  assign axil_cms_if.awaddr  = axil_cms_int_awaddr;
  assign axil_cms_if.awprot  = axil_cms_int_awprot;
  assign axil_cms_if.awvalid = axil_cms_int_awvalid;
  assign axil_cms_int_awready = axil_cms_if.awready;
  assign axil_cms_if.wdata   = axil_cms_int_wdata;
  assign axil_cms_if.wstrb   = axil_cms_int_wstrb;
  assign axil_cms_if.wvalid  = axil_cms_int_wvalid;
  assign axil_cms_int_wready = axil_cms_if.wready;
  assign axil_cms_int_bresp  = axil_cms_if.bresp;
  assign axil_cms_int_bvalid = axil_cms_if.bvalid;
  assign axil_cms_if.bready  = axil_cms_int_bready;
  assign axil_cms_if.araddr  = axil_cms_int_araddr;
  assign axil_cms_if.arprot  = axil_cms_int_arprot;
  assign axil_cms_if.arvalid = axil_cms_int_arvalid;
  assign axil_cms_int_arready = axil_cms_if.arready;
  assign axil_cms_int_rdata  = axil_cms_if.rdata;
  assign axil_cms_int_rresp  = axil_cms_if.rresp;
  assign axil_cms_int_rvalid = axil_cms_if.rvalid;
  assign axil_cms_if.rready  = axil_cms_int_rready;

  cms_subsystem_wrapper_if cms_inst (
    .s_axil               (axil_cms_if),

    .satellite_uart_0_rxd (satellite_uart_0_rxd),
    .satellite_uart_0_txd (satellite_uart_0_txd),
    .satellite_gpio_0     (satellite_gpio_0),

    .hbm_temp_1_0         (hbm_temp_1_0),
    .hbm_temp_2_0         (hbm_temp_2_0),
    .hbm_cattrip          (interrupt_hbm_cattrip_0),

    .interrupt_host       (interrupt_host)
  );

  // ---------------------------------------------------------------------
  // M03 → HBICAP (AXI-Lite control in the host clock domain, ICAP clock
  // at 100 MHz shared with the static-region icap_clk).
  //
  // The IP has two AXI slaves and one AXI-Stream master:
  //
  //   s_axi_ctrl  — AXI-Lite control registers, wired to the crossbar
  //                 M04 slice.  Host software drives HBICAP's FIFO,
  //                 control, and status registers through this port.
  //                 Runs on s_axi_aclk (the host clock).
  //
  //   s_axi       — AXI4-Full high-bandwidth streaming path for bulk
  //                 bitstream writes.  Not used in this design; tied
  //                 off with all inputs low.  Runs on s_axi_mm_aclk.
  //
  // To load a partial bitstream the host writes the bitstream words
  // one 32-bit dword at a time to HBICAP's WF (Write FIFO) register
  // through s_axi_ctrl.  Slower than the AXI4 streaming path but
  // simple and sufficient for the occasional PR event.
  //
  // eos_in is tied high: by the time any register write reaches the
  // IP the FPGA has long since finished its startup sequence.
  // ---------------------------------------------------------------------
  axi_hbicap_0 hbicap_inst (
    // Clocks and resets
    .icap_clk            (icap_clk),
    .eos_in              (1'b1),
    .s_axi_aclk          (aclk),
    .s_axi_aresetn       (aresetn),
    // s_axi_mm is the bulk-bitstream AXI4 slave and is driven by
    // axi_dma_switch.M02 at the top level — that traffic runs on the
    // 250 MHz XDMA user clock, not the 100 MHz control clock.  Drive
    // the IP's s_axi_mm_aclk from the same 250 MHz net so HBICAP's
    // built-in ASYNC_CLOCK FIFO can CDC 250→100 into icap_clk
    // internally (instead of leaving the 250→100 crossing unprotected
    // between the DMA switch and HBICAP).
    .s_axi_mm_aclk       (s_axi_hbicap_data.aclk),
    .s_axi_mm_aresetn    (s_axi_hbicap_data.aresetn),

    // S_AXI_CTRL — AXI-Lite control from system_config_axi_crossbar M03.
    // Note: no awprot/arprot on this slave — the crossbar's prot bits
    // dead-end in axil_hbicap_{aw,ar}prot.
    .s_axi_ctrl_awaddr   (axil_hbicap_awaddr),
    .s_axi_ctrl_awvalid  (axil_hbicap_awvalid),
    .s_axi_ctrl_awready  (axil_hbicap_awready),
    .s_axi_ctrl_wdata    (axil_hbicap_wdata),
    .s_axi_ctrl_wstrb    (axil_hbicap_wstrb),
    .s_axi_ctrl_wvalid   (axil_hbicap_wvalid),
    .s_axi_ctrl_wready   (axil_hbicap_wready),
    .s_axi_ctrl_bresp    (axil_hbicap_bresp),
    .s_axi_ctrl_bvalid   (axil_hbicap_bvalid),
    .s_axi_ctrl_bready   (axil_hbicap_bready),
    .s_axi_ctrl_araddr   (axil_hbicap_araddr),
    .s_axi_ctrl_arvalid  (axil_hbicap_arvalid),
    .s_axi_ctrl_arready  (axil_hbicap_arready),
    .s_axi_ctrl_rdata    (axil_hbicap_rdata),
    .s_axi_ctrl_rresp    (axil_hbicap_rresp),
    .s_axi_ctrl_rvalid   (axil_hbicap_rvalid),
    .s_axi_ctrl_rready   (axil_hbicap_rready),

    // S_AXI — AXI4-Full bitstream streaming path, driven by
    // axi_dma_switch.M02 via the top-level s_axi_hbicap_data port.
    //
    // Width mismatches handled at the connection:
    //   - 64-bit address is sliced to HBICAP's 32 bits (upper bits are
    //     zero for any transaction landing in HBICAP's DMA window).
    //   - 4-bit AXI ID is forced to 0 on the master side and
    //     zero-returned on the slave side.  HBICAP's s_axi_awid /
    //     s_axi_arid are 1 bit wide, and XDMA's bitstream DMA uses a
    //     single ID anyway.
    //   - 1-bit AxUSER signals get tied to 0 because axi_if doesn't
    //     expose a user field.
    .s_axi_awid          (1'b0),
    .s_axi_awaddr        (s_axi_hbicap_data.awaddr[31:0]),
    .s_axi_awlen         (s_axi_hbicap_data.awlen),
    .s_axi_awsize        (s_axi_hbicap_data.awsize),
    .s_axi_awburst       (s_axi_hbicap_data.awburst),
    .s_axi_awlock        (s_axi_hbicap_data.awlock),
    .s_axi_awcache       (s_axi_hbicap_data.awcache),
    .s_axi_awprot        (s_axi_hbicap_data.awprot),
    .s_axi_awqos         (s_axi_hbicap_data.awqos),
    .s_axi_awregion      (s_axi_hbicap_data.awregion),
    .s_axi_awuser        (1'b0),
    .s_axi_awvalid       (s_axi_hbicap_data.awvalid),
    .s_axi_awready       (s_axi_hbicap_data.awready),
    .s_axi_wdata         (s_axi_hbicap_data.wdata),
    .s_axi_wstrb         (s_axi_hbicap_data.wstrb),
    .s_axi_wlast         (s_axi_hbicap_data.wlast),
    .s_axi_wuser         (1'b0),
    .s_axi_wvalid        (s_axi_hbicap_data.wvalid),
    .s_axi_wready        (s_axi_hbicap_data.wready),
    .s_axi_bid           (),                          // 1-bit; dropped (zero-return below)
    .s_axi_bresp         (s_axi_hbicap_data.bresp),
    .s_axi_buser         (),
    .s_axi_bvalid        (s_axi_hbicap_data.bvalid),
    .s_axi_bready        (s_axi_hbicap_data.bready),
    .s_axi_arid          (1'b0),
    .s_axi_araddr        (s_axi_hbicap_data.araddr[31:0]),
    .s_axi_arlen         (s_axi_hbicap_data.arlen),
    .s_axi_arsize        (s_axi_hbicap_data.arsize),
    .s_axi_arburst       (s_axi_hbicap_data.arburst),
    .s_axi_arlock        (s_axi_hbicap_data.arlock),
    .s_axi_arcache       (s_axi_hbicap_data.arcache),
    .s_axi_arprot        (s_axi_hbicap_data.arprot),
    .s_axi_arqos         (s_axi_hbicap_data.arqos),
    .s_axi_arregion      (s_axi_hbicap_data.arregion),
    .s_axi_aruser        (1'b0),
    .s_axi_arvalid       (s_axi_hbicap_data.arvalid),
    .s_axi_arready       (s_axi_hbicap_data.arready),
    .s_axi_rid           (),                          // 1-bit; dropped (zero-return below)
    .s_axi_rdata         (s_axi_hbicap_data.rdata),
    .s_axi_rresp         (s_axi_hbicap_data.rresp),
    .s_axi_rlast         (s_axi_hbicap_data.rlast),
    .s_axi_ruser         (),
    .s_axi_rvalid        (s_axi_hbicap_data.rvalid),
    .s_axi_rready        (s_axi_hbicap_data.rready),

    // Interrupt to host — unconnected (not currently routed to CMS)
    .ip2intc_irpt        ()
  );

  // Zero-return the upper ID bits on the HBICAP response channels.
  // HBICAP only drives s_axi_bid[0] and s_axi_rid[0]; the switch's
  // master side expects a full 4-bit ID on those channels.  Because we
  // forced awid/arid to 0 above, all responses legitimately carry ID 0.
  assign s_axi_hbicap_data.bid = '0;
  assign s_axi_hbicap_data.rid = '0;

endmodule: system_config
