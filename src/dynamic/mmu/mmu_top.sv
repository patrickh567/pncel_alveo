// *************************************************************************
//
// MMU top — wraps the systolic array, the staging buffers, the parallel
// load / store engines, and the control FSM.  Exposes one AXI-Lite slave
// to the host (for command/control) and 6 AXI4 master ports to HBM,
// sized to saturate the 32×32 systolic array's per-cycle data movement:
//
//   Activations in : 32 lanes × 8 bits  = 32 B/cycle  → 1 HBM port
//   Weights load   : 32 lanes × 8 bits  = 32 B/cycle  → 1 HBM port
//   Outputs out    : 32 lanes × 32 bits = 128 B/cycle → 4 HBM ports
//   Total                                               6 HBM ports
//
// Two of these MMUs are instantiated in parallel inside the RM, for a
// total of 12 HBM ports — same budget as the earlier monolithic 64×64
// design.  Each MMU is a self-contained matmul tile; the RM-level
// control plane multiplexes work between them.
//
// All buffers are partitioned bank-by-row so each engine reads / writes
// a contiguous slice of the matrix in HBM (no strided AXI transactions
// — every burst is a regular INCR sequence).  The systolic array sees
// a single flat addressing space; for the C buffer mmu_top decodes
// (row index → bank, sub-row).  A and B have a single bank each, so
// no decode is needed on the compute side.
//
//   A buffer (1 KB, 32 rows × 32 B):  1 bank × 32 rows × 256 b
//   B buffer (1 KB, 32 rows × 32 B):  1 bank × 32 rows × 256 b
//   C buffer (4 KB, 32 rows × 128 B): 4 banks × 8 rows × 1024 b
//
// Hierarchy:
//
//   mmu_top
//   ├── mmu_control                 (axil_reg_map + top FSM)
//   ├── mmu_load_engine     × 1     (A loader)
//   ├── mmu_load_engine     × 1     (B loader)
//   ├── mmu_store_engine    × 4     (C writers, one per bank)
//   ├── mmu_bram_2p         × 1     (A bank)
//   ├── mmu_bram_2p         × 1     (B bank)
//   ├── mmu_bram_2p         × 4     (C banks)
//   └── mmu_systolic_array
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_top
  import mmu_pkg::*;
(
  input  logic         clk,
  input  logic         aresetn,        // active-low from dyn_aresetn

  // Host control
  axi_if.slave         s_axil,

  // HBM masters — 1 for A, 1 for B, 4 for C
  axi_if.master        m_axi_hbm_a0,
  axi_if.master        m_axi_hbm_b0,
  axi_if.master        m_axi_hbm_c0,
  axi_if.master        m_axi_hbm_c1,
  axi_if.master        m_axi_hbm_c2,
  axi_if.master        m_axi_hbm_c3
);

  // Local synchronous active-high reset
  logic rst;
  assign rst = ~aresetn;

  // -----------------------------------------------------------------
  // Sizing
  // -----------------------------------------------------------------
  localparam int A_BUF_WIDTH = MMU_K * IN_W;        // 32 × 8  = 256
  localparam int B_BUF_WIDTH = MMU_N * IN_W;        // 32 × 8  = 256
  localparam int C_BUF_WIDTH = MMU_N * ACC_W;       // 32 × 32 = 1024

  localparam int N_C_BANKS   = 4;
  localparam int C_BANK_ROWS = MMU_M / N_C_BANKS;   // 8

  // -----------------------------------------------------------------
  // Control FSM ↔ buffer plumbing
  // -----------------------------------------------------------------
  logic                              load_a_start, load_a_done_all;
  logic [HBM_ADDR_W-1:0]             load_a_addr;
  logic                              load_b_start, load_b_done_all;
  logic [HBM_ADDR_W-1:0]             load_b_addr;
  logic                              store_c_start, store_c_done_all;
  logic [HBM_ADDR_W-1:0]             store_c_addr;

  logic                              ctrl_a_buf_re;
  logic [$clog2(MMU_M)-1:0]          ctrl_a_buf_raddr;
  logic [A_BUF_WIDTH-1:0]            ctrl_a_buf_rdata;

  logic                              ctrl_b_buf_re;
  logic [$clog2(MMU_K)-1:0]          ctrl_b_buf_raddr;
  logic [B_BUF_WIDTH-1:0]            ctrl_b_buf_rdata;

  logic                              ctrl_c_buf_we;
  logic [$clog2(MMU_M)-1:0]          ctrl_c_buf_waddr;
  logic [C_BUF_WIDTH-1:0]            ctrl_c_buf_wdata;

  logic                                 sa_w_load_en;
  logic [$clog2(MMU_K)-1:0]             sa_w_load_row;
  logic signed [MMU_N-1:0][IN_W-1:0]    sa_w_load_data;
  logic                                 sa_a_valid;
  logic signed [MMU_K-1:0][IN_W-1:0]    sa_a_row_in;
  logic                                 sa_c_valid;
  logic signed [MMU_N-1:0][ACC_W-1:0]   sa_c_row_out;

  // -----------------------------------------------------------------
  // A buffer: single bank of 256-bit × 32-row.  No bank decode —
  // ctrl_a_buf_raddr is the full address.
  // -----------------------------------------------------------------
  logic                                  a_bank_we;
  logic [$clog2(MMU_M)-1:0]              a_bank_waddr;
  logic [A_BUF_WIDTH-1:0]                a_bank_wdata;
  logic                                  a_bank_re;
  logic [A_BUF_WIDTH-1:0]                a_bank_rdata;

  mmu_bram_2p #(.WIDTH(A_BUF_WIDTH), .DEPTH(MMU_M)) u_a_bank (
    .clk      (clk),
    .wr_en    (a_bank_we),
    .wr_addr  (a_bank_waddr),
    .wr_data  (a_bank_wdata),
    .rd_en    (a_bank_re),
    .rd_addr  (ctrl_a_buf_raddr),
    .rd_data  (a_bank_rdata)
  );

  assign a_bank_re        = ctrl_a_buf_re;
  assign ctrl_a_buf_rdata = a_bank_rdata;

  // -----------------------------------------------------------------
  // B buffer: same shape as A — single bank, no decode.
  // -----------------------------------------------------------------
  logic                                  b_bank_we;
  logic [$clog2(MMU_K)-1:0]              b_bank_waddr;
  logic [B_BUF_WIDTH-1:0]                b_bank_wdata;
  logic                                  b_bank_re;
  logic [B_BUF_WIDTH-1:0]                b_bank_rdata;

  mmu_bram_2p #(.WIDTH(B_BUF_WIDTH), .DEPTH(MMU_K)) u_b_bank (
    .clk      (clk),
    .wr_en    (b_bank_we),
    .wr_addr  (b_bank_waddr),
    .wr_data  (b_bank_wdata),
    .rd_en    (b_bank_re),
    .rd_addr  (ctrl_b_buf_raddr),
    .rd_data  (b_bank_rdata)
  );

  assign b_bank_re        = ctrl_b_buf_re;
  assign ctrl_b_buf_rdata = b_bank_rdata;

  // -----------------------------------------------------------------
  // C buffer: 4 banks, each 1024-bit × 8-row
  // -----------------------------------------------------------------
  logic [N_C_BANKS-1:0]                  c_bank_we;
  logic [$clog2(C_BANK_ROWS)-1:0]        c_bank_waddr;
  logic [C_BUF_WIDTH-1:0]                c_bank_wdata;
  logic [N_C_BANKS-1:0]                  c_bank_re;
  logic [$clog2(C_BANK_ROWS)-1:0]        c_bank_raddr [N_C_BANKS];
  logic [C_BUF_WIDTH-1:0]                c_bank_rdata [N_C_BANKS];

  for (genvar i = 0; i < N_C_BANKS; i++) begin : g_c_bank
    mmu_bram_2p #(.WIDTH(C_BUF_WIDTH), .DEPTH(C_BANK_ROWS)) u_bank (
      .clk      (clk),
      .wr_en    (c_bank_we[i]),
      .wr_addr  (c_bank_waddr),
      .wr_data  (c_bank_wdata),
      .rd_en    (c_bank_re[i]),
      .rd_addr  (c_bank_raddr[i]),
      .rd_data  (c_bank_rdata[i])
    );
  end

  // Compute-side write decode: row index → (bank, sub-row)
  wire [$clog2(N_C_BANKS)-1:0]        c_wr_bank = ctrl_c_buf_waddr[$clog2(MMU_M)-1 -: $clog2(N_C_BANKS)];
  assign c_bank_waddr                  = ctrl_c_buf_waddr[$clog2(C_BANK_ROWS)-1:0];
  assign c_bank_wdata                  = ctrl_c_buf_wdata;
  for (genvar i = 0; i < N_C_BANKS; i++) begin : g_c_we_decode
    assign c_bank_we[i] = ctrl_c_buf_we && (c_wr_bank == i[$clog2(N_C_BANKS)-1:0]);
  end

  // -----------------------------------------------------------------
  // A loader — single engine fills the entire A bank from base_addr.
  // -----------------------------------------------------------------
  mmu_load_engine #(.NUM_ROWS(MMU_M), .BUF_WIDTH(A_BUF_WIDTH)) u_load_a0 (
    .clk(clk), .rst(rst), .start(load_a_start),
    .base_addr(load_a_addr),
    .done(load_a_done_all), .m_axi_hbm(m_axi_hbm_a0),
    .bram_we(a_bank_we), .bram_addr(a_bank_waddr), .bram_data(a_bank_wdata)
  );

  // -----------------------------------------------------------------
  // B loader — same shape as A
  // -----------------------------------------------------------------
  mmu_load_engine #(.NUM_ROWS(MMU_K), .BUF_WIDTH(B_BUF_WIDTH)) u_load_b0 (
    .clk(clk), .rst(rst), .start(load_b_start),
    .base_addr(load_b_addr),
    .done(load_b_done_all), .m_axi_hbm(m_axi_hbm_b0),
    .bram_we(b_bank_we), .bram_addr(b_bank_waddr), .bram_data(b_bank_wdata)
  );

  // -----------------------------------------------------------------
  // C writers — 4 parallel single-port engines, each draining its bank.
  // SystemVerilog forbids selecting between named interface instances
  // inside a generate-for, so the engines are unrolled explicitly.
  // -----------------------------------------------------------------
  localparam int C_BANK_BYTES = C_BANK_ROWS * (C_BUF_WIDTH/8);
  logic [N_C_BANKS-1:0]   c_engine_done;

  mmu_store_engine #(.NUM_ROWS(C_BANK_ROWS), .BUF_WIDTH(C_BUF_WIDTH)) u_store_c0 (
    .clk(clk), .rst(rst), .start(store_c_start),
    .base_addr(store_c_addr + 0 * C_BANK_BYTES),
    .done(c_engine_done[0]), .m_axi_hbm(m_axi_hbm_c0),
    .bram_re(c_bank_re[0]), .bram_addr(c_bank_raddr[0]), .bram_rdata(c_bank_rdata[0])
  );
  mmu_store_engine #(.NUM_ROWS(C_BANK_ROWS), .BUF_WIDTH(C_BUF_WIDTH)) u_store_c1 (
    .clk(clk), .rst(rst), .start(store_c_start),
    .base_addr(store_c_addr + 1 * C_BANK_BYTES),
    .done(c_engine_done[1]), .m_axi_hbm(m_axi_hbm_c1),
    .bram_re(c_bank_re[1]), .bram_addr(c_bank_raddr[1]), .bram_rdata(c_bank_rdata[1])
  );
  mmu_store_engine #(.NUM_ROWS(C_BANK_ROWS), .BUF_WIDTH(C_BUF_WIDTH)) u_store_c2 (
    .clk(clk), .rst(rst), .start(store_c_start),
    .base_addr(store_c_addr + 2 * C_BANK_BYTES),
    .done(c_engine_done[2]), .m_axi_hbm(m_axi_hbm_c2),
    .bram_re(c_bank_re[2]), .bram_addr(c_bank_raddr[2]), .bram_rdata(c_bank_rdata[2])
  );
  mmu_store_engine #(.NUM_ROWS(C_BANK_ROWS), .BUF_WIDTH(C_BUF_WIDTH)) u_store_c3 (
    .clk(clk), .rst(rst), .start(store_c_start),
    .base_addr(store_c_addr + 3 * C_BANK_BYTES),
    .done(c_engine_done[3]), .m_axi_hbm(m_axi_hbm_c3),
    .bram_re(c_bank_re[3]), .bram_addr(c_bank_raddr[3]), .bram_rdata(c_bank_rdata[3])
  );

  assign store_c_done_all = &c_engine_done;

  // -----------------------------------------------------------------
  // Systolic array
  // -----------------------------------------------------------------
  mmu_systolic_array u_array (
    .clk         (clk),
    .rst         (rst),
    .w_load_en   (sa_w_load_en),
    .w_load_row  (sa_w_load_row),
    .w_load_data (sa_w_load_data),
    .a_valid     (sa_a_valid),
    .a_row_in    (sa_a_row_in),
    .c_valid     (sa_c_valid),
    .c_row_out   (sa_c_row_out)
  );

  // -----------------------------------------------------------------
  // Control FSM
  // -----------------------------------------------------------------
  mmu_control u_ctrl (
    .clk            (clk),
    .rst            (rst),
    .s_axil         (s_axil),

    .load_a_start   (load_a_start),
    .load_a_addr    (load_a_addr),
    .load_a_done    (load_a_done_all),

    .load_b_start   (load_b_start),
    .load_b_addr    (load_b_addr),
    .load_b_done    (load_b_done_all),

    .store_c_start  (store_c_start),
    .store_c_addr   (store_c_addr),
    .store_c_done   (store_c_done_all),

    .a_buf_rd_en    (ctrl_a_buf_re),
    .a_buf_rd_addr  (ctrl_a_buf_raddr),
    .a_buf_rd_data  (ctrl_a_buf_rdata),

    .b_buf_rd_en    (ctrl_b_buf_re),
    .b_buf_rd_addr  (ctrl_b_buf_raddr),
    .b_buf_rd_data  (ctrl_b_buf_rdata),

    .c_buf_wr_en    (ctrl_c_buf_we),
    .c_buf_wr_addr  (ctrl_c_buf_waddr),
    .c_buf_wr_data  (ctrl_c_buf_wdata),

    .w_load_en      (sa_w_load_en),
    .w_load_row     (sa_w_load_row),
    .w_load_data    (sa_w_load_data),

    .a_valid        (sa_a_valid),
    .a_row_in       (sa_a_row_in),

    .c_valid        (sa_c_valid),
    .c_row_out      (sa_c_row_out)
  );

endmodule : mmu_top
