// *************************************************************************
//
// Generic write-port + read-port BRAM
//
// Single-clock simple dual-port memory: one write address with byte/word
// data, one read address with single-cycle registered output.  Vivado
// infers Block RAM (or URAM if MEMORY_SIZE warrants it) from this
// idiomatic always_ff pattern.
//
// Used by the MMU's A / B / C staging buffers.  Sizes (M = N = K = 64,
// IN_W = 8, ACC_W = 32):
//
//   A buffer : WIDTH = 512  (64 × int8),  DEPTH = 64
//   B buffer : WIDTH = 512  (64 × int8),  DEPTH = 64
//   C buffer : WIDTH = 2048 (64 × int32), DEPTH = 64
//
// *************************************************************************
`timescale 1ns/1ps
module mmu_bram_2p #(
  parameter int WIDTH = 512,
  parameter int DEPTH = 64
) (
  input  logic                       clk,
  // Write port
  input  logic                       wr_en,
  input  logic [$clog2(DEPTH)-1:0]   wr_addr,
  input  logic [WIDTH-1:0]           wr_data,
  // Read port (1-cycle latency)
  input  logic                       rd_en,
  input  logic [$clog2(DEPTH)-1:0]   rd_addr,
  output logic [WIDTH-1:0]           rd_data
);

  logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    if (rd_en) rd_data <= mem[rd_addr];
  end

endmodule : mmu_bram_2p
