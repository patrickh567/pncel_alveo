// *************************************************************************
//
// clk_island — wrapper around clk_wiz_50Mhz + BUFGs + reset sync chains.
//
// Pulled out of system_config.sv so the MMCM (and its derived clocks +
// resets) lives in pncel_static.  Two reasons:
//
//   1. In simulation, system_config is stubbed out (it pulls in the
//      CMS Microblaze subsystem which doesn't behave well in pure-RTL
//      sim).  When the MMCM lived inside system_config, the stub had
//      to fake `cache_clk` with `assign cache_clk = aclk`, which made
//      the cache_clk-domain logic run at the same rate as aclk and
//      hid any CDC issues between aclk (250 MHz) and cache_clk
//      (100 MHz) from sim.  With the MMCM out here, the clk_wiz_50Mhz
//      IP's behavioral model runs in sim too, producing a real
//      100 MHz cache_clk that's actually asynchronous to aclk.
//
//   2. Cleaner separation of concerns — `pncel_static` is the
//      infrastructure region (XDMA + clock generation + AXI splitters);
//      `system_config` is just one peripheral cluster.  The peripheral
//      shouldn't be the source-of-truth for clocks the rest of the
//      design depends on.
//
// Inputs:
//   aclk_ref      reference clock for the MMCM.  Sourced from XDMA's
//                 axi_aclk (250 MHz).
//
// Outputs:
//   cms_clk       50 MHz, BUFG'd, drives the CMS subsystem.
//   icap_clk      100 MHz, BUFG'd, drives HBICAP and is exported as
//                 cache_clk to the dynamic region.
//   cms_locked    MMCM lock indicator — high when the PLL is locked.
//                 Both resets stay asserted until this rises.
//   cms_aresetn   cms_clk-domain reset, active-low.  Async assert /
//                 sync deassert on cms_clk, gated by cms_locked.
//   icap_aresetn  icap_clk-domain reset, same pattern, on icap_clk.
//
// The MMCM's reset port (.resetn) is intentionally disabled in the IP
// configuration (clk_wiz_50Mhz.tcl: CONFIG.USE_RESET=false).  MMCMs
// auto-lock on power-up as soon as their input clock is valid, and
// gating .resetn on an upstream reset (e.g. XDMA's axi_aresetn)
// created a chicken-and-egg startup deadlock.  See the matching
// commentary in pncel_static / mini_dice_alveo_dynamic_region.
//
// *************************************************************************
`timescale 1ns/1ps
module clk_island (
  input  wire aclk_ref,

  output wire cms_clk,
  output wire icap_clk,
  output wire cms_locked,
  output wire cms_aresetn,
  output wire icap_aresetn
);

  wire clk_50mhz_wiz_out;
  wire clk_100mhz_wiz_out;

  clk_wiz_50Mhz clk_wiz_inst (
    .clk_in1  (aclk_ref),
    .clk_out1 (clk_50mhz_wiz_out),
    .clk_out2 (clk_100mhz_wiz_out),
    .locked   (cms_locked)
  );

  BUFG clk_50mhz_bufg_inst (
    .I (clk_50mhz_wiz_out),
    .O (cms_clk)
  );

  BUFG clk_100mhz_bufg_inst (
    .I (clk_100mhz_wiz_out),
    .O (icap_clk)
  );

  localparam SYNC_STAGES = 2;

  // 50 MHz reset — async assert (cms_locked=0), sync deassert on cms_clk.
  reg [SYNC_STAGES-1:0] cms_aresetn_sync = {SYNC_STAGES{1'b0}};
  always @(posedge cms_clk) begin
    if (!cms_locked) cms_aresetn_sync <= {SYNC_STAGES{1'b0}};
    else             cms_aresetn_sync <= {cms_aresetn_sync[SYNC_STAGES-2:0], 1'b1};
  end
  assign cms_aresetn = cms_locked && cms_aresetn_sync[SYNC_STAGES-1];

  // 100 MHz reset — same pattern, separate sync chain on icap_clk.
  reg [SYNC_STAGES-1:0] icap_aresetn_sync = {SYNC_STAGES{1'b0}};
  always @(posedge icap_clk) begin
    if (!cms_locked) icap_aresetn_sync <= {SYNC_STAGES{1'b0}};
    else             icap_aresetn_sync <= {icap_aresetn_sync[SYNC_STAGES-2:0], 1'b1};
  end
  assign icap_aresetn = cms_locked && icap_aresetn_sync[SYNC_STAGES-1];

endmodule
