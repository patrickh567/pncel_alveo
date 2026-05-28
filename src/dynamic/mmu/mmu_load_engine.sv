// *************************************************************************
//
// MMU load engine — HBM AXI4 read → BRAM staging buffer.
//
// Used twice in the MMU:
//   * to load matrix A from HBM into the A buffer (NUM_ROWS = MMU_M)
//   * to load matrix B from HBM into the B buffer (NUM_ROWS = MMU_K)
//
// Single-row interface: software hands the engine a 64-bit base address,
// asserts `start`, and the engine issues `NUM_ROWS` HBM read bursts,
// packing the returning HBM beats (HBM_DATA_W bits each) into one
// `BUF_WIDTH`-bit BRAM word per row.  When the last BRAM word is
// committed, `done` rises and stays high until `start` drops.
//
// One row per burst → ARLEN = (BUF_WIDTH/HBM_DATA_W) − 1.  For the
// design-wide values (BUF_WIDTH = 512, HBM_DATA_W = 256) that's a
// 2-beat burst per row.  The row builder accumulates the leading beats
// in a register and combines them with the final beat at RLAST time.
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_load_engine
  import mmu_pkg::*;
#(
  parameter int NUM_ROWS  = MMU_M,
  parameter int BUF_WIDTH = MMU_K * IN_W      // = 512 for 64×8
) (
  input  logic                              clk,
  input  logic                              rst,        // sync, active high

  // Command / status
  input  logic                              start,
  input  logic [HBM_ADDR_W-1:0]             base_addr,
  output logic                              done,

  // AXI4 master to one HBM port
  axi_if.master                             m_axi_hbm,

  // BRAM write port (one row of A or B per pulse)
  output logic                              bram_we,
  output logic [$clog2(NUM_ROWS)-1:0]       bram_addr,
  output logic [BUF_WIDTH-1:0]              bram_data
);

  // -----------------------------------------------------------------
  // Sizing / derived constants
  // -----------------------------------------------------------------
  localparam int BEATS_PER_ROW = BUF_WIDTH / HBM_DATA_W;
  localparam int BYTES_PER_ROW = BUF_WIDTH / 8;

  // -----------------------------------------------------------------
  // FSM
  // -----------------------------------------------------------------
  typedef enum logic [1:0] { S_IDLE, S_AR, S_R, S_DONE } state_t;
  state_t state;

  logic [$clog2(NUM_ROWS):0]      row_idx;       // 0..NUM_ROWS
  logic [$clog2(BEATS_PER_ROW)+1:0] beat_in_row; // 0..BEATS_PER_ROW
  logic [BUF_WIDTH-1:0]           row_builder;
  logic [HBM_ADDR_W-1:0]          cur_addr;

  // -----------------------------------------------------------------
  // AXI master signal drives — combinational defaults + per-state overrides
  // -----------------------------------------------------------------
  always_comb begin
    // Write channels are unused on the load path
    m_axi_hbm.awid     = '0;
    m_axi_hbm.awaddr   = '0;
    m_axi_hbm.awlen    = '0;
    m_axi_hbm.awsize   = '0;
    m_axi_hbm.awburst  = '0;
    m_axi_hbm.awlock   = '0;
    m_axi_hbm.awcache  = '0;
    m_axi_hbm.awprot   = '0;
    m_axi_hbm.awqos    = '0;
    m_axi_hbm.awregion = '0;
    m_axi_hbm.awvalid  = 1'b0;
    m_axi_hbm.wdata    = '0;
    m_axi_hbm.wstrb    = '0;
    m_axi_hbm.wlast    = 1'b0;
    m_axi_hbm.wvalid   = 1'b0;
    m_axi_hbm.bready   = 1'b1;

    // Read channel
    m_axi_hbm.arid     = '0;
    m_axi_hbm.araddr   = cur_addr;
    m_axi_hbm.arlen    = HBM_LEN_W'(BEATS_PER_ROW - 1);
    m_axi_hbm.arsize   = 3'b101;     // log2(32 bytes)
    m_axi_hbm.arburst  = 2'b01;      // INCR
    m_axi_hbm.arlock   = '0;
    m_axi_hbm.arcache  = 4'b0011;
    m_axi_hbm.arprot   = '0;
    m_axi_hbm.arqos    = '0;
    m_axi_hbm.arregion = '0;
    m_axi_hbm.arvalid  = (state == S_AR);
    m_axi_hbm.rready   = (state == S_R);
  end

  // -----------------------------------------------------------------
  // Sequential
  // -----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= S_IDLE;
      row_idx     <= '0;
      beat_in_row <= '0;
      row_builder <= '0;
      cur_addr    <= '0;
      done        <= 1'b0;
      bram_we     <= 1'b0;
      bram_addr   <= '0;
      bram_data   <= '0;
    end else begin
      bram_we <= 1'b0;     // default — pulsed when a row is committed

      case (state)
        S_IDLE: begin
          done <= 1'b0;
          if (start) begin
            row_idx     <= '0;
            beat_in_row <= '0;
            cur_addr    <= base_addr;
            state       <= S_AR;
          end
        end

        S_AR: begin
          if (m_axi_hbm.arready) begin
            beat_in_row <= '0;
            state       <= S_R;
          end
        end

        S_R: begin
          if (m_axi_hbm.rvalid) begin
            if (m_axi_hbm.rlast) begin
              // Final beat of the burst — assemble and commit the row.
              // The leading beats live in row_builder[BUF_WIDTH-HBM_DATA_W-1:0];
              // this beat occupies the top HBM_DATA_W bits of the BRAM word.
              bram_we   <= 1'b1;
              bram_addr <= row_idx[$clog2(NUM_ROWS)-1:0];
              bram_data <= {m_axi_hbm.rdata,
                            row_builder[BUF_WIDTH-HBM_DATA_W-1:0]};

              row_idx     <= row_idx + 1'b1;
              cur_addr    <= cur_addr + BYTES_PER_ROW;
              beat_in_row <= '0;

              if (row_idx == NUM_ROWS - 1) begin
                state <= S_DONE;
              end else begin
                state <= S_AR;
              end
            end else begin
              // Mid-burst beat — stash into the row builder
              row_builder[beat_in_row * HBM_DATA_W +: HBM_DATA_W]
                          <= m_axi_hbm.rdata;
              beat_in_row <= beat_in_row + 1'b1;
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

endmodule : mmu_load_engine
