// *************************************************************************
//
// Testbench: HBM burst write / read exercising every pseudo-channel.
//
// Instantiates `alveo_u50_static` in SIMULATION mode and drives two
// classes of traffic:
//
//   1. DMA-path coverage: 4 write/read bursts through `sim_axi_dma`
//      → `axi_dma_switch` → `axi_hbm_switch` → HBM port 00.  This
//      proves the full host-to-HBM plumbing (512-bit data, 512→256
//      width conversion, AXI4→AXI3 burst splitting).
//
//   2. Per-PC coverage: 31 write/read bursts driven directly into
//      each of the HBM IP's per-pseudo-channel AXI slave ports
//      (`s_axi_hbm_01`..`s_axi_hbm_31`) via the top-level HBM port
//      interface.  Each port corresponds to one HBM2 pseudo-channel
//      (8 GB / 32 PCs = 256 MB per PC), so driving a distinct
//      address on every port guarantees every PC sees traffic.
//
// Prerequisites:
//   1. `make project` must have been run to generate all IP outputs.
//   2. Compile with +define+SIMULATION and include the Vivado-generated
//      simulation models for every IP (switches, proc_sys_reset, HBM).
//      The system_config block is automatically stubbed when SIMULATION
//      is defined — no sim model needed for CMS/QSPI/SYSMON/HBICAP.
//   3. The HBM simulation model may take many cycles to initialise its
//      memory controllers.  Adjust INIT_WAIT_CYCLES below if the first
//      transaction times out.
//
// Quick start (VCS):
//   cd sim && make
//
// *************************************************************************
`timescale 1ns/1ps

// -------------------------------------------------------------------------
// Macro to tie off an HBM slave port (master side) — no transactions.
// -------------------------------------------------------------------------
`define TB_HBM_SLAVE_TIEOFF(IF)  \
    assign IF.awid     = '0;      \
    assign IF.awaddr   = '0;      \
    assign IF.awlen    = '0;      \
    assign IF.awsize   = '0;      \
    assign IF.awburst  = '0;      \
    assign IF.awlock   = 1'b0;    \
    assign IF.awcache  = '0;      \
    assign IF.awprot   = '0;      \
    assign IF.awqos    = '0;      \
    assign IF.awregion = '0;      \
    assign IF.awvalid  = 1'b0;    \
    assign IF.wdata    = '0;      \
    assign IF.wstrb    = '0;      \
    assign IF.wlast    = 1'b0;    \
    assign IF.wvalid   = 1'b0;    \
    assign IF.bready   = 1'b1;    \
    assign IF.arid     = '0;      \
    assign IF.araddr   = '0;      \
    assign IF.arlen    = '0;      \
    assign IF.arsize   = '0;      \
    assign IF.arburst  = '0;      \
    assign IF.arlock   = 1'b0;    \
    assign IF.arcache  = '0;      \
    assign IF.arprot   = '0;      \
    assign IF.arqos    = '0;      \
    assign IF.arregion = '0;      \
    assign IF.arvalid  = 1'b0;    \
    assign IF.rready   = 1'b1

// -------------------------------------------------------------------------
// Macro to tie off a master-side axi_if port (drive slave responses to
// idle — used for the dynamic region's m_axil / m_axi outputs that have
// nothing to talk to in this TB).
// -------------------------------------------------------------------------
`define TB_MASTER_TIEOFF(IF)     \
    assign IF.awready = 1'b0;     \
    assign IF.wready  = 1'b0;     \
    assign IF.bid     = '0;       \
    assign IF.bvalid  = 1'b0;     \
    assign IF.bresp   = 2'b00;    \
    assign IF.arready = 1'b0;     \
    assign IF.rid     = '0;       \
    assign IF.rvalid  = 1'b0;     \
    assign IF.rdata   = '0;       \
    assign IF.rresp   = 2'b00;    \
    assign IF.rlast   = 1'b0

module tb_hbm;

  // =====================================================================
  // Parameters
  // =====================================================================
  localparam real CLK_PERIOD_NS     = 4.0;    // 250 MHz
  localparam real HBM_REF_PERIOD_NS = 10.0;   // 100 MHz
  localparam int  RESET_CYCLES      = 20;
  // HBM behavioural model releases its per-channel Resetb at
  // ~82 us after top-level reset de-assert (it prints
  // "HBM[CH_A] : Resetb is de-asserted at 82234 ns" in the log).
  // 30000 cycles at 250 MHz = 120 us comfortably covers that plus
  // per-port DFI init settle.  apb_complete_0/1 go high much
  // earlier (~300 ns) but lie about readiness, so we can't use
  // them as the gate.
  localparam int  INIT_WAIT_CYCLES  = 30000;
  localparam int  TIMEOUT_CYCLES    = 10000;

  localparam int  BURST_LEN  = 15;    // awlen = 15 → 16 beats
  localparam int  NUM_BEATS  = BURST_LEN + 1;
  localparam int  DATA_W     = 512;
  localparam int  STRB_W     = DATA_W / 8;

  // AXI4 burst parameters for 512-bit (64-byte) transfers
  localparam [2:0] AXSIZE_64B = 3'b110;   // log2(64) = 6
  localparam [1:0] BURST_INCR = 2'b01;

  // =====================================================================
  // Clock and reset
  // =====================================================================
  logic clk = 0;
  logic hbm_ref_clk = 0;
  logic rstn = 0;

  always #(CLK_PERIOD_NS / 2.0)     clk         = ~clk;
  always #(HBM_REF_PERIOD_NS / 2.0) hbm_ref_clk = ~hbm_ref_clk;

  // =====================================================================
  // DUT interfaces
  // =====================================================================

  // TB-driven AXI interfaces (TB is the master)
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) axil_if  (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4)) dma_if   (.aclk(clk), .aresetn(rstn));

  // Dynamic-region master output (needs slave tie-off)
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) dyn_axil (.aclk(clk), .aresetn(rstn));

  // HBM slave ports 01–31 + mux (need master tie-offs)
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_01 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_02 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_03 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_04 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_05 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_06 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_07 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_08 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_09 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_10 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_11 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_12 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_13 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_14 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_15 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_16 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_17 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_18 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_19 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_20 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_21 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_22 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_23 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_24 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_25 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_26 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_27 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_28 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_29 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_30 (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(6), .LEN_W(4)) hbm_31 (.aclk(clk), .aresetn(rstn));
  // hbm_mux feeds axi_hbm_switch.s01, which is now 256-bit AXI3 (4-bit
  // ID, 4-bit LEN) — matches the static-side switch's HBM-port shape
  // since the AXI4→AXI3 conversion now happens inside the RM's tree-
  // root switch.
  axi_if #(.ADDR_W(64), .DATA_W(256), .ID_W(4), .LEN_W(4)) hbm_mux(.aclk(clk), .aresetn(rstn));

  // DUT outputs (directly observed)
  wire dut_axi_aclk;
  wire dut_axi_aresetn;
  wire dut_decouple;
  wire dut_dyn_aresetn;

  // =====================================================================
  // DUT — alveo_u50_static in SIMULATION mode
  // =====================================================================
  alveo_u50_static dut (
    .aclk                (clk),
    .aresetn             (rstn),
    .sim_axil            (axil_if),
    .sim_axi_dma         (dma_if),

    .satellite_uart_0_rxd (1'b1),
    .satellite_uart_0_txd (),
    .satellite_gpio_0     (2'b0),
    .hbm_ref_clk_sim      (hbm_ref_clk),

    .axi_aclk             (dut_axi_aclk),
    .axi_aresetn          (dut_axi_aresetn),
    .decouple             (dut_decouple),
    .dyn_aresetn           (dut_dyn_aresetn),

    .m_axil_dynamic        (dyn_axil),

    .s_axi_hbm_01 (hbm_01), .s_axi_hbm_02 (hbm_02), .s_axi_hbm_03 (hbm_03),
    .s_axi_hbm_04 (hbm_04), .s_axi_hbm_05 (hbm_05), .s_axi_hbm_06 (hbm_06),
    .s_axi_hbm_07 (hbm_07), .s_axi_hbm_08 (hbm_08), .s_axi_hbm_09 (hbm_09),
    .s_axi_hbm_10 (hbm_10), .s_axi_hbm_11 (hbm_11), .s_axi_hbm_12 (hbm_12),
    .s_axi_hbm_13 (hbm_13), .s_axi_hbm_14 (hbm_14), .s_axi_hbm_15 (hbm_15),
    .s_axi_hbm_16 (hbm_16), .s_axi_hbm_17 (hbm_17), .s_axi_hbm_18 (hbm_18),
    .s_axi_hbm_19 (hbm_19), .s_axi_hbm_20 (hbm_20), .s_axi_hbm_21 (hbm_21),
    .s_axi_hbm_22 (hbm_22), .s_axi_hbm_23 (hbm_23), .s_axi_hbm_24 (hbm_24),
    .s_axi_hbm_25 (hbm_25), .s_axi_hbm_26 (hbm_26), .s_axi_hbm_27 (hbm_27),
    .s_axi_hbm_28 (hbm_28), .s_axi_hbm_29 (hbm_29), .s_axi_hbm_30 (hbm_30),
    .s_axi_hbm_31 (hbm_31),
    .s_axi_hbm_mux (hbm_mux)
  );

  // =====================================================================
  // Tie-offs for unused interfaces
  // =====================================================================

  // Dynamic-region master output — sink with not-ready
  `TB_MASTER_TIEOFF(dyn_axil);

  // hbm_01..31 are driven procedurally by the per-PC test loop via
  // the virtual-interface array `hbm_vif[]` declared below — no
  // continuous tie-off here.  hbm_mux (AXI-full s01 of the HBM
  // switch, used by the PR partition in real designs) is unused in
  // this TB, so it stays tied off.
  `TB_HBM_SLAVE_TIEOFF(hbm_mux);

  // AXI-Lite interface — not used in this TB (we only test DMA/HBM)
  assign axil_if.awaddr  = '0;  assign axil_if.awprot  = '0;
  assign axil_if.awvalid = 1'b0;
  assign axil_if.wdata   = '0;  assign axil_if.wstrb   = '0;
  assign axil_if.wvalid  = 1'b0;
  assign axil_if.bready  = 1'b1;
  assign axil_if.araddr  = '0;  assign axil_if.arprot  = '0;
  assign axil_if.arvalid = 1'b0;
  assign axil_if.rready  = 1'b1;

  // =====================================================================
  // Direct-HBM test infrastructure
  //
  // The 31 direct HBM ports are driven procedurally via a virtual
  // interface array, so one set of tasks can cycle through every
  // pseudo-channel.
  // =====================================================================
  localparam int  HBM_DATA_W = 256;
  localparam int  HBM_STRB_W = HBM_DATA_W / 8;
  localparam [2:0] AXSIZE_32B = 3'b101;   // log2(32) = 5

  typedef virtual axi_if #(.ADDR_W(64), .DATA_W(HBM_DATA_W),
                           .ID_W(6), .LEN_W(4)) hbm_vif_t;

  hbm_vif_t hbm_vif [1:31];

  // =====================================================================
  // Scoreboard
  // =====================================================================
  int pass_count = 0;
  int fail_count = 0;

  // =====================================================================
  // AXI4 burst write task
  // =====================================================================
  task automatic axi4_burst_write(
    input  [63:0]    addr,
    input  [7:0]     len,             // burst length - 1
    input  [DATA_W-1:0] wdata [0:255] // data beats
  );
    int timer;

    // Write-address channel
    @(posedge clk);
    dma_if.awid     <= 4'h0;
    dma_if.awaddr   <= addr;
    dma_if.awlen    <= len;
    dma_if.awsize   <= AXSIZE_64B;
    dma_if.awburst  <= BURST_INCR;
    dma_if.awlock   <= 1'b0;
    dma_if.awcache  <= 4'b0011;
    dma_if.awprot   <= 3'b0;
    dma_if.awqos    <= 4'h0;
    dma_if.awregion <= 4'h0;
    dma_if.awvalid  <= 1'b1;

    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: awready not asserted for write @0x%016h", addr);
        dma_if.awvalid <= 1'b0;
        return;
      end
    end while (!dma_if.awready);
    dma_if.awvalid <= 1'b0;

    // Write-data channel
    for (int i = 0; i <= len; i++) begin
      dma_if.wdata  <= wdata[i];
      dma_if.wstrb  <= {STRB_W{1'b1}};
      dma_if.wlast  <= (i == int'(len));
      dma_if.wvalid <= 1'b1;

      timer = 0;
      do begin
        @(posedge clk);
        timer++;
        if (timer > TIMEOUT_CYCLES) begin
          $error("TIMEOUT: wready not asserted for write beat %0d @0x%016h", i, addr);
          dma_if.wvalid <= 1'b0;
          return;
        end
      end while (!dma_if.wready);
    end
    dma_if.wvalid <= 1'b0;
    dma_if.wlast  <= 1'b0;

    // Write-response channel
    dma_if.bready <= 1'b1;
    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: bvalid not asserted for write @0x%016h", addr);
        dma_if.bready <= 1'b0;
        return;
      end
    end while (!dma_if.bvalid);

    if (dma_if.bresp != 2'b00)
      $error("Write @0x%016h returned bresp=%0b", addr, dma_if.bresp);

    @(posedge clk);
    dma_if.bready <= 1'b0;
  endtask

  // =====================================================================
  // AXI4 burst read task
  // =====================================================================
  task automatic axi4_burst_read(
    input  [63:0]    addr,
    input  [7:0]     len,
    output [DATA_W-1:0] rdata [0:255]
  );
    int timer;

    // Read-address channel
    @(posedge clk);
    dma_if.arid     <= 4'h0;
    dma_if.araddr   <= addr;
    dma_if.arlen    <= len;
    dma_if.arsize   <= AXSIZE_64B;
    dma_if.arburst  <= BURST_INCR;
    dma_if.arlock   <= 1'b0;
    dma_if.arcache  <= 4'b0011;
    dma_if.arprot   <= 3'b0;
    dma_if.arqos    <= 4'h0;
    dma_if.arregion <= 4'h0;
    dma_if.arvalid  <= 1'b1;

    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: arready not asserted for read @0x%016h", addr);
        dma_if.arvalid <= 1'b0;
        return;
      end
    end while (!dma_if.arready);
    dma_if.arvalid <= 1'b0;

    // Read-data channel
    dma_if.rready <= 1'b1;
    for (int i = 0; i <= len; i++) begin
      timer = 0;
      do begin
        @(posedge clk);
        timer++;
        if (timer > TIMEOUT_CYCLES) begin
          $error("TIMEOUT: rvalid not asserted for read beat %0d @0x%016h", i, addr);
          dma_if.rready <= 1'b0;
          return;
        end
      end while (!dma_if.rvalid);

      rdata[i] = dma_if.rdata;

      if (dma_if.rresp != 2'b00)
        $error("Read @0x%016h beat %0d returned rresp=%0b", addr, i, dma_if.rresp);
      if (i == int'(len) && !dma_if.rlast)
        $error("Read @0x%016h: expected rlast on beat %0d", addr, i);
    end
    @(posedge clk);
    dma_if.rready <= 1'b0;
  endtask

  // =====================================================================
  // Write-then-readback-and-compare helper
  // =====================================================================
  task automatic test_hbm_segment(
    input [63:0]  base_addr,
    input string  label
  );
    logic [DATA_W-1:0] wr_data [0:255];
    logic [DATA_W-1:0] rd_data [0:255];

    $display("[%0t] --- %s: burst write %0d beats to 0x%016h ---",
             $time, label, NUM_BEATS, base_addr);

    // Generate a unique test pattern for each beat
    for (int i = 0; i < NUM_BEATS; i++) begin
      // Mix address + beat index into a repeating pattern across 512 bits
      for (int w = 0; w < DATA_W/32; w++) begin
        wr_data[i][w*32 +: 32] = base_addr[31:0] ^ (i << 16) ^ (w << 8) ^ 32'hDEAD_BEEF;
      end
    end

    axi4_burst_write(base_addr, BURST_LEN, wr_data);
    $display("[%0t]     write complete", $time);

    // Same deterministic barrier as test_hbm_pc, but via the DMA
    // path.  Required for the 31 per-PC DMA segments that follow
    // the direct-port phase because both paths race on the same
    // DRAM cells and the HBM model's BVALID is optimistic.
    dma_wait_commit(base_addr, wr_data[0][31:0]);

    axi4_burst_read(base_addr, BURST_LEN, rd_data);
    $display("[%0t]     read complete, comparing...", $time);

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
  // Direct-HBM-port AXI tasks (256-bit data, 4-bit len, 6-bit ID)
  // =====================================================================

  // Reset every master-driven signal on an HBM port to idle.
  task automatic hbm_port_init(hbm_vif_t vif);
    vif.awid     = '0;  vif.awaddr   = '0;  vif.awlen    = '0;
    vif.awsize   = '0;  vif.awburst  = '0;  vif.awlock   = '0;
    vif.awcache  = '0;  vif.awprot   = '0;  vif.awqos    = '0;
    vif.awregion = '0;  vif.awvalid  = 1'b0;
    vif.wdata    = '0;  vif.wstrb    = '0;  vif.wlast    = 1'b0;
    vif.wvalid   = 1'b0;
    vif.bready   = 1'b0;
    vif.arid     = '0;  vif.araddr   = '0;  vif.arlen    = '0;
    vif.arsize   = '0;  vif.arburst  = '0;  vif.arlock   = '0;
    vif.arcache  = '0;  vif.arprot   = '0;  vif.arqos    = '0;
    vif.arregion = '0;  vif.arvalid  = 1'b0;
    vif.rready   = 1'b0;
  endtask

  task automatic hbm_port_write(
    hbm_vif_t vif,
    input [63:0]            addr,
    input [3:0]             len,           // burst length - 1 (AXI3, 4-bit)
    input [HBM_DATA_W-1:0]  wdata [0:15]
  );
    int timer;

    @(posedge clk);
    vif.awid     <= 6'h0;
    vif.awaddr   <= addr;
    vif.awlen    <= len;
    vif.awsize   <= AXSIZE_32B;
    vif.awburst  <= BURST_INCR;
    vif.awlock   <= 1'b0;
    vif.awcache  <= 4'b0011;
    vif.awprot   <= 3'b0;
    vif.awqos    <= 4'h0;
    vif.awregion <= 4'h0;
    vif.awvalid  <= 1'b1;

    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: awready on hbm port @0x%016h", addr);
        vif.awvalid <= 1'b0;
        return;
      end
    end while (!vif.awready);
    vif.awvalid <= 1'b0;

    for (int i = 0; i <= int'(len); i++) begin
      vif.wdata  <= wdata[i];
      vif.wstrb  <= {HBM_STRB_W{1'b1}};
      vif.wlast  <= (i == int'(len));
      vif.wvalid <= 1'b1;
      timer = 0;
      do begin
        @(posedge clk);
        timer++;
        if (timer > TIMEOUT_CYCLES) begin
          $error("TIMEOUT: wready on hbm port beat %0d @0x%016h", i, addr);
          vif.wvalid <= 1'b0;
          return;
        end
      end while (!vif.wready);
    end
    vif.wvalid <= 1'b0;
    vif.wlast  <= 1'b0;

    vif.bready <= 1'b1;
    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: bvalid on hbm port @0x%016h", addr);
        vif.bready <= 1'b0;
        return;
      end
    end while (!vif.bvalid);
    if (vif.bresp != 2'b00)
      $error("hbm port write @0x%016h returned bresp=%0b", addr, vif.bresp);
    @(posedge clk);
    vif.bready <= 1'b0;
  endtask

  task automatic hbm_port_read(
    hbm_vif_t vif,
    input [63:0]            addr,
    input [3:0]             len,
    output [HBM_DATA_W-1:0] rdata [0:15]
  );
    int timer;

    @(posedge clk);
    vif.arid     <= 6'h0;
    vif.araddr   <= addr;
    vif.arlen    <= len;
    vif.arsize   <= AXSIZE_32B;
    vif.arburst  <= BURST_INCR;
    vif.arlock   <= 1'b0;
    vif.arcache  <= 4'b0011;
    vif.arprot   <= 3'b0;
    vif.arqos    <= 4'h0;
    vif.arregion <= 4'h0;
    vif.arvalid  <= 1'b1;

    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: arready on hbm port @0x%016h", addr);
        vif.arvalid <= 1'b0;
        return;
      end
    end while (!vif.arready);
    vif.arvalid <= 1'b0;

    vif.rready <= 1'b1;
    for (int i = 0; i <= int'(len); i++) begin
      timer = 0;
      do begin
        @(posedge clk);
        timer++;
        if (timer > TIMEOUT_CYCLES) begin
          $error("TIMEOUT: rvalid on hbm port beat %0d @0x%016h", i, addr);
          vif.rready <= 1'b0;
          return;
        end
      end while (!vif.rvalid);
      rdata[i] = vif.rdata;
      if (vif.rresp != 2'b00)
        $error("hbm port read @0x%016h beat %0d rresp=%0b", addr, i, vif.rresp);
      if (i == int'(len) && !vif.rlast)
        $error("hbm port read @0x%016h: expected rlast on beat %0d", addr, i);
    end
    @(posedge clk);
    vif.rready <= 1'b0;
  endtask

  // Max poll attempts for the post-write "wait for commit" helpers
  // below.  One attempt = (a few-cycle idle gap) + one single-beat
  // read handshake.  The gap is important: the HBM behavioural
  // model appears to hold write commits until the port has idle
  // time, so a tight read-poll-loop can starve the write and
  // deadlock the convergence.  With a 32-cycle gap per attempt,
  // HBM_COMMIT_POLL_MAX = 200 gives ~6 400 cycles of wall-time
  // headroom, which comfortably covers the slowest commit path
  // observed so far (~500 cycles for DMA-side cross-port writes).
  localparam int  HBM_COMMIT_POLL_MAX    = 200;
  localparam int  HBM_COMMIT_POLL_GAP    = 32;

  // Poll-read a single beat on an HBM direct port and return only
  // when the bottom 32 bits of the read match `expected_low`.  This
  // replaces the old `repeat (N) @(posedge clk)` bounded wait with
  // a deterministic barrier: once a read observes the sentinel, the
  // write is guaranteed to be visible on this port's read path and
  // any subsequent read of the same address will also see it.
  task automatic hbm_port_wait_commit(
    hbm_vif_t       vif,
    input [63:0]    addr,
    input [31:0]    expected_low
  );
    logic [HBM_DATA_W-1:0] probe [0:15];
    for (int attempt = 0; attempt < HBM_COMMIT_POLL_MAX; attempt++) begin
      repeat (HBM_COMMIT_POLL_GAP) @(posedge clk);
      hbm_port_read(vif, addr, 4'd0, probe);
      if (probe[0][31:0] === expected_low)
        return;
    end
    $fatal(1, "hbm_port_wait_commit: addr=0x%016h never converged on 0x%08h (last=0x%08h)",
           addr, expected_low, probe[0][31:0]);
  endtask

  // Same idea as above, but via the DMA path (port 00) using the
  // existing 512-bit axi4 tasks.  Used by test_hbm_segment to
  // self-synchronise the DMA write path against the HBM model's
  // optimistic BVALID.
  task automatic dma_wait_commit(
    input [63:0]    addr,
    input [31:0]    expected_low
  );
    logic [DATA_W-1:0] probe [0:255];
    for (int attempt = 0; attempt < HBM_COMMIT_POLL_MAX; attempt++) begin
      repeat (HBM_COMMIT_POLL_GAP) @(posedge clk);
      axi4_burst_read(addr, 8'd0, probe);
      if (probe[0][31:0] === expected_low)
        return;
    end
    $fatal(1, "dma_wait_commit: addr=0x%016h never converged on 0x%08h (last=0x%08h)",
           addr, expected_low, probe[0][31:0]);
  endtask

  // Write-then-readback-and-compare on a single HBM pseudo-channel.
  // Each port targets its *own* PC's address region (rather than all
  // collapsing onto PC 0 at low offsets through the HBM internal
  // switch), so every pseudo-channel's controller is actually
  // exercised and there's no back-to-back contention on any one PC.
  // The offset of 16 MB inside each PC keeps the direct-port writes
  // clear of the DMA-path tests, which sit at each PC's base
  // address (0 MB offset).
  task automatic test_hbm_pc(
    input int     port_num,   // 1..31
    hbm_vif_t     vif
  );
    logic [HBM_DATA_W-1:0] wr_data [0:15];
    logic [HBM_DATA_W-1:0] rd_data [0:15];
    logic [63:0] base_addr;
    string       label;

    // PC N base = N * 256 MB, + 16 MB offset inside that PC
    base_addr = (port_num * 64'h1000_0000) + 64'h100_0000;
    label = $sformatf("HBM PC %02d", port_num);

    $display("[%0t] --- %s: burst write 16 beats to 0x%016h ---",
             $time, label, base_addr);

    for (int i = 0; i < 16; i++) begin
      for (int w = 0; w < HBM_DATA_W/32; w++) begin
        wr_data[i][w*32 +: 32] =
            32'hCA00_0000 | (port_num << 20) | (i << 12) | (w << 4);
      end
    end

    hbm_port_write(vif, base_addr, 4'd15, wr_data);
    // Wait until the model's DRAM has actually absorbed the first
    // beat before issuing the full-burst readback.  The HBM model's
    // BVALID is optimistic; this poll turns "wait long enough"
    // into "wait until a read observes the write".
    hbm_port_wait_commit(vif, base_addr, wr_data[0][31:0]);
    hbm_port_read (vif, base_addr, 4'd15, rd_data);

    for (int i = 0; i < 16; i++) begin
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
    // Initialise DMA interface master signals
    dma_if.awid     = '0;  dma_if.awaddr   = '0;  dma_if.awlen    = '0;
    dma_if.awsize   = '0;  dma_if.awburst  = '0;  dma_if.awlock   = '0;
    dma_if.awcache  = '0;  dma_if.awprot   = '0;  dma_if.awqos    = '0;
    dma_if.awregion = '0;  dma_if.awvalid  = 1'b0;
    dma_if.wdata    = '0;  dma_if.wstrb    = '0;  dma_if.wlast    = 1'b0;
    dma_if.wvalid   = 1'b0;
    dma_if.bready   = 1'b0;
    dma_if.arid     = '0;  dma_if.araddr   = '0;  dma_if.arlen    = '0;
    dma_if.arsize   = '0;  dma_if.arburst  = '0;  dma_if.arlock   = '0;
    dma_if.arcache  = '0;  dma_if.arprot   = '0;  dma_if.arqos    = '0;
    dma_if.arregion = '0;  dma_if.arvalid  = 1'b0;
    dma_if.rready   = 1'b0;

    // Bind virtual interface handles for the 31 direct HBM ports.
    hbm_vif[1]  = hbm_01;  hbm_vif[2]  = hbm_02;  hbm_vif[3]  = hbm_03;
    hbm_vif[4]  = hbm_04;  hbm_vif[5]  = hbm_05;  hbm_vif[6]  = hbm_06;
    hbm_vif[7]  = hbm_07;  hbm_vif[8]  = hbm_08;  hbm_vif[9]  = hbm_09;
    hbm_vif[10] = hbm_10;  hbm_vif[11] = hbm_11;  hbm_vif[12] = hbm_12;
    hbm_vif[13] = hbm_13;  hbm_vif[14] = hbm_14;  hbm_vif[15] = hbm_15;
    hbm_vif[16] = hbm_16;  hbm_vif[17] = hbm_17;  hbm_vif[18] = hbm_18;
    hbm_vif[19] = hbm_19;  hbm_vif[20] = hbm_20;  hbm_vif[21] = hbm_21;
    hbm_vif[22] = hbm_22;  hbm_vif[23] = hbm_23;  hbm_vif[24] = hbm_24;
    hbm_vif[25] = hbm_25;  hbm_vif[26] = hbm_26;  hbm_vif[27] = hbm_27;
    hbm_vif[28] = hbm_28;  hbm_vif[29] = hbm_29;  hbm_vif[30] = hbm_30;
    hbm_vif[31] = hbm_31;

    // Initialise every direct HBM port's master signals to idle
    // before reset is released.
    for (int i = 1; i <= 31; i++) hbm_port_init(hbm_vif[i]);

    // ---- Reset ----
    $display("[%0t] Asserting reset for %0d cycles", $time, RESET_CYCLES);
    rstn = 1'b0;
    repeat (RESET_CYCLES) @(posedge clk);
    rstn = 1'b1;
    $display("[%0t] Reset deasserted, waiting for HBM init (%0d cycles, ~%0d us)...",
             $time, INIT_WAIT_CYCLES,
             int'(INIT_WAIT_CYCLES * CLK_PERIOD_NS / 1000.0));

    // Fixed wait covering the HBM behavioural model's ~82 us
    // per-channel Resetb de-assert plus per-port DFI init.  We
    // can't use apb_complete_0/1 via hierarchical reference
    // because those signals rise before the channels are
    // actually ready.
    repeat (INIT_WAIT_CYCLES) @(posedge clk);
    $display("[%0t] Init wait complete, axi_aresetn=%b — starting tests",
             $time, dut_axi_aresetn);

    // ---- DMA-path full-address-range coverage ----
    // Stride through the 8 GB HBM address space at 256 MB
    // boundaries, one test per pseudo-channel.  Every pseudo-
    // channel is reached via the DMA path's port 00 + HBM
    // internal switch (USER_SWITCH_ENABLE) — this is the actual
    // host → HBM data path that XDMA uses at runtime, and it
    // proves the full address range is writeable/readable from
    // the host's perspective.
    $display("");
    $display("---- DMA-path full-address-range coverage (32 PCs) ----");
    for (int pc = 0; pc < 32; pc++) begin
      test_hbm_segment(pc * 64'h1000_0000,
                       $sformatf("DMA PC %02d", pc));
    end

    // ---- Direct HBM port tests (01..31) ----
    // Exercise each of the 31 direct HBM slave ports
    // independently — every pseudo-channel gets a 16-beat
    // write/read at its own 4 KB-aligned address.  This proves
    // each accelerator-side port is usable for independent
    // HBM traffic at simulation time, which is required for
    // later sims that add a PR accelerator behind the PR
    // boundary.
    $display("");
    $display("---- Direct HBM port tests (01..31) ----");
    for (int pc = 1; pc <= 31; pc++) begin
      test_hbm_pc(pc, hbm_vif[pc]);
    end

    // ---- Summary ----
    $display("");
    $display("========================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED (%0d beat comparisons)", pass_count);
    else
      $display(" %0d FAILURES out of %0d beat comparisons", fail_count, pass_count + fail_count);
    $display("========================================");
    $finish;
  end

  // Global timeout — catch infinite hangs
  initial begin
    #(CLK_PERIOD_NS * 1_000_000); // 1M cycles
    $error("GLOBAL TIMEOUT — simulation did not finish in 1M cycles");
    $finish;
  end

endmodule

`undef TB_HBM_SLAVE_TIEOFF
`undef TB_MASTER_TIEOFF
