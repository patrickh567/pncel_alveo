// *************************************************************************
//
// Testbench: pncel-alveo aurora packet bridge.
//
// Exercises the host-side `axi_aurora_bridge_inv` (in pncel_dynamic_region)
// by initiating AXI4-Full + AXI-Lite transactions from the host side (via
// pncel_top's SIMULATION-mode sim_axil / sim_axi_dma ports), observing the
// resulting outbound aurora packets on the bridge's TX wires, and feeding
// matching response packets back on the bridge's RX wires to complete the
// transaction.  This mirrors what the zcu102 far-end would do in hardware:
// receive request packets, drive its local AXI fabric, and ship B/R
// responses back.
//
// The packet format under test is the exact wire protocol used by the
// zcu102 design's `axi_to_aurora` / `axi_lite_to_aurora` / `axi_packetizer`
// pair, with ADDR_W = 64, DATA_W = 128, ID_W = 4 (matching the bridge
// instantiation in pncel_dynamic_region.sv).
//
// Packet layout (256-bit flits; opcode at [7:0] when present):
//
//   OP_AW = 0x10  Write header (data wire, chunked).  Single flit for AXI-Lite
//                 or short Full writes; otherwise hdr + cont flits.
//     Header [255:0] (LSB -> MSB):
//       [7:0]     OP_AW (0x10)
//       [11:8]    id           (ID_W bits)
//       [75:12]   addr         (ADDR_W bits)
//       [83:76]   len          (awlen, 8 bits)
//       [86:84]   size         (awsize, 3 bits)
//       [88:87]   burst        (2 bits)
//       [92:89]   cache        (4 bits)
//       [95:93]   prot         (3 bits)
//       [96]      lite         (1 bit, 1 = AXI-Lite request)
//       [103:97]  pad to byte  (7 bits, = 0)
//       [hdr_data_start +: HDR_DATA_BYTES*8]  first 19 W data bytes
//     tkeep: low 13 metadata bytes always 1; next STRB_W bits = wstrb;
//            trailing 3 bytes = 0.
//     tlast = 1 on the FINAL flit of the burst (single-flit if all data
//     fits in the header slot).
//
//   OP_AR = 0x13  Read request (user-K wire, single flit).  Same layout
//                 as OP_AW header up through bit [96] (lite).
//
//   OP_B  = 0x12  Full write response (user-K, single flit):
//     [7:0]   OP_B; [11:8] bid; [13:12] bresp.
//
//   OP_B_LITE = 0x16  Lite write response (user-K, single flit):
//     [7:0]   OP_B_LITE; [9:8] bresp.
//
//   OP_R_LITE = 0x17  Lite read response (user-K, single flit):
//     [7:0]   OP_R_LITE; [9:8] rresp; [9+DATA_W:10] rdata.
//
//   OP_R  = 0x14  Full read response (data wire, chunked):
//     Header [7:0] OP_R; [11:8] rid; [13:12] rresp; [255:14] up to
//       R_HDR_CHUNK_CAP = 7 chunks of rdata (32 bits each).
//     Cont flits: 256 bits = R_CONT_CHUNK_CAP = 8 chunks each, no opcode.
//     tlast = 1 on FINAL flit; receiver re-assembles rdata beats from
//     CHUNKS_PER_BEAT = DATA_W/32 = 4 chunks each.
//
// Test list:
//   1. AXI-Lite write : sim_axil AW+W -> OP_AW (lite=1) observed -> B-Lite
//                       response injected -> sim_axil.bvalid checked.
//   2. AXI-Lite read  : sim_axil AR -> OP_AR (lite=1) observed -> R-Lite
//                       response injected -> sim_axil.rdata checked.
//   3. AXI4 write     : sim_axi_dma AW+W (1 beat, awsize=4 = 16 bytes)
//                       -> single-flit OP_AW (lite=0) on tx_data ->
//                       B response injected on userk_rx -> sim_axi_dma.bvalid.
//   4. AXI4 read      : sim_axi_dma AR (1 beat, arsize=4) -> OP_AR
//                       (lite=0) observed -> chunked R response with 1
//                       beat of rdata injected on rx_data -> sim_axi_dma.rdata.
//
// Each test is self-contained and uses a deterministic data pattern so
// any mismatch identifies the failing test + field.
//
// *************************************************************************
`timescale 1ns/1ps

module tb_pncel_aurora;

  // =====================================================================
  // Parameters
  // =====================================================================
  localparam real CLK_PERIOD_NS        = 4.0;    // 250 MHz aclk
  localparam real AURORA_PERIOD_NS     = 6.4;    // ~156.25 MHz aurora_user_clk
  localparam int  RESET_CYCLES         = 20;
  localparam int  AURORA_UP_CYCLES     = 50;
  // Bridge needs reset to propagate through axi_clock_converter +
  // axi_lite_clock_converter CDC after channel_up.  Give it ~200 aclks.
  localparam int  POST_CHANNEL_SETTLE  = 200;
  localparam int  TIMEOUT_CYCLES       = 20000;
  // How long to wait for a tx packet to appear after issuing an AXI
  // transaction (covers CDC + bridge serialisation latency).
  localparam int  TX_WAIT_CYCLES       = 5000;
  // HBM behavioural model takes ~82us after reset to bring its per-
  // channel Resetb up.  30000 aclks (~120us) covers that plus per-port
  // DFI settle, same as the HBM TB.  Only needed before the inbound
  // HBM tests (5/6) which actually touch the HBM model; tests 1-4
  // only exercise the bridge in isolation.
  localparam int  HBM_INIT_WAIT_CYCLES = 30000;

  // Debug-print enable.  Set with +debug at simv time.  Declared up
  // here because the test bodies reference it before the deep probes
  // (which used to host the declaration) come into scope.
  wire dbg_enable;
  assign dbg_enable = $test$plusargs("debug") != 0;

  // Bridge geometry (matches pncel_dynamic_region.sv:720)
  localparam int  ADDR_W = 64;
  localparam int  DATA_W = 128;
  localparam int  ID_W   = 4;
  localparam int  STRB_W = DATA_W / 8;

  // Packet field offsets in OP_AW / OP_AR header
  localparam int  P_OP_LSB     = 0;
  localparam int  P_ID_LSB     = 8;
  localparam int  P_ADDR_LSB   = P_ID_LSB   + ID_W;       // 12
  localparam int  P_LEN_LSB    = P_ADDR_LSB + ADDR_W;     // 76
  localparam int  P_SIZE_LSB   = P_LEN_LSB  + 8;          // 84
  localparam int  P_BURST_LSB  = P_SIZE_LSB + 3;          // 87
  localparam int  P_CACHE_LSB  = P_BURST_LSB + 2;         // 89
  localparam int  P_PROT_LSB   = P_CACHE_LSB + 4;         // 93
  localparam int  P_LITE_LSB   = P_PROT_LSB  + 3;         // 96
  localparam int  HDR_AW_W     = P_LITE_LSB  + 1;         // 97
  localparam int  HDR_DATA_OFF = ((HDR_AW_W + 7) / 8) * 8; // 104

  // Opcodes
  localparam logic [7:0] OP_AW       = 8'h10;
  localparam logic [7:0] OP_B        = 8'h12;
  localparam logic [7:0] OP_AR       = 8'h13;
  localparam logic [7:0] OP_R        = 8'h14;
  localparam logic [7:0] OP_B_LITE   = 8'h16;
  localparam logic [7:0] OP_R_LITE   = 8'h17;

  // R-Full geometry (matches axi_packetizer.sv:97-103)
  localparam int  R_RESP_W         = 2;
  localparam int  R_HDR_META_W     = 8 + ID_W + R_RESP_W;        // 14
  localparam int  R_CHUNK_W        = 32;
  localparam int  R_HDR_CHUNK_CAP  = (256 - R_HDR_META_W) / R_CHUNK_W;  // 7
  localparam int  R_CONT_CHUNK_CAP = 256 / R_CHUNK_W;             // 8
  localparam int  CHUNKS_PER_BEAT  = DATA_W / R_CHUNK_W;          // 4

  // Address windows
  // axil_host_switch.M02 = 0x0008_0000..0x0009_FFFF -> bridge s_lite
  // (re-packed for the 1 MB AXI-Lite BAR).
  localparam logic [31:0] AXIL_BRIDGE_BASE = 32'h0008_0000;
  // axi_dma_switch.M00   = 0x0_0000_0000..0x1_FFFF_FFFF -> bridge s_full
  localparam logic [63:0] AXI_BRIDGE_BASE  = 64'h0000_0000_0000_0000;

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
  axi_if #(.ADDR_W(32), .DATA_W(32),  .ID_W(1)) sim_axil    (.aclk(aclk), .aresetn(rstn));
  axi_if #(.ADDR_W(64), .DATA_W(512), .ID_W(4)) sim_axi_dma (.aclk(aclk), .aresetn(rstn));

  // Aurora TX (driven by DUT, observed by TB)
  wire [255:0] sim_aurora_tx_tdata;
  wire  [31:0] sim_aurora_tx_tkeep;
  wire         sim_aurora_tx_tlast;
  wire         sim_aurora_tx_tvalid;
  logic        sim_aurora_tx_tready = 1'b1;       // always ready
  wire [255:0] sim_aurora_userk_tx_tdata;
  wire         sim_aurora_userk_tx_tvalid;
  logic        sim_aurora_userk_tx_tready = 1'b1; // always ready

  // Aurora RX (driven by TB, consumed by DUT)
  logic [255:0] sim_aurora_rx_tdata        = '0;
  logic  [31:0] sim_aurora_rx_tkeep        = '0;
  logic         sim_aurora_rx_tlast        = 1'b0;
  logic         sim_aurora_rx_tvalid       = 1'b0;
  logic [255:0] sim_aurora_userk_rx_tdata  = '0;
  logic         sim_aurora_userk_rx_tvalid = 1'b0;

  // =====================================================================
  // DUT
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
  // Scoreboard
  // =====================================================================
  int pass_count = 0;
  int fail_count = 0;

  task automatic check(string label, bit cond);
    if (cond) begin
      pass_count++;
      $display("[%0t]   PASS: %s", $time, label);
    end else begin
      fail_count++;
      $error("[%0t]   FAIL: %s", $time, label);
    end
  endtask

  task automatic check_eq(string label, logic [127:0] got, logic [127:0] exp);
    if (got === exp) begin
      pass_count++;
      $display("[%0t]   PASS: %s (0x%0h)", $time, label, got);
    end else begin
      fail_count++;
      $error("[%0t]   FAIL: %s exp=0x%0h got=0x%0h", $time, label, exp, got);
    end
  endtask

  // =====================================================================
  // AXI-Lite write/read tasks (drive sim_axil)
  // =====================================================================
  task automatic axil_write(
    input [31:0] addr,
    input [31:0] data
  );
    int timer;
    @(posedge aclk);
    sim_axil.awaddr  <= addr;
    sim_axil.awprot  <= 3'b0;
    sim_axil.awvalid <= 1'b1;
    sim_axil.wdata   <= data;
    sim_axil.wstrb   <= 4'hF;
    sim_axil.wvalid  <= 1'b1;

    // Wait for both AW and W to be accepted (Lite slave consumes them
    // together).
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axil_write: timeout waiting for aw/wready @0x%08h", addr);
        sim_axil.awvalid <= 1'b0;
        sim_axil.wvalid  <= 1'b0;
        return;
      end
    end while (!(sim_axil.awready && sim_axil.wready));
    sim_axil.awvalid <= 1'b0;
    sim_axil.wvalid  <= 1'b0;

    sim_axil.bready <= 1'b1;
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axil_write: timeout waiting for bvalid @0x%08h", addr);
        sim_axil.bready <= 1'b0;
        return;
      end
    end while (!sim_axil.bvalid);
    if (sim_axil.bresp != 2'b00)
      $error("axil_write @0x%08h bresp=%0b", addr, sim_axil.bresp);
    @(posedge aclk);
    sim_axil.bready <= 1'b0;
  endtask

  task automatic axil_read(
    input  [31:0] addr,
    output [31:0] data
  );
    int timer;
    @(posedge aclk);
    sim_axil.araddr  <= addr;
    sim_axil.arprot  <= 3'b0;
    sim_axil.arvalid <= 1'b1;

    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axil_read: timeout waiting for arready @0x%08h", addr);
        sim_axil.arvalid <= 1'b0;
        return;
      end
    end while (!sim_axil.arready);
    sim_axil.arvalid <= 1'b0;

    sim_axil.rready <= 1'b1;
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axil_read: timeout waiting for rvalid @0x%08h", addr);
        sim_axil.rready <= 1'b0;
        return;
      end
    end while (!sim_axil.rvalid);
    data = sim_axil.rdata;
    if (sim_axil.rresp != 2'b00)
      $error("axil_read @0x%08h rresp=%0b", addr, sim_axil.rresp);
    @(posedge aclk);
    sim_axil.rready <= 1'b0;
  endtask

  // =====================================================================
  // AXI4 single-beat write/read tasks (drive sim_axi_dma).  Use awsize=4
  // (= 16 bytes) so the 512-bit XDMA bus narrows through both dwidth
  // converters into a single 128-bit beat at the bridge slave -- which
  // packs into a single OP_AW header flit (16 W data bytes ≤
  // HDR_DATA_BYTES = 19 byte slot).
  // =====================================================================
  localparam [2:0] AXSIZE_16B = 3'b100;   // log2(16) = 4
  localparam [1:0] BURST_INCR = 2'b01;

  task automatic axi_write_16B(
    input [63:0]  addr,
    input [127:0] data
  );
    int timer;
    @(posedge aclk);
    sim_axi_dma.awid     <= 4'h0;
    sim_axi_dma.awaddr   <= addr;
    sim_axi_dma.awlen    <= 8'h00;
    sim_axi_dma.awsize   <= AXSIZE_16B;
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
        $error("axi_write_16B: timeout awready @0x%016h", addr);
        sim_axi_dma.awvalid <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.awready);
    sim_axi_dma.awvalid <= 1'b0;

    // wdata at the 512-bit bus: put data in the low 16 bytes, strobe
    // only those bytes.  The dwidth converter cascade narrows this
    // into a single 128-bit beat at the bridge slave.
    sim_axi_dma.wdata  <= {384'h0, data};
    sim_axi_dma.wstrb  <= {48'h0, 16'hFFFF};
    sim_axi_dma.wlast  <= 1'b1;
    sim_axi_dma.wvalid <= 1'b1;
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axi_write_16B: timeout wready @0x%016h", addr);
        sim_axi_dma.wvalid <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.wready);
    sim_axi_dma.wvalid <= 1'b0;
    sim_axi_dma.wlast  <= 1'b0;

    sim_axi_dma.bready <= 1'b1;
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axi_write_16B: timeout bvalid @0x%016h", addr);
        sim_axi_dma.bready <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.bvalid);
    if (sim_axi_dma.bresp != 2'b00)
      $error("axi_write_16B @0x%016h bresp=%0b", addr, sim_axi_dma.bresp);
    @(posedge aclk);
    sim_axi_dma.bready <= 1'b0;
  endtask

  task automatic axi_read_16B(
    input  [63:0]  addr,
    output [127:0] data
  );
    int timer;
    @(posedge aclk);
    sim_axi_dma.arid     <= 4'h0;
    sim_axi_dma.araddr   <= addr;
    sim_axi_dma.arlen    <= 8'h00;
    sim_axi_dma.arsize   <= AXSIZE_16B;
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
        $error("axi_read_16B: timeout arready @0x%016h", addr);
        sim_axi_dma.arvalid <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.arready);
    sim_axi_dma.arvalid <= 1'b0;

    sim_axi_dma.rready <= 1'b1;
    timer = 0;
    do begin
      @(posedge aclk);
      timer++;
      if (timer > TIMEOUT_CYCLES) begin
        $error("axi_read_16B: timeout rvalid @0x%016h", addr);
        sim_axi_dma.rready <= 1'b0;
        return;
      end
    end while (!sim_axi_dma.rvalid);
    data = sim_axi_dma.rdata[127:0];   // low 16 bytes are the 16-byte beat
    if (sim_axi_dma.rresp != 2'b00)
      $error("axi_read_16B @0x%016h rresp=%0b", addr, sim_axi_dma.rresp);
    @(posedge aclk);
    sim_axi_dma.rready <= 1'b0;
  endtask

  // =====================================================================
  // Aurora capture helpers (observe DUT TX, drive DUT RX).  All run on
  // aurora_user_clk because the bridge lives in that domain.
  // =====================================================================

  // Wait up to TX_WAIT_CYCLES aurora_user_clk edges for `cond` to be
  // true, returning 1 on success / 0 on timeout.  Used to gate on
  // tx_data_tvalid or tx_userk_tvalid.
  task automatic wait_aurora(string what, output bit ok);
    int timer = 0;
    ok = 1'b0;
    while (timer < TX_WAIT_CYCLES) begin
      @(posedge aurora_user_clk);
      timer++;
      if ((what == "tx_data")  && sim_aurora_tx_tvalid)       begin ok = 1'b1; return; end
      if ((what == "tx_userk") && sim_aurora_userk_tx_tvalid) begin ok = 1'b1; return; end
    end
    $error("wait_aurora: timeout waiting for %s tvalid", what);
  endtask

  // Capture a single flit from tx_data when the DUT asserts tvalid.
  task automatic capture_tx_data(
    output logic [255:0] tdata,
    output logic [31:0]  tkeep,
    output logic         tlast
  );
    bit ok;
    wait_aurora("tx_data", ok);
    if (!ok) begin tdata = '0; tkeep = '0; tlast = 1'b0; return; end
    tdata = sim_aurora_tx_tdata;
    tkeep = sim_aurora_tx_tkeep;
    tlast = sim_aurora_tx_tlast;
  endtask

  task automatic capture_tx_userk(output logic [255:0] tdata);
    bit ok;
    wait_aurora("tx_userk", ok);
    if (!ok) begin tdata = '0; return; end
    tdata = sim_aurora_userk_tx_tdata;
  endtask

  // Drive a single-flit packet on the DUT's userk RX.  The bridge
  // consumes whatever appears on userk_rx with tvalid high for one
  // aurora_user_clk edge.
  task automatic inject_userk(input [255:0] tdata);
    @(posedge aurora_user_clk);
    sim_aurora_userk_rx_tdata  <= tdata;
    sim_aurora_userk_rx_tvalid <= 1'b1;
    @(posedge aurora_user_clk);
    sim_aurora_userk_rx_tvalid <= 1'b0;
    sim_aurora_userk_rx_tdata  <= '0;
  endtask

  // Drive a single-flit packet on the DUT's data RX (with tlast / tkeep).
  task automatic inject_rx_data(
    input [255:0] tdata,
    input [31:0]  tkeep,
    input         tlast
  );
    @(posedge aurora_user_clk);
    sim_aurora_rx_tdata  <= tdata;
    sim_aurora_rx_tkeep  <= tkeep;
    sim_aurora_rx_tlast  <= tlast;
    sim_aurora_rx_tvalid <= 1'b1;
    @(posedge aurora_user_clk);
    sim_aurora_rx_tvalid <= 1'b0;
    sim_aurora_rx_tlast  <= 1'b0;
    sim_aurora_rx_tdata  <= '0;
    sim_aurora_rx_tkeep  <= '0;
  endtask

  // =====================================================================
  // Per-test bodies.  Each forks an "issuer" thread that drives the
  // AXI side and an "observer/responder" thread that watches the
  // aurora wires and injects the response.  join_any prevents either
  // side from deadlocking the other; the issuer is what completes when
  // the response packet has been consumed by the bridge.
  // =====================================================================

  task automatic test_axil_write;
    logic [255:0]   captured;
    logic [31:0]    captured_keep;
    logic           captured_last;
    logic [255:0]   resp;
    logic [31:0]    awaddr  = AXIL_BRIDGE_BASE;
    logic [31:0]    wdata   = 32'hCAFE_BABE;

    $display("");
    $display("[%0t] === Test 1: AXI-Lite write @0x%08h data=0x%08h ===",
             $time, awaddr, wdata);

    fork
      // Issuer
      axil_write(awaddr, wdata);

      // Observer + responder
      begin
        capture_tx_data(captured, captured_keep, captured_last);
        check    ("tx_data tlast=1",      captured_last == 1'b1);
        check    ("OP_AW opcode",          captured[P_OP_LSB +: 8] == OP_AW);
        check    ("lite=1",                captured[P_LITE_LSB]    == 1'b1);
        check_eq ("addr field",            captured[P_ADDR_LSB +: ADDR_W],
                                            {32'h0, awaddr});
        check_eq ("len = 0",               captured[P_LEN_LSB +: 8], 8'h0);
        // $clog2 returns a signed 32-bit int; the 3'(...) cast sign-
        // extends through check_eq's 128-bit arg.  Use an unsigned
        // literal instead.
        check_eq ("size = log2(16)",       captured[P_SIZE_LSB +: 3], 32'h4);
        check_eq ("burst = INCR",          captured[P_BURST_LSB +: 2], 2'b01);
        // W data: bridge pads the 32-bit XDMA wdata with 96 leading
        // zeros to make DATA_W=128; we expect the low 32 bits to be
        // our wdata and the upper 96 = 0.
        check_eq ("W data low 32",         captured[HDR_DATA_OFF +: 32], wdata);
        check_eq ("W data high 96 = 0",    captured[HDR_DATA_OFF + 32 +: 96], '0);

        // Synthesize B-Lite response and feed it back on userk_rx.
        resp = '0;
        resp[7:0] = OP_B_LITE;
        resp[9:8] = 2'b00;                 // OKAY
        inject_userk(resp);
      end
    join
  endtask

  task automatic test_axil_read;
    logic [255:0]   captured;
    logic [255:0]   resp;
    logic [31:0]    araddr   = AXIL_BRIDGE_BASE + 32'h4;
    logic [31:0]    exp_data = 32'hDEAD_F00D;
    logic [31:0]    got_data;

    $display("");
    $display("[%0t] === Test 2: AXI-Lite read @0x%08h (exp rdata=0x%08h) ===",
             $time, araddr, exp_data);

    fork
      begin
        axil_read(araddr, got_data);
      end

      begin
        capture_tx_userk(captured);
        check    ("OP_AR opcode",          captured[P_OP_LSB +: 8] == OP_AR);
        check    ("lite=1",                captured[P_LITE_LSB]    == 1'b1);
        check_eq ("addr field",            captured[P_ADDR_LSB +: ADDR_W],
                                            {32'h0, araddr});

        // R-Lite response: { rdata[DATA_W], rresp[2], OP_R_LITE }.
        // The bridge truncates rdata back to 32 b on the lite slave
        // port; we replicate our 32-bit exp_data across the 128-bit
        // rdata slot so any byte-lane confusion would still match.
        resp = '0;
        resp[7:0]                 = OP_R_LITE;
        resp[9:8]                 = 2'b00;         // OKAY
        resp[10 +: DATA_W]        = {4{exp_data}}; // 128 b: 4 copies
        inject_userk(resp);
      end
    join

    check_eq ("rdata low 32",            got_data, exp_data);
  endtask

  task automatic test_axi_write;
    logic [255:0]   captured;
    logic [31:0]    captured_keep;
    logic           captured_last;
    logic [255:0]   resp;
    logic [63:0]    awaddr  = AXI_BRIDGE_BASE;
    logic [127:0]   wdata   = 128'h0011_2233_4455_6677_8899_AABB_CCDD_EEFF;

    $display("");
    $display("[%0t] === Test 3: AXI4-Full write @0x%016h data=0x%032h ===",
             $time, awaddr, wdata);

    fork
      begin
        axi_write_16B(awaddr, wdata);
      end

      begin
        capture_tx_data(captured, captured_keep, captured_last);
        check    ("tx_data tlast=1",      captured_last == 1'b1);
        check    ("OP_AW opcode",          captured[P_OP_LSB +: 8] == OP_AW);
        check    ("lite=0",                captured[P_LITE_LSB]    == 1'b0);
        check_eq ("addr field",            captured[P_ADDR_LSB +: ADDR_W], awaddr);
        check_eq ("len = 0 (single beat)", captured[P_LEN_LSB +: 8], 8'h0);
        // $clog2 returns a signed 32-bit int; the 3'(...) cast sign-
        // extends through check_eq's 128-bit arg.  Use an unsigned
        // literal instead.
        check_eq ("size = log2(16)",       captured[P_SIZE_LSB +: 3], 32'h4);
        check_eq ("W data (128 b)",        captured[HDR_DATA_OFF +: DATA_W], wdata);

        // OP_B response: { bresp, bid, OP_B }
        resp = '0;
        resp[7:0]            = OP_B;
        resp[8 +: ID_W]      = 4'h0;       // bid = 0 (matches awid)
        resp[8+ID_W +: 2]    = 2'b00;      // bresp = OKAY
        inject_userk(resp);
      end
    join
  endtask

  task automatic test_axi_read;
    logic [255:0]   captured_userk;
    logic [255:0]   r_hdr;
    logic [63:0]    araddr   = AXI_BRIDGE_BASE + 64'h40;
    logic [127:0]   exp_data = 128'hAAAA_BBBB_CCCC_DDDD_1111_2222_3333_4444;
    logic [127:0]   got_data;

    $display("");
    $display("[%0t] === Test 4: AXI4-Full read @0x%016h (exp rdata=0x%032h) ===",
             $time, araddr, exp_data);

    fork
      begin
        axi_read_16B(araddr, got_data);
      end

      begin
        capture_tx_userk(captured_userk);
        check    ("OP_AR opcode",          captured_userk[P_OP_LSB +: 8] == OP_AR);
        check    ("lite=0",                captured_userk[P_LITE_LSB]    == 1'b0);
        check_eq ("addr field",            captured_userk[P_ADDR_LSB +: ADDR_W],
                                            araddr);
        check_eq ("len = 0",               captured_userk[P_LEN_LSB +: 8], 8'h0);
        check_eq ("size = log2(16)",       captured_userk[P_SIZE_LSB +: 3], 32'h4);

        // R-Full chunked response.  For a single beat (rlen = 0) the
        // bridge expects CHUNKS_PER_BEAT = 4 chunks of 32 bits.  All
        // 4 chunks fit in the R-Full header (R_HDR_CHUNK_CAP = 7), so
        // we send a single-flit response with tlast = 1.
        //
        // R hdr layout:
        //   [7:0]   OP_R
        //   [11:8]  rid (4 bits)
        //   [13:12] rresp (2 bits)
        //   [14 +: 7*32] up to 7 chunks of rdata
        //   [255:14+7*32 = 238] pad bytes
        r_hdr = '0;
        r_hdr[7:0]                          = OP_R;
        r_hdr[P_ID_LSB +: ID_W]             = 4'h0;       // rid = 0
        r_hdr[R_HDR_META_W-R_RESP_W +: 2]   = 2'b00;      // rresp = OKAY
        // 128 b rdata = 4 chunks
        r_hdr[R_HDR_META_W +: DATA_W]       = exp_data;

        // Single-flit R-Full frame: tkeep all-ones, tlast = 1.
        inject_rx_data(r_hdr, 32'hFFFFFFFF, 1'b1);
      end
    join

    check_eq ("rdata (128 b)",            got_data, exp_data);
  endtask

  // =====================================================================
  // Inbound tests: TB pretends to be the zcu102 far end.  It hand-
  // crafts AW/AR request packets, drops them on the bridge's RX wires,
  // and waits for the bridge to do the local HBM access and emit
  // the corresponding B/R response packets back on the TX wires.
  //
  // Wire shape: bridge.m_* (128 b AXI4) -> axi_dwidth_bridge_to_hbm
  // (128->256) -> axi_protocol_converter_bridge (AXI4->AXI3) ->
  // hbm_0.s_axi_00.  HBM model is the same instance the HBM TB hits
  // on port 31; we just route through port 0 here.
  //
  // We use ID=1 throughout to distinguish responses from any stale
  // ID=0 transactions queued earlier in the run.
  // =====================================================================
  localparam logic [ID_W-1:0] INBOUND_ID = 4'h1;

  // Build a request packet header (OP_AW or OP_AR) with the given
  // metadata in the bottom 104 bits.  W data (if any) is appended by
  // the caller via the optional `w_data_lo16` argument.
  function automatic logic [255:0] build_request_pkt(
    input logic [7:0]  op,
    input logic [63:0] addr,
    input logic [7:0]  len,
    input logic [2:0]  size,
    input logic [1:0]  burst,
    input logic [127:0] w_data_lo16   // ignored unless op == OP_AW
  );
    logic [255:0] pkt;
    pkt = '0;
    pkt[P_OP_LSB    +: 8]      = op;
    pkt[P_ID_LSB    +: ID_W]   = INBOUND_ID;
    pkt[P_ADDR_LSB  +: ADDR_W] = addr;
    pkt[P_LEN_LSB   +: 8]      = len;
    pkt[P_SIZE_LSB  +: 3]      = size;
    pkt[P_BURST_LSB +: 2]      = burst;
    pkt[P_CACHE_LSB +: 4]      = 4'b0011;
    pkt[P_PROT_LSB  +: 3]      = 3'b000;
    pkt[P_LITE_LSB]            = 1'b0;
    if (op == OP_AW)
      pkt[HDR_DATA_OFF +: DATA_W] = w_data_lo16;
    return pkt;
  endfunction

  task automatic test_inbound_write(
    input  [63:0]  addr,
    input  [127:0] wdata
  );
    logic [255:0] aw_pkt;
    logic [255:0] aw_tkeep;
    logic [255:0] b_resp;

    $display("");
    $display("[%0t] === Test 5: Inbound HBM write @0x%016h data=0x%032h ===",
             $time, addr, wdata);

    aw_pkt = build_request_pkt(OP_AW, addr, 8'h0, AXSIZE_16B, BURST_INCR, wdata);
    // tkeep: [12:0]=metadata (always valid), [28:13]=wstrb for 16 W
    // bytes, [31:29]=trailing pad (invalid).
    aw_tkeep = {3'b000, 16'hFFFF, 13'h1FFF};

    if (dbg_enable) begin
      $display("[%0t] DBG TB aw_pkt        = 0x%064h", $time, aw_pkt);
      $display("[%0t] DBG TB aw_tkeep[31:0]= 0x%08h",  $time, aw_tkeep[31:0]);
    end

    fork
      // Drive the OP_AW frame on rx_data, then watch for the B
      // response packet on tx_userk.
      begin
        inject_rx_data(aw_pkt, aw_tkeep[31:0], 1'b1);
        capture_tx_userk(b_resp);
        check    ("OP_B opcode",        b_resp[P_OP_LSB +: 8]      == OP_B);
        check_eq ("bid matches awid",   b_resp[P_ID_LSB +: ID_W],   INBOUND_ID);
        check_eq ("bresp = OKAY",       b_resp[P_ID_LSB+ID_W +: 2], 2'b00);
      end
    join
  endtask

  // Issue one inbound read packet and capture the chunked R response.
  // Returns the rdata extracted from the (single) R header flit; also
  // returns the metadata fields by reference so the caller can verify
  // them once.  Used both directly by test_inbound_read and by the
  // poll-commit helper below.
  task automatic inbound_read_once(
    input  [63:0]    addr,
    output logic [127:0] got_data,
    output logic [255:0] r_hdr,
    output logic         r_last
  );
    logic [255:0] ar_pkt;
    logic [31:0]  r_keep;
    ar_pkt = build_request_pkt(OP_AR, addr, 8'h0, AXSIZE_16B, BURST_INCR, '0);
    fork
      inject_userk(ar_pkt);
      capture_tx_data(r_hdr, r_keep, r_last);
    join
    got_data = r_hdr[R_HDR_META_W +: DATA_W];
  endtask

  // Poll-read through the inbound bridge path until rdata's low 32 b
  // matches `exp_low`, returning the converged rdata.  Same idea as
  // the HBM TB's dma_wait_commit: the HBM model's BVALID is optimistic,
  // so an inbound read issued immediately after an inbound write can
  // race the DRAM commit.  Each attempt round-trips through the full
  // packet path (depacketize AR -> AXI master -> HBM read -> packetize
  // R), which is naturally several hundred cycles, so a modest max
  // count covers the worst case.
  localparam int INBOUND_POLL_MAX = 50;
  localparam int INBOUND_POLL_GAP = 100;   // aurora_user_clks between attempts

  task automatic inbound_read_until(
    input  [63:0]    addr,
    input  [31:0]    exp_low,
    output logic [127:0] got_data
  );
    logic [255:0] r_hdr;
    logic         r_last;
    for (int attempt = 0; attempt < INBOUND_POLL_MAX; attempt++) begin
      inbound_read_once(addr, got_data, r_hdr, r_last);
      if (got_data[31:0] === exp_low) return;
      repeat (INBOUND_POLL_GAP) @(posedge aurora_user_clk);
    end
    $error("inbound_read_until: addr=0x%016h never converged on 0x%08h (last=0x%08h)",
           addr, exp_low, got_data[31:0]);
  endtask

  task automatic test_inbound_read(
    input  [63:0]   addr,
    input  [127:0]  exp_data
  );
    logic [127:0] got_data;
    logic [255:0] r_hdr;
    logic         r_last;

    $display("");
    $display("[%0t] === Test 6: Inbound HBM read  @0x%016h (exp=0x%032h) ===",
             $time, addr, exp_data);

    // First, validate the response packet *shape* on a single read.
    // This catches packet-format bugs even if the data hasn't
    // committed yet (the header metadata fields don't depend on what
    // HBM holds).
    inbound_read_once(addr, got_data, r_hdr, r_last);
    check    ("R tlast=1",          r_last == 1'b1);
    check    ("OP_R opcode",        r_hdr[P_OP_LSB +: 8]      == OP_R);
    check_eq ("rid matches arid",   r_hdr[P_ID_LSB +: ID_W],   INBOUND_ID);
    check_eq ("rresp = OKAY",       r_hdr[P_ID_LSB+ID_W +: 2], 2'b00);

    // If the first read already saw the write, accept it; otherwise
    // poll-read through the same path until HBM's optimistic-BVALID
    // commit lag clears.
    if (got_data === exp_data) begin
      pass_count++;
      $display("[%0t]   PASS: rdata matches write on first attempt (0x%0h)",
               $time, got_data);
    end else begin
      $display("[%0t]   first read returned 0x%0h, polling for commit...",
               $time, got_data);
      inbound_read_until(addr, exp_data[31:0], got_data);
      check_eq ("rdata matches write (after commit poll)", got_data, exp_data);
    end
  endtask

  // =====================================================================
  // Main test sequence
  // =====================================================================
  initial begin
    // Idle every TB-driven signal first.
    sim_axil.awaddr  = '0;  sim_axil.awprot  = '0;  sim_axil.awvalid = 1'b0;
    sim_axil.wdata   = '0;  sim_axil.wstrb   = '0;  sim_axil.wvalid  = 1'b0;
    sim_axil.bready  = 1'b0;
    sim_axil.araddr  = '0;  sim_axil.arprot  = '0;  sim_axil.arvalid = 1'b0;
    sim_axil.rready  = 1'b0;

    sim_axi_dma.awid     = '0;  sim_axi_dma.awaddr   = '0;  sim_axi_dma.awlen   = '0;
    sim_axi_dma.awsize   = '0;  sim_axi_dma.awburst  = '0;  sim_axi_dma.awlock  = '0;
    sim_axi_dma.awcache  = '0;  sim_axi_dma.awprot   = '0;  sim_axi_dma.awqos   = '0;
    sim_axi_dma.awregion = '0;  sim_axi_dma.awvalid  = 1'b0;
    sim_axi_dma.wdata    = '0;  sim_axi_dma.wstrb    = '0;  sim_axi_dma.wlast   = 1'b0;
    sim_axi_dma.wvalid   = 1'b0;
    sim_axi_dma.bready   = 1'b0;
    sim_axi_dma.arid     = '0;  sim_axi_dma.araddr   = '0;  sim_axi_dma.arlen   = '0;
    sim_axi_dma.arsize   = '0;  sim_axi_dma.arburst  = '0;  sim_axi_dma.arlock  = '0;
    sim_axi_dma.arcache  = '0;  sim_axi_dma.arprot   = '0;  sim_axi_dma.arqos   = '0;
    sim_axi_dma.arregion = '0;  sim_axi_dma.arvalid  = 1'b0;
    sim_axi_dma.rready   = 1'b0;

    // ---- Reset ----
    $display("[%0t] Asserting reset for %0d aclk cycles", $time, RESET_CYCLES);
    rstn = 1'b0;
    repeat (RESET_CYCLES) @(posedge aclk);
    rstn = 1'b1;
    $display("[%0t] Reset deasserted", $time);

    // ---- Aurora bring-up + bridge settle ----
    // Channel_up gates the bridge out of reset; give CDC time after.
    $display("[%0t] Waiting %0d aurora_user_clk cycles before channel_up",
             $time, AURORA_UP_CYCLES);
    repeat (AURORA_UP_CYCLES) @(posedge aurora_user_clk);
    aurora_chan_up = 1'b1;
    $display("[%0t] channel_up asserted, settling %0d aclks before tests",
             $time, POST_CHANNEL_SETTLE);
    repeat (POST_CHANNEL_SETTLE) @(posedge aclk);

    // ---- Run tests ----
    test_axil_write;
    test_axil_read;
    test_axi_write;
    test_axi_read;

    // ---- Wait for HBM behavioural model init before touching it ----
    $display("");
    $display("[%0t] Waiting %0d aclks (~%0d us) for HBM init before inbound tests",
             $time, HBM_INIT_WAIT_CYCLES,
             int'(HBM_INIT_WAIT_CYCLES * CLK_PERIOD_NS / 1000.0));
    repeat (HBM_INIT_WAIT_CYCLES) @(posedge aclk);
    $display("[%0t] HBM init wait complete", $time);

    // ---- Inbound tests: zcu102 (TB) writes and reads pncel HBM ----
    // Address 0 on bridge.m_* lands at HBM port 0 / PC 0 offset 0 via
    // the bridge protocol-converter chain.  Same write+read pattern
    // as the HBM TB: write a known value, then read it back through
    // the same packet path to prove the inbound chain round-trips
    // through actual HBM cells (not just bridge plumbing).
    //
    // Cross-check: also issue an XDMA-side read of the same physical
    // PC via the HBM-port-31 BAR window (0x4_0000_0000).  Port 31 and
    // port 0 both reach the full HBM with USER_SWITCH enabled, so a
    // bridge-side write at HBM addr X should be visible to an
    // XDMA-side read at addr 0x4_0000_0000 | X.  If the bridge write
    // is reaching HBM, this readback will show it (and the inbound
    // read failing on its own would then point at the bridge's R
    // packetization path, not the write path).
    begin
      automatic logic [127:0] pattern = 128'hF00D_BABE_DEAD_BEEF_1234_5678_9ABC_DEF0;
      // Use a non-zero, 16-byte-aligned address to rule out any
      // special-case handling around address 0 in the HBM model.
      automatic logic [63:0]  inbound_addr = 64'h0000_0000_0000_0080;
      test_inbound_write(inbound_addr, pattern);
      test_inbound_read (inbound_addr, pattern);
    end

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

  // =====================================================================
  // Debug probes — hierarchical references into pncel_dynamic_region to
  // monitor the bridge's master-port handshakes and the AXI3 wires
  // feeding HBM port 0.  Enabled with +debug on the simulate command
  // line.  Helps isolate whether a missing write is the bridge not
  // emitting AW/W, the dwidth/protocol converter swallowing it, or
  // HBM port 0 not seeing it.
  // =====================================================================
  // (dbg_enable now declared near the top of the module so the test
  //  bodies — which reference it before this block — can see it.)

  // Bridge master port (128 b AXI4, aurora_user_clk).  These are inside
  // pncel_dynamic_region.sv as br_m_* wires.
  wire dbg_bm_awvalid = u_dut.dynamic_inst.u_region.br_m_awvalid;
  wire dbg_bm_awready = u_dut.dynamic_inst.u_region.br_m_awready;
  wire dbg_bm_wvalid  = u_dut.dynamic_inst.u_region.br_m_wvalid;
  wire dbg_bm_wready  = u_dut.dynamic_inst.u_region.br_m_wready;
  wire dbg_bm_wlast   = u_dut.dynamic_inst.u_region.br_m_wlast;
  wire dbg_bm_bvalid  = u_dut.dynamic_inst.u_region.br_m_bvalid;
  wire dbg_bm_bready  = u_dut.dynamic_inst.u_region.br_m_bready;
  wire dbg_bm_arvalid = u_dut.dynamic_inst.u_region.br_m_arvalid;
  wire dbg_bm_arready = u_dut.dynamic_inst.u_region.br_m_arready;
  wire dbg_bm_rvalid  = u_dut.dynamic_inst.u_region.br_m_rvalid;
  wire dbg_bm_rready  = u_dut.dynamic_inst.u_region.br_m_rready;

  // Protocol converter master side (AXI3, 256 b) feeding HBM s_axi_00.
  wire dbg_pc_awvalid = u_dut.dynamic_inst.u_region.pc_m_awvalid;
  wire dbg_pc_awready = u_dut.dynamic_inst.u_region.pc_m_awready;
  wire dbg_pc_wvalid  = u_dut.dynamic_inst.u_region.pc_m_wvalid;
  wire dbg_pc_wready  = u_dut.dynamic_inst.u_region.pc_m_wready;
  wire dbg_pc_wlast   = u_dut.dynamic_inst.u_region.pc_m_wlast;
  wire dbg_pc_bvalid  = u_dut.dynamic_inst.u_region.pc_m_bvalid;
  wire dbg_pc_bready  = u_dut.dynamic_inst.u_region.pc_m_bready;
  wire dbg_pc_arvalid = u_dut.dynamic_inst.u_region.pc_m_arvalid;
  wire dbg_pc_arready = u_dut.dynamic_inst.u_region.pc_m_arready;
  wire dbg_pc_rvalid  = u_dut.dynamic_inst.u_region.pc_m_rvalid;
  wire dbg_pc_rready  = u_dut.dynamic_inst.u_region.pc_m_rready;

  // Deep probes inside the depacketizer (the module that consumes RX
  // packets).  Lets us see if rx_data_tdata is arriving correctly,
  // whether aw_rx_fire actually trips, and what gets into the W byte
  // buffer.
  wire        dbg_dep_aw_rx_fire = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.aw_rx_fire;
  wire        dbg_dep_rx_in_cont = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.rx_in_cont_i;
  wire [255:0] dbg_dep_rx_tdata  = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.rx_data_tdata;
  wire [31:0]  dbg_dep_rx_tkeep  = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.rx_data_tkeep;
  wire         dbg_dep_rx_tvalid = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.rx_data_tvalid;
  wire [63:0]  dbg_dep_rx_aw_addr = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.rx_aw_addr;
  // Latched AW register and m_full_awvalid (depacketizer output)
  wire [63:0]  dbg_dep_aw_addr_r  = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.aw_addr_r;
  wire         dbg_dep_m_full_awvalid = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.m_full_awvalid;
  wire         dbg_dep_m_full_awready = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.m_full_awready;
  wire [127:0] dbg_dep_w_data_unpacked = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.w_data_unpacked;
  wire [15:0]  dbg_dep_w_strb_unpacked = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.u_depacketizer.w_strb_unpacked;
  // Intermediate points along the awaddr propagation chain.
  wire [63:0]  dbg_resp_m_full_awaddr = u_dut.dynamic_inst.u_region.u_bridge.u_axi_aurora_responder.m_full_awaddr;
  wire [63:0]  dbg_brinv_m_awaddr     = u_dut.dynamic_inst.u_region.u_bridge.m_awaddr;

  always @(posedge aurora_user_clk) if (dbg_enable && rstn) begin
    if (dbg_dep_aw_rx_fire)
      $display("[%0t] DBG dep aw_rx_fire: rx_tdata[31:0]=0x%08h rx_tdata[231:104]=0x%032h rx_tkeep=0x%08h rx_aw_addr=0x%016h rx_in_cont_i=%b",
               $time,
               dbg_dep_rx_tdata[31:0],
               dbg_dep_rx_tdata[231:104],
               dbg_dep_rx_tkeep,
               dbg_dep_rx_aw_addr,
               dbg_dep_rx_in_cont);
    // Print aw_addr_r every cycle m_full_awvalid is high (it's combinational
    // from aw_addr_r, so if it ever differs from what we latched, we'll see
    // it here).
    if (dbg_dep_m_full_awvalid)
      $display("[%0t] DBG dep awvalid: aw_addr_r=0x%016h m_full_awvalid=%b m_full_awready=%b w_data_unpacked[127:0]=0x%032h w_strb=0x%04h",
               $time,
               dbg_dep_aw_addr_r,
               dbg_dep_m_full_awvalid,
               dbg_dep_m_full_awready,
               dbg_dep_w_data_unpacked,
               dbg_dep_w_strb_unpacked);
  end

  always @(posedge aurora_user_clk) if (dbg_enable && rstn) begin
    if (dbg_bm_awvalid && dbg_bm_awready)
      $display("[%0t] DBG bridge.m_AW fire: br_m_awaddr=0x%016h resp.m_full_awaddr=0x%016h brinv.m_awaddr=0x%016h dep.aw_addr_r=0x%016h len=%0d id=%0d",
               $time,
               u_dut.dynamic_inst.u_region.br_m_awaddr,
               dbg_resp_m_full_awaddr,
               dbg_brinv_m_awaddr,
               dbg_dep_aw_addr_r,
               u_dut.dynamic_inst.u_region.br_m_awlen,
               u_dut.dynamic_inst.u_region.br_m_awid);
    if (dbg_bm_wvalid && dbg_bm_wready)
      $display("[%0t] DBG bridge.m_W  fire data=0x%032h strb=0x%04h last=%0b",
               $time,
               u_dut.dynamic_inst.u_region.br_m_wdata,
               u_dut.dynamic_inst.u_region.br_m_wstrb,
               dbg_bm_wlast);
    if (dbg_bm_bvalid && dbg_bm_bready)
      $display("[%0t] DBG bridge.m_B  fire bid=%0d bresp=%0d",
               $time,
               u_dut.dynamic_inst.u_region.br_m_bid,
               u_dut.dynamic_inst.u_region.br_m_bresp);
    if (dbg_bm_arvalid && dbg_bm_arready)
      $display("[%0t] DBG bridge.m_AR fire addr=0x%016h len=%0d id=%0d",
               $time,
               u_dut.dynamic_inst.u_region.br_m_araddr,
               u_dut.dynamic_inst.u_region.br_m_arlen,
               u_dut.dynamic_inst.u_region.br_m_arid);
    if (dbg_bm_rvalid && dbg_bm_rready)
      $display("[%0t] DBG bridge.m_R  fire data=0x%032h last=%0b",
               $time,
               u_dut.dynamic_inst.u_region.br_m_rdata,
               u_dut.dynamic_inst.u_region.br_m_rlast);

    if (dbg_pc_awvalid && dbg_pc_awready)
      $display("[%0t] DBG pc->hbm.AW  fire addr=0x%016h len=%0d",
               $time,
               u_dut.dynamic_inst.u_region.pc_m_awaddr,
               u_dut.dynamic_inst.u_region.pc_m_awlen);
    if (dbg_pc_wvalid && dbg_pc_wready)
      $display("[%0t] DBG pc->hbm.W   fire data=0x%064h strb=0x%08h last=%0b",
               $time,
               u_dut.dynamic_inst.u_region.pc_m_wdata,
               u_dut.dynamic_inst.u_region.pc_m_wstrb,
               dbg_pc_wlast);
    if (dbg_pc_bvalid && dbg_pc_bready)
      $display("[%0t] DBG pc->hbm.B   fire bresp=%0d",
               $time, u_dut.dynamic_inst.u_region.pc_m_bresp);
    if (dbg_pc_arvalid && dbg_pc_arready)
      $display("[%0t] DBG pc->hbm.AR  fire addr=0x%016h len=%0d",
               $time,
               u_dut.dynamic_inst.u_region.pc_m_araddr,
               u_dut.dynamic_inst.u_region.pc_m_arlen);
    if (dbg_pc_rvalid && dbg_pc_rready)
      $display("[%0t] DBG pc->hbm.R   fire data=0x%064h last=%0b",
               $time,
               u_dut.dynamic_inst.u_region.pc_m_rdata,
               u_dut.dynamic_inst.u_region.pc_m_rlast);
  end

  // =====================================================================
  // Global timeout
  // =====================================================================
  initial begin
    #(CLK_PERIOD_NS * 500_000); // 500k aclks = 2 ms wall-clock
    $error("GLOBAL TIMEOUT - simulation did not finish in 500k cycles");
    $finish;
  end

  // =====================================================================
  // Optional waveform dump
  // =====================================================================
  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_pncel_aurora.vcd");
      $dumpvars(0, tb_pncel_aurora);
    end
  end

endmodule
