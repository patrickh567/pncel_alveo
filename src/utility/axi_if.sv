// *************************************************************************
//
// AXI4 (full) interface definition
//
// *************************************************************************
`timescale 1ns/1ps
interface axi_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 64,
  parameter int ID_W   = 4,
  parameter int LEN_W  = 8
) (
  input logic aclk,
  input logic aresetn
);

  localparam int STRB_W = DATA_W / 8;

  // Write address channel
  logic   [ID_W-1:0] awid;
  logic [ADDR_W-1:0] awaddr;
  logic  [LEN_W-1:0] awlen;
  logic        [2:0] awsize;
  logic        [1:0] awburst;
  logic              awlock;
  logic        [3:0] awcache;
  logic        [2:0] awprot;
  logic        [3:0] awqos;
  logic        [3:0] awregion;
  logic              awvalid;
  logic              awready;

  // Write data channel
  logic [DATA_W-1:0] wdata;
  logic [STRB_W-1:0] wstrb;
  logic              wlast;
  logic              wvalid;
  logic              wready;

  // Write response channel
  logic   [ID_W-1:0] bid;
  logic        [1:0] bresp;
  logic              bvalid;
  logic              bready;

  // Read address channel
  logic   [ID_W-1:0] arid;
  logic [ADDR_W-1:0] araddr;
  logic  [LEN_W-1:0] arlen;
  logic        [2:0] arsize;
  logic        [1:0] arburst;
  logic              arlock;
  logic        [3:0] arcache;
  logic        [2:0] arprot;
  logic        [3:0] arqos;
  logic        [3:0] arregion;
  logic              arvalid;
  logic              arready;

  // Read data channel
  logic   [ID_W-1:0] rid;
  logic [DATA_W-1:0] rdata;
  logic        [1:0] rresp;
  logic              rlast;
  logic              rvalid;
  logic              rready;

  modport master (
    input  aclk, aresetn,
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awvalid,
    input  awready,
    output wdata, wstrb, wlast, wvalid,
    input  wready,
    input  bid, bresp, bvalid,
    output bready,
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, arvalid,
    input  arready,
    input  rid, rdata, rresp, rlast, rvalid,
    output rready
  );

  modport slave (
    input  aclk, aresetn,
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awvalid,
    output awready,
    input  wdata, wstrb, wlast, wvalid,
    output wready,
    output bid, bresp, bvalid,
    input  bready,
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, arvalid,
    output arready,
    output rid, rdata, rresp, rlast, rvalid,
    input  rready
  );

endinterface: axi_if
