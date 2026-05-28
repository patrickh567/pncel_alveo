// *************************************************************************
//
// APB (Advanced Peripheral Bus) interface definition
//
// *************************************************************************
`timescale 1ns/1ps
interface apb_if #(
  parameter int ADDR_W = 22,
  parameter int DATA_W = 32
) (
  input logic pclk,
  input logic preset_n
);

  logic [ADDR_W-1:0] paddr;
  logic               psel;
  logic               penable;
  logic               pwrite;
  logic [DATA_W-1:0] pwdata;
  logic [DATA_W-1:0] prdata;
  logic               pready;
  logic               pslverr;

  modport master (
    output paddr, psel, penable, pwrite, pwdata,
    input  prdata, pready, pslverr
  );

  modport slave (
    input  paddr, psel, penable, pwrite, pwdata,
    output prdata, pready, pslverr
  );

endinterface: apb_if
