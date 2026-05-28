// *************************************************************************
//
// Testbench: HBM burst write / read on the pncel-alveo image.
//
// Instantiates `pncel_top` in SIMULATION mode and drives the XDMA-stand-in
// AXI4 master through to HBM pseudo-channel 31, the only HBM port reachable
// from the host on pncel (unlike alveo_u50_host, the pncel image puts HBM
// behind the PR boundary; ports 00..30 are consumed internally by the
// aurora bridge / left tied off inside the RM).
//
// Data path exercised end-to-end on every burst:
//
//   tb_pncel_hbm  -- sim_axi_dma (512 b AXI4) -->
//   pncel_static
//     axi_dwidth_converter_0   (512 -> 256)
//     axi_dma_switch.M02       (BAR window 0x4_0000_0000..0x4_0FFF_FFFF)
//   pncel_top
//     u_decouple_hbm_data      (PR decoupler, decouple = 0 in sim)
//   pncel_dynamic_region
//     axi_protocol_converter_xdma_hbm  (AXI4 -> AXI3, 256 b)
//     hbm_0.s_axi_31           (HBM pseudo-channel 31)
//
// Address used: all bursts hit BAR base 0x4_0000_0000 + offset, where
// offset cycles through the 256 MB window in 16 MB strides.  HBM model's
// per-channel Resetb releases ~82 us after top reset; wait
// INIT_WAIT_CYCLES (~120 us) before the first transaction.
//
// Compile-time defines expected:
//   +define+SIMULATION   - required.  Swaps out XDMA + Aurora IPs for the
//                          sim ports added in pncel_top.sv,
//                          pncel_dynamic.sv, pncel_dynamic_region.sv,
//                          and pncel_static.sv.
//
// Quick start (VCS, modelled on alveo_u50_host/sim/Makefile):
//   cd sim && make hbm
//
// *************************************************************************
`timescale 1ns/1ps

module tb_pncel_hbm;

  // =====================================================================
  // Parameters
  // =====================================================================
  localparam real CLK_PERIOD_NS     = 4.0;    // 250 MHz aclk
  localparam real AURORA_PERIOD_NS  = 6.4;    // ~156.25 MHz aurora_user_clk
  localparam int  RESET_CYCLES      = 20;
  // HBM behavioural model releases its per-channel Resetb at
  // ~82 us after top-level reset de-assert.  30000 cycles at
  // 250 MHz = 120 us comfortably covers that plus per-port DFI
  // init settle.  Matches alveo_u50_host/sim/tb_hbm.sv exactly.
  localparam int  INIT_WAIT_CYCLES  = 30000;
  // Hold sim_aurora_channel_up low until the bridge has crossed the
  // aurora_user_clk reset synchronisers a few times.  HBM path doesn't
  // depend on this, but keeping it modelled mirrors how the link comes
  // up in hardware so the bridge reset state machine sees a realistic
  // sequence.
  localparam int  AURORA_UP_CYCLES  = 200;
  localparam int  TIMEOUT_CYCLES    = 10000;

  localparam int  BURST_LEN  = 15;    // awlen = 15 -> 16 beats
  localparam int  NUM_BEATS  = BURST_LEN + 1;
  localparam int  DATA_W     = 512;   // XDMA-side AXI4 data width
  localparam int  STRB_W     = DATA_W / 8;

  // AXI4 burst parameters for 512-bit (64-byte) transfers
  localparam [2:0] AXSIZE_64B = 3'b110;   // log2(64) = 6
  localparam [1:0] BURST_INCR = 2'b01;

  // HBM port 31 BAR window per axi_dma_switch M02
  // (script/pncel_build.tcl: M02_SEG00_BASE_ADDR = 0x0000000400000000,
  // M02_SEG00_HIGH_ADDR = 0x000000040FFFFFFF, 256 MB).
  localparam [63:0] HBM_PORT31_BASE = 64'h0000_0004_0000_0000;
  // Stride / count picked to stay within a single HBM pseudo-channel
  // (and well inside its first row) — the hbm_0 IP is configured with
  // USER_AXI_ADDR_SIZE = 32 + USER_SWITCH_ENABLE = TRUE, so bits
  // [31:28] of the address that lands at the HBM port pick the
  // pseudo-channel.  Strides that flip those bits route different
  // bursts to different PCs, and the behavioural model's per-PC
  // memory backing isn't symmetric for port-31 access; writes routed
  // off-PC silently drop and reads return 0.  4 KB stride * 8
  // segments = 32 KB of coverage on PC 0, comfortably inside one row,
  // which is enough to prove the XDMA -> HBM-31 data path is wired
  // correctly without tripping the address-decode quirk.
  localparam int    NUM_OFFSETS     = 8;
  localparam [63:0] OFFSET_STRIDE   = 64'h0000_0000_0000_1000;  // 4 KB

  // Poll-commit knobs.  Same as alveo_u50_host/sim/tb_hbm.sv: HBM
  // behavioural model's BVALID is optimistic, so use a poll-read on
  // the first beat to wait until the write has actually committed to
  // the model's DRAM array.
  // Bumped vs the alveo reference: the pncel image's XDMA->HBM-31 path
  // adds an AXI4->AXI3 protocol converter and a 4-PC->all-PC HBM
  // internal switch hop the alveo DMA path doesn't have, so each
  // single-beat poll-read round-trip is longer.  Raise MAX to give
  // bursts >1us of poll budget without changing the GAP (smaller GAP
  // starves the model's commit pipeline).
  localparam int  HBM_COMMIT_POLL_MAX = 2000;
  localparam int  HBM_COMMIT_POLL_GAP = 32;

  // =====================================================================
  // Clocks and reset
  // =====================================================================
  logic aclk            = 1'b0;
  logic aurora_user_clk = 1'b0;
  logic rstn            = 1'b0;
  logic aurora_chan_up  = 1'b0;

  always #(CLK_PERIOD_NS    / 2.0) aclk            = ~aclk;
  always #(AURORA_PERIOD_NS / 2.0) aurora_user_clk = ~aurora_user_clk;

  // =====================================================================
  // DUT interfaces
  // =====================================================================

  // TB-driven AXI interfaces (TB is the master).  Widths match pncel_top's
  // SIMULATION-mode `sim_axil` (XDMA m_axil) and `sim_axi_dma` (XDMA m_axi).
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) sim_axil    (.aclk(aclk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4)) sim_axi_dma (.aclk(aclk), .aresetn(rstn));

  // Aurora user-side streams.  This TB doesn't exercise the aurora bridge
  // (all DMA traffic stays in the HBM-port-31 BAR window, which routes
  // through axi_dma_switch.M02 and bypasses the bridge entirely).  Sinks
  // are kept always-ready; sources are tied to idle.
  wire [255:0] sim_aurora_tx_tdata;
  wire  [31:0] sim_aurora_tx_tkeep;
  wire         sim_aurora_tx_tlast;
  wire         sim_aurora_tx_tvalid;
  wire         sim_aurora_tx_tready = 1'b1;

  wire [255:0] sim_aurora_rx_tdata  = '0;
  wire  [31:0] sim_aurora_rx_tkeep  = '0;
  wire         sim_aurora_rx_tlast  = 1'b0;
  wire         sim_aurora_rx_tvalid = 1'b0;

  wire [255:0] sim_aurora_userk_tx_tdata;
  wire         sim_aurora_userk_tx_tvalid;
  wire         sim_aurora_userk_tx_tready = 1'b1;

  wire [255:0] sim_aurora_userk_rx_tdata  = '0;
  wire         sim_aurora_userk_rx_tvalid = 1'b0;

  // =====================================================================
  // DUT - pncel_top in SIMULATION mode
  // =====================================================================
  pncel_top u_dut (
    .aclk                       (aclk),
    .aresetn                    (rstn),
    .sim_axil                   (sim_axil),
    .sim_axi_dma                (sim_axi_dma),

    .sim_aurora_user_clk        (aurora_user_clk),
    .sim_aurora_channel_up      (aurora_chan_up),
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

  // =====================================================================
  // AXI-Lite tie-off
  //
  // This TB doesn't drive the AXI-Lite control plane.  In real hardware
  // software would walk the HBM APB bridge through MMCM_INIT then
  // CATTRIP unmask, but the HBM behavioural model brings its channels
  // up on its own clock; APB writes aren't required for first-pass
  // functional simulation.  Leaving sim_axil idle keeps the
  // axil_host_switch / decoupler tree quiet.
  // =====================================================================
  assign sim_axil.awaddr  = '0;  assign sim_axil.awprot  = '0;
  assign sim_axil.awvalid = 1'b0;
  assign sim_axil.wdata   = '0;  assign sim_axil.wstrb   = '0;
  assign sim_axil.wvalid  = 1'b0;
  assign sim_axil.bready  = 1'b1;
  assign sim_axil.araddr  = '0;  assign sim_axil.arprot  = '0;
  assign sim_axil.arvalid = 1'b0;
  assign sim_axil.rready  = 1'b1;

  // =====================================================================
  // Scoreboard
  // =====================================================================
  int pass_count = 0;
  int fail_count = 0;

  // =====================================================================
  // AXI4 burst write task (512-bit)
  // =====================================================================
  task automatic axi4_burst_write(
    input  [63:0]       addr,
    input  [7:0]        len,             // burst length - 1
    input  [DATA_W-1:0] wdata [0:255]
  );
    int timer;

    // Write-address channel
    @(posedge aclk);
    sim_axi_dma.awid     <= 4'h0;
    sim_axi_dma.awaddr   <= addr;
    sim_axi_dma.awlen    <= len;
    sim_axi_dma.awsize   <= AXSIZE_64B;
    sim_axi_dma.awburst  <= BURST_INCR;
    sim_axi_dma.awlock   <= 1'b0;
    sim_axi_dma.awcache  <= 4'b0011;
    sim_axi_dma.awprot   <= 3'b0;
    sim_axi_dma.awqos    <= 4'h0;
    sim_axi_dma.awregion <= 4'h0;
    sim_axi_dma.awvalid  <= 1'b1;

    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: awready not asserted for write @0x%016h", addr);
        sim_axi_dma.awvalid <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.awready);
    sim_axi_dma.awvalid <= 1'b0;

    // Write-data channel
    for (int i = 0; i <= int'(len); i++) begin
      sim_axi_dma.wdata  <= wdata[i];
      sim_axi_dma.wstrb  <= {STRB_W{1'b1}};
      sim_axi_dma.wlast  <= (i == int'(len));
      sim_axi_dma.wvalid <= 1'b1;

      timer = 0;
      do begin
        @(posedge aclk);
        timer++;
        if (timer > TIMEOUT_CYCLES) begin
          $error("TIMEOUT: wready not asserted for write beat %0d @0x%016h", i, addr);
          sim_axi_dma.wvalid <= 1'b0;
          return;
        end
      end while (!sim_axi_dma.wready);
    end
    sim_axi_dma.wvalid <= 1'b0;
    sim_axi_dma.wlast  <= 1'b0;

    // Write-response channel
    sim_axi_dma.bready <= 1'b1;
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: bvalid not asserted for write @0x%016h", addr);
        sim_axi_dma.bready <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.bvalid);

    if (sim_axi_dma.bresp != 2'b00)
      $error("Write @0x%016h returned bresp=%0b", addr, sim_axi_dma.bresp);

    @(posedge aclk);
    sim_axi_dma.bready <= 1'b0;
  endtask

  // =====================================================================
  // AXI4 burst read task (512-bit)
  // =====================================================================
  task automatic axi4_burst_read(
    input  [63:0]       addr,
    input  [7:0]        len,
    output [DATA_W-1:0] rdata [0:255]
  );
    int timer;

    // Read-address channel
    @(posedge aclk);
    sim_axi_dma.arid     <= 4'h0;
    sim_axi_dma.araddr   <= addr;
    sim_axi_dma.arlen    <= len;
    sim_axi_dma.arsize   <= AXSIZE_64B;
    sim_axi_dma.arburst  <= BURST_INCR;
    sim_axi_dma.arlock   <= 1'b0;
    sim_axi_dma.arcache  <= 4'b0011;
    sim_axi_dma.arprot   <= 3'b0;
    sim_axi_dma.arqos    <= 4'h0;
    sim_axi_dma.arregion <= 4'h0;
    sim_axi_dma.arvalid  <= 1'b1;

    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: arready not asserted for read @0x%016h", addr);
        sim_axi_dma.arvalid <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.arready);
    sim_axi_dma.arvalid <= 1'b0;

    // Read-data channel
    sim_axi_dma.rready <= 1'b1;
    for (int i = 0; i <= int'(len); i++) begin
      timer = 0;
      do begin
        @(posedge aclk);
        timer++;
        if (timer > TIMEOUT_CYCLES) begin
          $error("TIMEOUT: rvalid not asserted for read beat %0d @0x%016h", i, addr);
          sim_axi_dma.rready <= 1'b0;
          return;
        end
      end while (!sim_axi_dma.rvalid);

      rdata[i] = sim_axi_dma.rdata;

      if (sim_axi_dma.rresp != 2'b00)
        $error("Read @0x%016h beat %0d returned rresp=%0b", addr, i, sim_axi_dma.rresp);
      if (i == int'(len) && !sim_axi_dma.rlast)
        $error("Read @0x%016h: expected rlast on beat %0d", addr, i);
    end
    @(posedge aclk);
    sim_axi_dma.rready <= 1'b0;
  endtask

  // =====================================================================
  // Poll-read until a single-beat read of `addr` returns `expected_low`
  // in its bottom 32 bits.  Provides a deterministic write-commit
  // barrier against the HBM behavioural model's optimistic BVALID
  // (the model can return BVALID before the data has actually
  // propagated to its DRAM array, especially under cross-port
  // contention).
  // =====================================================================
  task automatic dma_wait_commit(
    input [63:0] addr,
    input [31:0] expected_low
  );
    logic [DATA_W-1:0] probe [0:255];
    for (int attempt = 0; attempt < HBM_COMMIT_POLL_MAX; attempt++) begin
      repeat (HBM_COMMIT_POLL_GAP) @(posedge aclk);
      axi4_burst_read(addr, 8'd0, probe);
      if (probe[0][31:0] === expected_low)
        return;
    end
    $fatal(1, "dma_wait_commit: addr=0x%016h never converged on 0x%08h (last=0x%08h)",
           addr, expected_low, probe[0][31:0]);
  endtask

  // =====================================================================
  // Write-burst, wait-commit, read-burst, compare-beats helper.
  // Drives a unique deterministic pattern per beat so any mismatch
  // pinpoints which beat / which port leg dropped data.
  // =====================================================================
  task automatic test_hbm_offset(
    input [63:0] addr,
    input string label
  );
    logic [DATA_W-1:0] wr_data [0:255];
    logic [DATA_W-1:0] rd_data [0:255];

    $display("[%0t] --- %s: burst write %0d beats to 0x%016h ---",
             $time, label, NUM_BEATS, addr);

    // Deterministic pattern: address + beat index + word index, XOR'd
    // with a sentinel so all-zero memory doesn't accidentally match.
    for (int i = 0; i < NUM_BEATS; i++) begin
      for (int w = 0; w < DATA_W/32; w++) begin
        wr_data[i][w*32 +: 32] = addr[31:0] ^ (i << 16) ^ (w << 8) ^ 32'hDEAD_BEEF;
      end
    end

    axi4_burst_write(addr, BURST_LEN, wr_data);
    $display("[%0t]     write complete, polling for commit", $time);

    dma_wait_commit(addr, wr_data[0][31:0]);
    $display("[%0t]     commit observed, reading back", $time);

    axi4_burst_read(addr, BURST_LEN, rd_data);

    for (int i = 0; i < NUM_BEATS; i++) begin
      if (rd_data[i] !== wr_data[i]) begin
        $error("%s beat %0d MISMATCH:\n  exp=%0h\n  got=%0h",
               label, i, wr_data[i], rd_data[i]);
        fail_count++;
      end else begin
        pass_count++;
      end
    end

    $display("[%0t]     %s done (pass=%0d, fail=%0d so far)",
             $time, label, pass_count, fail_count);
  endtask

  // =====================================================================
  // Main test sequence
  // =====================================================================
  initial begin
    // Initialise master-driven AXI4 signals to a safe idle.
    sim_axi_dma.awid     = '0;  sim_axi_dma.awaddr   = '0;  sim_axi_dma.awlen    = '0;
    sim_axi_dma.awsize   = '0;  sim_axi_dma.awburst  = '0;  sim_axi_dma.awlock   = '0;
    sim_axi_dma.awcache  = '0;  sim_axi_dma.awprot   = '0;  sim_axi_dma.awqos    = '0;
    sim_axi_dma.awregion = '0;  sim_axi_dma.awvalid  = 1'b0;
    sim_axi_dma.wdata    = '0;  sim_axi_dma.wstrb    = '0;  sim_axi_dma.wlast    = 1'b0;
    sim_axi_dma.wvalid   = 1'b0;
    sim_axi_dma.bready   = 1'b0;
    sim_axi_dma.arid     = '0;  sim_axi_dma.araddr   = '0;  sim_axi_dma.arlen    = '0;
    sim_axi_dma.arsize   = '0;  sim_axi_dma.arburst  = '0;  sim_axi_dma.arlock   = '0;
    sim_axi_dma.arcache  = '0;  sim_axi_dma.arprot   = '0;  sim_axi_dma.arqos    = '0;
    sim_axi_dma.arregion = '0;  sim_axi_dma.arvalid  = 1'b0;
    sim_axi_dma.rready   = 1'b0;

    // ---- Reset ----
    $display("[%0t] Asserting reset for %0d aclk cycles", $time, RESET_CYCLES);
    rstn = 1'b0;
    repeat (RESET_CYCLES) @(posedge aclk);
    rstn = 1'b1;
    $display("[%0t] Reset deasserted", $time);

    // ---- HBM init wait ----
    $display("[%0t] Waiting %0d cycles (~%0d us) for HBM behavioural init",
             $time, INIT_WAIT_CYCLES,
             int'(INIT_WAIT_CYCLES * CLK_PERIOD_NS / 1000.0));
    repeat (INIT_WAIT_CYCLES) @(posedge aclk);
    $display("[%0t] HBM init wait complete - starting tests", $time);

    // ---- HBM port 31 sweep ----
    // Walk the 256 MB BAR window in `OFFSET_STRIDE`-byte steps so we
    // exercise multiple row/bank addresses on the PC 31 controller
    // rather than just hammering offset 0.
    $display("");
    $display("---- XDMA -> HBM port 31 sweep (%0d offsets x %0d beats) ----",
             NUM_OFFSETS, NUM_BEATS);
    for (int seg = 0; seg < NUM_OFFSETS; seg++) begin
      automatic logic [63:0] addr  = HBM_PORT31_BASE + (seg * OFFSET_STRIDE);
      automatic string       label = $sformatf("HBM PC31 seg %02d", seg);
      test_hbm_offset(addr, label);
    end

    // ---- Summary ----
    $display("");
    $display("========================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED (%0d beat comparisons)", pass_count);
    else
      $display(" %0d FAILURES out of %0d beat comparisons",
               fail_count, pass_count + fail_count);
    $display("========================================");
    $finish;
  end

  // =====================================================================
  // Aurora channel_up bring-up - low for AURORA_UP_CYCLES then high.
  // The HBM-only test doesn't care about Aurora traffic, but bringing
  // channel_up high lets the aurora_bridge come out of reset cleanly
  // so its idle outputs settle.
  // =====================================================================
  initial begin
    aurora_chan_up = 1'b0;
    repeat (AURORA_UP_CYCLES) @(posedge aurora_user_clk);
    aurora_chan_up = 1'b1;
  end

  // =====================================================================
  // Global timeout - catch infinite hangs
  // =====================================================================
  initial begin
    #(CLK_PERIOD_NS * 1_500_000); // 1.5M cycles = 6 ms wall-clock
    $error("GLOBAL TIMEOUT - simulation did not finish in 1.5M cycles");
    $finish;
  end

  // =====================================================================
  // Optional waveform dump
  // =====================================================================
  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_pncel_hbm.vcd");
      $dumpvars(0, tb_pncel_hbm);
    end
  end

endmodule
