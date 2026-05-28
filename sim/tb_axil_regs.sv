// *************************************************************************
//
// Testbench: static-region AXI-Lite register map + PR control plane.
//
// Instantiates `alveo_u50_static` in SIMULATION mode and drives the
// `sim_axil` AXI-Lite port.  The `axil_host_switch`'s M01 routes BAR
// offsets 0x0000_0000..0x0000_0FFF to the static region's
// `axil_reg_map`, which holds four 32-bit registers:
//
//   Reg 0 (offset 0x0) — control register
//     bit 0   = decouple   (drives the static region's `decouple` out)
//     bit 1   = dyn_reset  (forces `dyn_aresetn` low when set)
//     31:2    = reserved
//   Reg 1 (offset 0x4) — scratch / loopback
//   Reg 2 (offset 0x8) — scratch / loopback
//   Reg 3 (offset 0xC) — scratch / loopback
//
// Tests:
//   - Scratch reg write / read loopback for regs 1..3.
//   - Reg 0 bit 0 (decouple) write → observe `dut.decouple`.
//   - Reg 0 bit 1 (dyn_reset) write → observe `dut.dyn_aresetn`.
//   - Writing both bits and then clearing them, to prove the static
//     control path is edge-clean.
//
// `sim_axi_dma` is tied off; the direct HBM ports are tied off.
// This TB keeps its runtime small — the HBM self-init is the only
// thing that takes real sim time, and we just wait past it.
//
// *************************************************************************
`timescale 1ns/1ps

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

module tb_axil_regs;

  // =====================================================================
  // Parameters
  // =====================================================================
  localparam real CLK_PERIOD_NS     = 4.0;     // 250 MHz
  localparam real HBM_REF_PERIOD_NS = 10.0;    // 100 MHz
  localparam int  RESET_CYCLES      = 20;
  localparam int  INIT_WAIT_CYCLES  = 30000;   // ~120 us — HBM model init
  localparam int  TIMEOUT_CYCLES    = 1000;

  // BAR offsets for the 4-register static map (host BAR offsets 0x0..0xC).
  localparam [31:0] REG0_CTRL    = 32'h0000_0000;
  localparam [31:0] REG1_SCRATCH = 32'h0000_0004;
  localparam [31:0] REG2_SCRATCH = 32'h0000_0008;
  localparam [31:0] REG3_SCRATCH = 32'h0000_000C;

  localparam [31:0] DECOUPLE_BIT  = 32'h0000_0001;  // reg 0 bit 0
  localparam [31:0] DYN_RESET_BIT = 32'h0000_0002;  // reg 0 bit 1

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
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) axil_if (.aclk(clk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4)) dma_if  (.aclk(clk), .aresetn(rstn));

  // Dynamic-region master output (needs slave tie-off)
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) dyn_axil (.aclk(clk), .aresetn(rstn));

  // HBM ports 01-31 + mux (all tied off — this TB doesn't use HBM)
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
    .dyn_aresetn          (dut_dyn_aresetn),

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
  `TB_MASTER_TIEOFF(dyn_axil);

  `TB_HBM_SLAVE_TIEOFF(hbm_01);
  `TB_HBM_SLAVE_TIEOFF(hbm_02);
  `TB_HBM_SLAVE_TIEOFF(hbm_03);
  `TB_HBM_SLAVE_TIEOFF(hbm_04);
  `TB_HBM_SLAVE_TIEOFF(hbm_05);
  `TB_HBM_SLAVE_TIEOFF(hbm_06);
  `TB_HBM_SLAVE_TIEOFF(hbm_07);
  `TB_HBM_SLAVE_TIEOFF(hbm_08);
  `TB_HBM_SLAVE_TIEOFF(hbm_09);
  `TB_HBM_SLAVE_TIEOFF(hbm_10);
  `TB_HBM_SLAVE_TIEOFF(hbm_11);
  `TB_HBM_SLAVE_TIEOFF(hbm_12);
  `TB_HBM_SLAVE_TIEOFF(hbm_13);
  `TB_HBM_SLAVE_TIEOFF(hbm_14);
  `TB_HBM_SLAVE_TIEOFF(hbm_15);
  `TB_HBM_SLAVE_TIEOFF(hbm_16);
  `TB_HBM_SLAVE_TIEOFF(hbm_17);
  `TB_HBM_SLAVE_TIEOFF(hbm_18);
  `TB_HBM_SLAVE_TIEOFF(hbm_19);
  `TB_HBM_SLAVE_TIEOFF(hbm_20);
  `TB_HBM_SLAVE_TIEOFF(hbm_21);
  `TB_HBM_SLAVE_TIEOFF(hbm_22);
  `TB_HBM_SLAVE_TIEOFF(hbm_23);
  `TB_HBM_SLAVE_TIEOFF(hbm_24);
  `TB_HBM_SLAVE_TIEOFF(hbm_25);
  `TB_HBM_SLAVE_TIEOFF(hbm_26);
  `TB_HBM_SLAVE_TIEOFF(hbm_27);
  `TB_HBM_SLAVE_TIEOFF(hbm_28);
  `TB_HBM_SLAVE_TIEOFF(hbm_29);
  `TB_HBM_SLAVE_TIEOFF(hbm_30);
  `TB_HBM_SLAVE_TIEOFF(hbm_31);
  `TB_HBM_SLAVE_TIEOFF(hbm_mux);

  // DMA interface — not used in this TB
  assign dma_if.awid     = '0;  assign dma_if.awaddr   = '0;
  assign dma_if.awlen    = '0;  assign dma_if.awsize   = '0;
  assign dma_if.awburst  = '0;  assign dma_if.awlock   = '0;
  assign dma_if.awcache  = '0;  assign dma_if.awprot   = '0;
  assign dma_if.awqos    = '0;  assign dma_if.awregion = '0;
  assign dma_if.awvalid  = 1'b0;
  assign dma_if.wdata    = '0;  assign dma_if.wstrb    = '0;
  assign dma_if.wlast    = 1'b0; assign dma_if.wvalid  = 1'b0;
  assign dma_if.bready   = 1'b1;
  assign dma_if.arid     = '0;  assign dma_if.araddr   = '0;
  assign dma_if.arlen    = '0;  assign dma_if.arsize   = '0;
  assign dma_if.arburst  = '0;  assign dma_if.arlock   = '0;
  assign dma_if.arcache  = '0;  assign dma_if.arprot   = '0;
  assign dma_if.arqos    = '0;  assign dma_if.arregion = '0;
  assign dma_if.arvalid  = 1'b0; assign dma_if.rready  = 1'b1;

  // =====================================================================
  // Scoreboard
  // =====================================================================
  int pass_count = 0;
  int fail_count = 0;

  // =====================================================================
  // AXI-Lite single-beat write task
  // =====================================================================
  task automatic axil_write(input [31:0] addr, input [31:0] data);
    int timer;

    // Drive AW and W concurrently
    @(posedge clk);
    axil_if.awid     <= 1'b0;
    axil_if.awaddr   <= addr;
    axil_if.awlen    <= 8'h00;
    axil_if.awsize   <= 3'b010;  // 4 bytes
    axil_if.awburst  <= 2'b01;   // INCR
    axil_if.awlock   <= 1'b0;
    axil_if.awcache  <= 4'b0011;
    axil_if.awprot   <= 3'b0;
    axil_if.awqos    <= 4'h0;
    axil_if.awregion <= 4'h0;
    axil_if.awvalid  <= 1'b1;
    axil_if.wdata    <= data;
    axil_if.wstrb    <= 4'hF;
    axil_if.wlast    <= 1'b1;
    axil_if.wvalid   <= 1'b1;
    axil_if.bready   <= 1'b1;

    // Hold until both handshakes complete
    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: awready on axil write @0x%08h", addr);
        axil_if.awvalid <= 1'b0;
        axil_if.wvalid  <= 1'b0;
        return;
      end
    end while (!axil_if.awready);
    axil_if.awvalid <= 1'b0;

    timer = 0;
    while (!axil_if.wready) begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: wready on axil write @0x%08h", addr);
        axil_if.wvalid <= 1'b0;
        return;
      end
    end
    axil_if.wvalid <= 1'b0;
    axil_if.wlast  <= 1'b0;

    // Wait bvalid
    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: bvalid on axil write @0x%08h", addr);
        axil_if.bready <= 1'b0;
        return;
      end
    end while (!axil_if.bvalid);
    if (axil_if.bresp != 2'b00)
      $error("axil write @0x%08h returned bresp=%0b", addr, axil_if.bresp);
    @(posedge clk);
    axil_if.bready <= 1'b0;
  endtask

  // =====================================================================
  // AXI-Lite single-beat read task
  // =====================================================================
  task automatic axil_read(input [31:0] addr, output [31:0] data);
    int timer;

    @(posedge clk);
    axil_if.arid     <= 1'b0;
    axil_if.araddr   <= addr;
    axil_if.arlen    <= 8'h00;
    axil_if.arsize   <= 3'b010;
    axil_if.arburst  <= 2'b01;
    axil_if.arlock   <= 1'b0;
    axil_if.arcache  <= 4'b0011;
    axil_if.arprot   <= 3'b0;
    axil_if.arqos    <= 4'h0;
    axil_if.arregion <= 4'h0;
    axil_if.arvalid  <= 1'b1;
    axil_if.rready   <= 1'b1;

    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: arready on axil read @0x%08h", addr);
        axil_if.arvalid <= 1'b0;
        data = 32'hXXXXXXXX;
        return;
      end
    end while (!axil_if.arready);
    axil_if.arvalid <= 1'b0;

    timer = 0;
    do begin
      @(posedge clk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("TIMEOUT: rvalid on axil read @0x%08h", addr);
        axil_if.rready <= 1'b0;
        data = 32'hXXXXXXXX;
        return;
      end
    end while (!axil_if.rvalid);
    data = axil_if.rdata;
    if (axil_if.rresp != 2'b00)
      $error("axil read @0x%08h returned rresp=%0b", addr, axil_if.rresp);
    @(posedge clk);
    axil_if.rready <= 1'b0;
  endtask

  // =====================================================================
  // Check helpers
  // =====================================================================
  task automatic check_eq32(input string label,
                            input [31:0] got,
                            input [31:0] expected);
    if (got === expected) begin
      pass_count++;
      $display("[%0t]   PASS: %s got=0x%08h", $time, label, got);
    end else begin
      fail_count++;
      $error("  FAIL: %s got=0x%08h expected=0x%08h",
             label, got, expected);
    end
  endtask

  task automatic check_eq1(input string label,
                           input logic got,
                           input logic expected);
    if (got === expected) begin
      pass_count++;
      $display("[%0t]   PASS: %s got=%b", $time, label, got);
    end else begin
      fail_count++;
      $error("  FAIL: %s got=%b expected=%b",
             label, got, expected);
    end
  endtask

  // =====================================================================
  // Test sequences
  // =====================================================================
  task automatic test_scratch_regs;
    logic [31:0] rd;
    $display("");
    $display("---- Scratch register loopback (reg 1..3) ----");
    axil_write(REG1_SCRATCH, 32'hDEAD_BEEF);
    axil_write(REG2_SCRATCH, 32'hCAFE_F00D);
    axil_write(REG3_SCRATCH, 32'h1234_5678);
    axil_read (REG1_SCRATCH, rd); check_eq32("reg1 loopback", rd, 32'hDEAD_BEEF);
    axil_read (REG2_SCRATCH, rd); check_eq32("reg2 loopback", rd, 32'hCAFE_F00D);
    axil_read (REG3_SCRATCH, rd); check_eq32("reg3 loopback", rd, 32'h1234_5678);

    // Overwrite and verify
    axil_write(REG1_SCRATCH, 32'hA5A5_A5A5);
    axil_read (REG1_SCRATCH, rd); check_eq32("reg1 overwrite", rd, 32'hA5A5_A5A5);

    // Byte-strobe test: write 0xFFFF_FFFF then a byte-masked write
    axil_write(REG2_SCRATCH, 32'hFFFF_FFFF);
    // Can't easily test partial wstrb with the full-task helper — leave
    // full-word loopback as the basic coverage.
  endtask

  task automatic test_decouple;
    logic [31:0] rd;
    $display("");
    $display("---- PR decouple bit (reg 0 bit 0) ----");

    // Reset state
    check_eq1("decouple at reset", dut_decouple, 1'b0);

    // Assert decouple
    axil_write(REG0_CTRL, DECOUPLE_BIT);
    repeat (2) @(posedge clk);   // allow output to propagate
    check_eq1("decouple after set", dut_decouple, 1'b1);

    // Read-back the control register
    axil_read(REG0_CTRL, rd);
    check_eq32("reg0 after decouple set", rd, DECOUPLE_BIT);

    // Clear decouple
    axil_write(REG0_CTRL, 32'h0);
    repeat (2) @(posedge clk);
    check_eq1("decouple after clear", dut_decouple, 1'b0);
    axil_read(REG0_CTRL, rd);
    check_eq32("reg0 after decouple clear", rd, 32'h0);
  endtask

  task automatic test_dyn_reset;
    logic [31:0] rd;
    $display("");
    $display("---- PR dynamic-region reset bit (reg 0 bit 1) ----");

    // Reset state — dyn_aresetn should track periph reset (high after init)
    check_eq1("dyn_aresetn at rest", dut_dyn_aresetn, 1'b1);

    // Assert dyn_reset
    axil_write(REG0_CTRL, DYN_RESET_BIT);
    repeat (2) @(posedge clk);
    check_eq1("dyn_aresetn after set", dut_dyn_aresetn, 1'b0);
    axil_read(REG0_CTRL, rd);
    check_eq32("reg0 after dyn_reset set", rd, DYN_RESET_BIT);

    // Clear dyn_reset
    axil_write(REG0_CTRL, 32'h0);
    repeat (2) @(posedge clk);
    check_eq1("dyn_aresetn after clear", dut_dyn_aresetn, 1'b1);
  endtask

  task automatic test_decouple_and_dyn_reset;
    $display("");
    $display("---- decouple + dyn_reset set together ----");
    axil_write(REG0_CTRL, DECOUPLE_BIT | DYN_RESET_BIT);
    repeat (2) @(posedge clk);
    check_eq1("decouple set",    dut_decouple,    1'b1);
    check_eq1("dyn_aresetn low", dut_dyn_aresetn, 1'b0);

    // Clear both
    axil_write(REG0_CTRL, 32'h0);
    repeat (2) @(posedge clk);
    check_eq1("decouple cleared", dut_decouple,    1'b0);
    check_eq1("dyn_aresetn high", dut_dyn_aresetn, 1'b1);
  endtask

  // =====================================================================
  // Main
  // =====================================================================
  initial begin
    // Initialise AXI-Lite master signals
    axil_if.awid     = '0;  axil_if.awaddr   = '0;
    axil_if.awlen    = '0;  axil_if.awsize   = '0;
    axil_if.awburst  = '0;  axil_if.awlock   = '0;
    axil_if.awcache  = '0;  axil_if.awprot   = '0;
    axil_if.awqos    = '0;  axil_if.awregion = '0;
    axil_if.awvalid  = 1'b0;
    axil_if.wdata    = '0;  axil_if.wstrb    = '0;
    axil_if.wlast    = 1'b0; axil_if.wvalid  = 1'b0;
    axil_if.bready   = 1'b0;
    axil_if.arid     = '0;  axil_if.araddr   = '0;
    axil_if.arlen    = '0;  axil_if.arsize   = '0;
    axil_if.arburst  = '0;  axil_if.arlock   = '0;
    axil_if.arcache  = '0;  axil_if.arprot   = '0;
    axil_if.arqos    = '0;  axil_if.arregion = '0;
    axil_if.arvalid  = 1'b0; axil_if.rready  = 1'b0;

    // ---- Reset ----
    $display("[%0t] Asserting reset for %0d cycles", $time, RESET_CYCLES);
    rstn = 1'b0;
    repeat (RESET_CYCLES) @(posedge clk);
    rstn = 1'b1;
    $display("[%0t] Reset deasserted, waiting for HBM init (%0d cycles)...",
             $time, INIT_WAIT_CYCLES);
    repeat (INIT_WAIT_CYCLES) @(posedge clk);
    $display("[%0t] Init wait complete, axi_aresetn=%b — starting tests",
             $time, dut_axi_aresetn);

    // ---- Tests ----
    test_scratch_regs();
    test_decouple();
    test_dyn_reset();
    test_decouple_and_dyn_reset();

    // ---- Summary ----
    $display("");
    $display("========================================");
    if (fail_count == 0)
      $display(" ALL TESTS PASSED (%0d checks)", pass_count);
    else
      $display(" %0d FAILURES out of %0d checks", fail_count, pass_count + fail_count);
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
