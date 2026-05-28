// *************************************************************************
//
// AXI4-Lite interface definition
//
// *************************************************************************
`timescale 1ns/1ps
interface axi_lite_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32
) (
  input logic aclk,
  input logic aresetn
);

  localparam int STRB_W = DATA_W / 8;

  // Write address channel
  logic [ADDR_W-1:0] awaddr;
  logic        [2:0] awprot;
  logic              awvalid;
  logic              awready;

  // Write data channel
  logic [DATA_W-1:0] wdata;
  logic [STRB_W-1:0] wstrb;
  logic              wvalid;
  logic              wready;

  // Write response channel
  logic        [1:0] bresp;
  logic              bvalid;
  logic              bready;

  // Read address channel
  logic [ADDR_W-1:0] araddr;
  logic        [2:0] arprot;
  logic              arvalid;
  logic              arready;

  // Read data channel
  logic [DATA_W-1:0] rdata;
  logic        [1:0] rresp;
  logic              rvalid;
  logic              rready;

  modport master (
    input  aclk, aresetn,
    output awaddr, awprot, awvalid,
    input  awready,
    output wdata, wstrb, wvalid,
    input  wready,
    input  bresp, bvalid,
    output bready,
    output araddr, arprot, arvalid,
    input  arready,
    input  rdata, rresp, rvalid,
    output rready
  );

  modport slave (
    input  aclk, aresetn,
    input  awaddr, awprot, awvalid,
    output awready,
    input  wdata, wstrb, wvalid,
    output wready,
    output bresp, bvalid,
    input  bready,
    input  araddr, arprot, arvalid,
    output arready,
    output rdata, rresp, rvalid,
    input  rready
  );

endinterface: axi_lite_if
