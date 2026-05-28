// *************************************************************************
//
// MMU control unit — host AXI-Lite register file + top-level FSM that
// sequences the load engines, the systolic array, and the store engine.
//
// Register map (host BAR offsets relative to the dynamic-region window):
//
//   0x00  CMD       — bit 0  : start    (W: 1 → kick off; HW clears)
//                     bit 31 : done     (R/O: HW sets when complete)
//   0x04  STATUS    — R/O state machine state, error flags (raw/loopback)
//   0x08  M         — rows of A and C   (must be MMU_M for first cut)
//   0x0C  N         — cols of B and C   (must be MMU_N)
//   0x10  K         — cols of A / rows of B (must be MMU_K)
//   0x14  A_ADDR_L  — low  32 bits of HBM byte address for A
//   0x18  A_ADDR_H  — high 32 bits
//   0x1C  B_ADDR_L  — low  32 bits of HBM byte address for B
//   0x20  B_ADDR_H  — high 32 bits
//   0x24  C_ADDR_L  — low  32 bits of HBM byte address for C
//   0x28  C_ADDR_H  — high 32 bits
//   0x2C  SCRATCH   — software loopback (no HW semantics)
//
// Top FSM:
//
//   IDLE
//     │  start written
//     ▼
//   LOAD_AB  (load_a + load_b in parallel — they use independent HBM ports)
//     │  load_a_done && load_b_done
//     ▼
//   COMPUTE  (sub-FSM: LOAD_W → STREAM_A → wait for capture)
//     │  c_capture_count == MMU_M
//     ▼
//   STORE_C
//     │  store_c_done
//     ▼
//   DONE     (raises bit 31 of CMD; next start brings us back to IDLE)
//
// The COMPUTE sub-FSM:
//   * LOAD_W: K+1 cycles.  Reads B-buffer row r each cycle (BRAM has a
//     1-cycle read latency), then drives the systolic array's
//     w_load_en/row/data with the registered B-buffer data.
//   * STREAM_A: M+1 cycles.  Same read-then-drive pattern with the A
//     buffer.  Once the last A row has been driven, a_valid goes low
//     and we just wait for the array's pipeline to flush — c_valid will
//     keep firing until all MMU_M C rows have been captured.
//   * c_capture_count tracks captures.  When it reaches MMU_M, we move
//     on to STORE_C.
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_control
  import mmu_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,    // sync, active high

  // AXI-Lite control plane from the host (via the static region)
  axi_if.slave                              s_axil,

  // Load engine A
  output logic                              load_a_start,
  output logic [HBM_ADDR_W-1:0]             load_a_addr,
  input  logic                              load_a_done,

  // Load engine B
  output logic                              load_b_start,
  output logic [HBM_ADDR_W-1:0]             load_b_addr,
  input  logic                              load_b_done,

  // Store engine C
  output logic                              store_c_start,
  output logic [HBM_ADDR_W-1:0]             store_c_addr,
  input  logic                              store_c_done,

  // BRAM read ports (driven by COMPUTE phase)
  output logic                              a_buf_rd_en,
  output logic [$clog2(MMU_M)-1:0]          a_buf_rd_addr,
  input  logic [MMU_K*IN_W-1:0]             a_buf_rd_data,

  output logic                              b_buf_rd_en,
  output logic [$clog2(MMU_K)-1:0]          b_buf_rd_addr,
  input  logic [MMU_N*IN_W-1:0]             b_buf_rd_data,

  // C buffer write port (capture from systolic array)
  output logic                              c_buf_wr_en,
  output logic [$clog2(MMU_M)-1:0]          c_buf_wr_addr,
  output logic [MMU_N*ACC_W-1:0]            c_buf_wr_data,

  // Systolic array control (drives w_load and a_valid; receives c_valid)
  output logic                              w_load_en,
  output logic [$clog2(MMU_K)-1:0]          w_load_row,
  output logic signed [MMU_N-1:0][IN_W-1:0] w_load_data,

  output logic                              a_valid,
  output logic signed [MMU_K-1:0][IN_W-1:0] a_row_in,

  input  logic                              c_valid,
  input  logic signed [MMU_N-1:0][ACC_W-1:0] c_row_out
);

  // -----------------------------------------------------------------
  // Register file
  // -----------------------------------------------------------------
  localparam int NUM_REGS = 12;

  logic [NUM_REGS-1:0][31:0] reg_out;
  logic [NUM_REGS-1:0][31:0] reg_in;
  logic [NUM_REGS-1:0]       reg_wr;

  axil_reg_map #(
    .NUM_REGS  (NUM_REGS)
  ) u_regs (
    .s_axil    (s_axil),
    .reg_out   (reg_out),
    .reg_in    (reg_in),
    .reg_wr    (reg_wr)
  );

  // CMD reg: bit 0 is software-set, bit 31 is hardware-set.  Loopback
  // for everyone else.
  logic fsm_done;
  always_comb begin
    reg_in[0]  = {fsm_done, 30'b0, 1'b0};   // host reads back done in bit 31
    reg_in[1]  = reg_out[1];                // STATUS — loopback for now
    reg_in[2]  = reg_out[2];                // M
    reg_in[3]  = reg_out[3];                // N
    reg_in[4]  = reg_out[4];                // K
    reg_in[5]  = reg_out[5];                // A_ADDR_L
    reg_in[6]  = reg_out[6];                // A_ADDR_H
    reg_in[7]  = reg_out[7];                // B_ADDR_L
    reg_in[8]  = reg_out[8];                // B_ADDR_H
    reg_in[9]  = reg_out[9];                // C_ADDR_L
    reg_in[10] = reg_out[10];               // C_ADDR_H
    reg_in[11] = reg_out[11];               // SCRATCH
  end

  // Decode the 64-bit addresses into convenience locals
  wire [63:0] a_addr_full = {reg_out[6], reg_out[5]};
  wire [63:0] b_addr_full = {reg_out[8], reg_out[7]};
  wire [63:0] c_addr_full = {reg_out[10], reg_out[9]};

  // Detect a software write of bit 0 of CMD as the "start" trigger
  wire start_pulse = reg_wr[0] && reg_out[0][0];

  // -----------------------------------------------------------------
  // Top FSM
  // -----------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_LOAD_AB,
    S_COMPUTE,
    S_STORE_C,
    S_DONE
  } state_t;
  state_t state;

  // Compute sub-FSM
  typedef enum logic [1:0] {
    C_IDLE,
    C_LOAD_W,
    C_STREAM_A
  } compute_state_t;
  compute_state_t cstate;

  // Counters used during the COMPUTE phase
  logic [$clog2(MMU_K+2)-1:0] w_load_cnt;     // 0..MMU_K
  logic [$clog2(MMU_M+2)-1:0] a_stream_cnt;   // 0..MMU_M
  logic [$clog2(MMU_M+2)-1:0] c_capture_cnt;  // 0..MMU_M

  // Pipeline registers for the BRAM read → array drive (1-cycle delay)
  logic                              w_drive_valid;
  logic [$clog2(MMU_K)-1:0]          w_drive_row;
  logic                              a_drive_valid;

  // -----------------------------------------------------------------
  // Sequential
  // -----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state          <= S_IDLE;
      cstate         <= C_IDLE;
      load_a_start   <= 1'b0;
      load_b_start   <= 1'b0;
      store_c_start  <= 1'b0;
      load_a_addr    <= '0;
      load_b_addr    <= '0;
      store_c_addr   <= '0;
      fsm_done       <= 1'b0;

      a_buf_rd_en    <= 1'b0;
      a_buf_rd_addr  <= '0;
      b_buf_rd_en    <= 1'b0;
      b_buf_rd_addr  <= '0;

      w_load_cnt     <= '0;
      a_stream_cnt   <= '0;
      c_capture_cnt  <= '0;

      w_drive_valid  <= 1'b0;
      w_drive_row    <= '0;
      a_drive_valid  <= 1'b0;
    end else begin
      // Defaults — pulses
      a_buf_rd_en   <= 1'b0;
      b_buf_rd_en   <= 1'b0;
      w_drive_valid <= 1'b0;
      a_drive_valid <= 1'b0;

      case (state)
        // -----------------------------------------------------------
        S_IDLE: begin
          fsm_done <= 1'b0;
          if (start_pulse) begin
            load_a_addr  <= a_addr_full;
            load_b_addr  <= b_addr_full;
            store_c_addr <= c_addr_full;
            load_a_start <= 1'b1;
            load_b_start <= 1'b1;
            state        <= S_LOAD_AB;
          end
        end

        // -----------------------------------------------------------
        S_LOAD_AB: begin
          if (load_a_done && load_b_done) begin
            // Drop the engine starts so they return to IDLE
            load_a_start  <= 1'b0;
            load_b_start  <= 1'b0;
            // Begin the COMPUTE phase
            cstate        <= C_LOAD_W;
            w_load_cnt    <= '0;
            a_stream_cnt  <= '0;
            c_capture_cnt <= '0;
            state         <= S_COMPUTE;
          end
        end

        // -----------------------------------------------------------
        S_COMPUTE: begin
          // Track c_valid pulses and count captures
          if (c_valid) c_capture_cnt <= c_capture_cnt + 1'b1;

          case (cstate)
            // ----- weight load: K BRAM reads → K array writes -----
            C_LOAD_W: begin
              if (w_load_cnt < MMU_K[$bits(w_load_cnt)-1:0]) begin
                b_buf_rd_en   <= 1'b1;
                b_buf_rd_addr <= w_load_cnt[$clog2(MMU_K)-1:0];
                w_drive_row   <= w_load_cnt[$clog2(MMU_K)-1:0];
                w_drive_valid <= 1'b1;
                w_load_cnt    <= w_load_cnt + 1'b1;
              end else begin
                cstate <= C_STREAM_A;
              end
            end

            // ----- activation stream + capture -----
            C_STREAM_A: begin
              if (a_stream_cnt < MMU_M[$bits(a_stream_cnt)-1:0]) begin
                a_buf_rd_en   <= 1'b1;
                a_buf_rd_addr <= a_stream_cnt[$clog2(MMU_M)-1:0];
                a_drive_valid <= 1'b1;
                a_stream_cnt  <= a_stream_cnt + 1'b1;
              end
              // Compute is done once every C row has been captured
              if (c_capture_cnt == MMU_M[$bits(c_capture_cnt)-1:0]) begin
                cstate         <= C_IDLE;
                store_c_start  <= 1'b1;
                state          <= S_STORE_C;
              end
            end

            default: cstate <= C_IDLE;
          endcase
        end

        // -----------------------------------------------------------
        S_STORE_C: begin
          if (store_c_done) begin
            store_c_start <= 1'b0;
            state         <= S_DONE;
          end
        end

        // -----------------------------------------------------------
        S_DONE: begin
          fsm_done <= 1'b1;
          // Auto-return to IDLE so the next start_pulse can fire.
          // (The CMD register's done bit is read directly off fsm_done.)
          if (start_pulse) begin
            fsm_done <= 1'b0;
            state    <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // -----------------------------------------------------------------
  // Drive the systolic array.
  //
  // BRAM read latency is 1 cycle, so the array sees w_load / a_valid
  // one cycle after we issue the BRAM read.  The *_drive_valid /
  // w_drive_row registers are the 1-cycle delayed view of the issue,
  // and the BRAM data appears on the same cycle they're high.
  // -----------------------------------------------------------------
  assign w_load_en   = w_drive_valid;
  assign w_load_row  = w_drive_row;
  assign w_load_data = b_buf_rd_data;

  assign a_valid     = a_drive_valid;
  assign a_row_in    = a_buf_rd_data;

  // -----------------------------------------------------------------
  // C capture into the C buffer
  //
  // The systolic array's c_valid pulse is a 1-per-row indication that
  // c_row_out holds a complete row of the result.  We just route it
  // straight into the C buffer write port and let a small counter
  // generate the BRAM address.
  // -----------------------------------------------------------------
  logic [$clog2(MMU_M)-1:0] c_wr_addr_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      c_wr_addr_q <= '0;
    end else if (state == S_LOAD_AB && load_a_done && load_b_done) begin
      // Reset the C write address as we're about to start the compute
      c_wr_addr_q <= '0;
    end else if (c_valid) begin
      c_wr_addr_q <= c_wr_addr_q + 1'b1;
    end
  end

  assign c_buf_wr_en   = c_valid;
  assign c_buf_wr_addr = c_wr_addr_q;
  assign c_buf_wr_data = c_row_out;

endmodule : mmu_control
