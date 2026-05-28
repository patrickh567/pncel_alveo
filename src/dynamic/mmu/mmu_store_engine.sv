// *************************************************************************
//
// MMU store engine — BRAM read → HBM AXI4 write.
//
// Mirror of `mmu_load_engine`.  Used to write the C buffer (rows of
// int32 partial-sums) back to HBM after a compute completes.
//
// One AXI write burst per row.  ARLEN = (BUF_WIDTH/HBM_DATA_W) − 1.
// For C (BUF_WIDTH = 2048, HBM_DATA_W = 256) that's an 8-beat burst.
//
// Sequence per row:
//   1. Pre-issue a BRAM read for the current row index (bram_re pulse).
//   2. Drive AW with the row's HBM base address; wait for AWREADY.
//      The BRAM has produced its data by the next cycle — capture it
//      into `row_data`.
//   3. Stream the row through the W channel one HBM beat at a time
//      (slice `row_data` by `beat_in_row * HBM_DATA_W`).  Assert
//      WLAST on the final beat.
//   4. Wait for BVALID.
//   5. Bump the row counter.  If more rows remain, pre-issue the next
//      BRAM read and loop back to step 2.  Otherwise → DONE.
//
// `done` rises once the final BVALID has been observed and stays high
// until `start` drops.
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_store_engine
  import mmu_pkg::*;
#(
  parameter int NUM_ROWS  = MMU_M,
  parameter int BUF_WIDTH = MMU_N * ACC_W       // 2048 for 64 × int32
) (
  input  logic                              clk,
  input  logic                              rst,        // sync, active high

  // Command / status
  input  logic                              start,
  input  logic [HBM_ADDR_W-1:0]             base_addr,
  output logic                              done,

  // AXI4 master to one HBM port
  axi_if.master                             m_axi_hbm,

  // BRAM read port (single-cycle registered read)
  output logic                              bram_re,
  output logic [$clog2(NUM_ROWS)-1:0]       bram_addr,
  input  logic [BUF_WIDTH-1:0]              bram_rdata
);

  // -----------------------------------------------------------------
  // Sizing
  // -----------------------------------------------------------------
  localparam int BEATS_PER_ROW = BUF_WIDTH / HBM_DATA_W;
  localparam int BYTES_PER_ROW = BUF_WIDTH / 8;

  // -----------------------------------------------------------------
  // FSM
  // -----------------------------------------------------------------
  typedef enum logic [2:0] { S_IDLE, S_AW, S_W, S_B, S_DONE } state_t;
  state_t state;

  logic [$clog2(NUM_ROWS):0]        row_idx;
  logic [$clog2(BEATS_PER_ROW)+1:0] beat_in_row;
  logic [BUF_WIDTH-1:0]             row_data;
  logic [HBM_ADDR_W-1:0]            cur_addr;

  // -----------------------------------------------------------------
  // AXI master signal drives
  // -----------------------------------------------------------------
  always_comb begin
    // Read channel unused
    m_axi_hbm.arid     = '0;
    m_axi_hbm.araddr   = '0;
    m_axi_hbm.arlen    = '0;
    m_axi_hbm.arsize   = '0;
    m_axi_hbm.arburst  = '0;
    m_axi_hbm.arlock   = '0;
    m_axi_hbm.arcache  = '0;
    m_axi_hbm.arprot   = '0;
    m_axi_hbm.arqos    = '0;
    m_axi_hbm.arregion = '0;
    m_axi_hbm.arvalid  = 1'b0;
    m_axi_hbm.rready   = 1'b1;

    // Write address
    m_axi_hbm.awid     = '0;
    m_axi_hbm.awaddr   = cur_addr;
    m_axi_hbm.awlen    = HBM_LEN_W'(BEATS_PER_ROW - 1);
    m_axi_hbm.awsize   = 3'b101;     // log2(32 bytes)
    m_axi_hbm.awburst  = 2'b01;      // INCR
    m_axi_hbm.awlock   = '0;
    m_axi_hbm.awcache  = 4'b0011;
    m_axi_hbm.awprot   = '0;
    m_axi_hbm.awqos    = '0;
    m_axi_hbm.awregion = '0;
    m_axi_hbm.awvalid  = (state == S_AW);

    // Write data — slice the latched row by the current beat index
    m_axi_hbm.wdata    = row_data[beat_in_row * HBM_DATA_W +: HBM_DATA_W];
    m_axi_hbm.wstrb    = {(HBM_DATA_W/8){1'b1}};
    m_axi_hbm.wlast    = (beat_in_row == BEATS_PER_ROW - 1);
    m_axi_hbm.wvalid   = (state == S_W);

    // Write response
    m_axi_hbm.bready   = (state == S_B);
  end

  // -----------------------------------------------------------------
  // Sequential
  // -----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= S_IDLE;
      row_idx     <= '0;
      beat_in_row <= '0;
      row_data    <= '0;
      cur_addr    <= '0;
      done        <= 1'b0;
      bram_re     <= 1'b0;
      bram_addr   <= '0;
    end else begin
      bram_re <= 1'b0;     // default — pulsed during pre-fetch transitions

      case (state)
        S_IDLE: begin
          done <= 1'b0;
          if (start) begin
            row_idx     <= '0;
            beat_in_row <= '0;
            cur_addr    <= base_addr;
            // Pre-issue first BRAM read so its data lines up with S_W.
            bram_re   <= 1'b1;
            bram_addr <= '0;
            state     <= S_AW;
          end
        end

        S_AW: begin
          if (m_axi_hbm.awready) begin
            row_data    <= bram_rdata;   // captured one cycle after bram_re
            beat_in_row <= '0;
            state       <= S_W;
          end
        end

        S_W: begin
          if (m_axi_hbm.wready) begin
            if (beat_in_row == BEATS_PER_ROW - 1) begin
              state <= S_B;
            end else begin
              beat_in_row <= beat_in_row + 1'b1;
            end
          end
        end

        S_B: begin
          if (m_axi_hbm.bvalid) begin
            row_idx  <= row_idx + 1'b1;
            cur_addr <= cur_addr + BYTES_PER_ROW;

            if (row_idx == NUM_ROWS - 1) begin
              state <= S_DONE;
            end else begin
              // Pre-issue the next BRAM read
              bram_re   <= 1'b1;
              bram_addr <= row_idx[$clog2(NUM_ROWS)-1:0] + 1'b1;
              state     <= S_AW;
            end
          end
        end

        S_DONE: begin
          done <= 1'b1;
          if (!start) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule : mmu_store_engine
