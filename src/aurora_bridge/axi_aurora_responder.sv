// *************************************************************************
//
// axi_aurora_responder -- Aurora <-> AXI responder (slave-end bridge).
//
// Receives AW/W/AR command packets over the Aurora interface, drives them
// onto one of two downstream AXI master ports (Full or Lite) based on the
// per-transaction `lite` flag, then captures the B/R responses from those
// slaves and packetizes them back over Aurora.
//
// Internally wraps:
//   axi_depacketizer  -- RX demux to Full / Lite master AW/W/AR
//   axi_packetizer    -- B + R-Full (chunked) + B-Lite + R-Lite packetizer
//
// Fork wiring (done internally): each slave B/R response is consumed by
// both the depacketizer (FSM advance) and the packetizer (relay). The
// slave's bready/rready come from the packetizer; the depacketizer sees
// the slave-valid gated by the packetizer's ready so its FSM only
// advances when the response was actually captured for relay.
//
// Aurora stream layout (matches the rest of the design):
//   data TX     -- chunked R-Full (only, this module's R output)
//   data RX     -- chunked W with embedded AW (shared with the master end's
//                  aurora_r_receiver via rx_in_cont_* cross-gating)
//   user-K TX   -- B + B-Lite + R-Lite (single-flit packets)
//   user-K RX   -- AR (single-flit packets)
//
// *************************************************************************
`timescale 1ns/1ps
module axi_aurora_responder #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  // ---------------- Aurora data TX (chunked R-Full) ----------------------
  output wire [255:0]            tx_data_tdata,
  output wire [31:0]             tx_data_tkeep,
  output wire                    tx_data_tlast,
  output wire                    tx_data_tvalid,
  input  wire                    tx_data_tready,

  // ---------------- Aurora data RX (chunked W with AW header) ------------
  input  wire [255:0]            rx_data_tdata,
  input  wire [31:0]             rx_data_tkeep,
  input  wire                    rx_data_tvalid,
  // Cross-gating with other consumers of the same data RX wire
  // (e.g. aurora_r_receiver on the master end).
  output wire                    rx_data_in_cont_o,
  input  wire                    rx_data_in_cont_i,

  // ---------------- Aurora user-K TX (B + B-Lite + R-Lite) ---------------
  output wire [255:0]            tx_userk_tdata,
  output wire                    tx_userk_tvalid,
  input  wire                    tx_userk_tready,

  // ---------------- Aurora user-K RX (AR single-flit) --------------------
  input  wire [255:0]            rx_userk_tdata,
  input  wire                    rx_userk_tvalid,

  // ---------------- AXI-Full master port (lite=0 transactions) -----------
  // AW
  output wire [ID_W-1:0]         m_full_awid,
  output wire [ADDR_W-1:0]       m_full_awaddr,
  output wire [7:0]              m_full_awlen,
  output wire [2:0]              m_full_awsize,
  output wire [1:0]              m_full_awburst,
  output wire [3:0]              m_full_awcache,
  output wire [2:0]              m_full_awprot,
  output wire                    m_full_awvalid,
  input  wire                    m_full_awready,
  // W
  output wire [DATA_W-1:0]       m_full_wdata,
  output wire [DATA_W/8-1:0]     m_full_wstrb,
  output wire                    m_full_wlast,
  output wire                    m_full_wvalid,
  input  wire                    m_full_wready,
  // B
  input  wire [ID_W-1:0]         m_full_bid,
  input  wire [1:0]              m_full_bresp,
  input  wire                    m_full_bvalid,
  output wire                    m_full_bready,
  // AR
  output wire [ID_W-1:0]         m_full_arid,
  output wire [ADDR_W-1:0]       m_full_araddr,
  output wire [7:0]              m_full_arlen,
  output wire [2:0]              m_full_arsize,
  output wire [1:0]              m_full_arburst,
  output wire [3:0]              m_full_arcache,
  output wire [2:0]              m_full_arprot,
  output wire                    m_full_arvalid,
  input  wire                    m_full_arready,
  // R
  input  wire [ID_W-1:0]         m_full_rid,
  input  wire [DATA_W-1:0]       m_full_rdata,
  input  wire [1:0]              m_full_rresp,
  input  wire                    m_full_rlast,
  input  wire                    m_full_rvalid,
  output wire                    m_full_rready,

  // ---------------- AXI-Lite master port (lite=1 transactions) -----------
  // AW
  output wire [ADDR_W-1:0]       m_lite_awaddr,
  output wire [2:0]              m_lite_awprot,
  output wire                    m_lite_awvalid,
  input  wire                    m_lite_awready,
  // W
  output wire [DATA_W-1:0]       m_lite_wdata,
  output wire [DATA_W/8-1:0]     m_lite_wstrb,
  output wire                    m_lite_wvalid,
  input  wire                    m_lite_wready,
  // B
  input  wire [1:0]              m_lite_bresp,
  input  wire                    m_lite_bvalid,
  output wire                    m_lite_bready,
  // AR
  output wire [ADDR_W-1:0]       m_lite_araddr,
  output wire [2:0]              m_lite_arprot,
  output wire                    m_lite_arvalid,
  input  wire                    m_lite_arready,
  // R
  input  wire [DATA_W-1:0]       m_lite_rdata,
  input  wire [1:0]              m_lite_rresp,
  input  wire                    m_lite_rvalid,
  output wire                    m_lite_rready
);

  // -- Packetizer ready outputs (drive both slave's *ready and the
  //    depacketizer's gated *valid inputs)
  wire pkt_b_full_ready;
  wire pkt_r_full_ready;
  wire pkt_b_lite_ready;
  wire pkt_r_lite_ready;

  // Fork pattern: the slave's *ready comes from the packetizer; the
  // depacketizer sees *valid only when the packetizer is also accepting,
  // so its FSM advances on the same cycle the packetizer captures the
  // response. (The depacketizer's own m_*_bready/rready outputs are tied
  // to 1 inside the depacketizer; we leave them dangling here.)
  assign m_full_bready = pkt_b_full_ready;
  assign m_full_rready = pkt_r_full_ready;
  assign m_lite_bready = pkt_b_lite_ready;
  assign m_lite_rready = pkt_r_lite_ready;

  wire dep_full_bvalid = m_full_bvalid & pkt_b_full_ready;
  wire dep_full_rvalid = m_full_rvalid & pkt_r_full_ready;
  wire dep_lite_bvalid = m_lite_bvalid & pkt_b_lite_ready;
  wire dep_lite_rvalid = m_lite_rvalid & pkt_r_lite_ready;

  axi_depacketizer #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) u_depacketizer (
    .aclk           (aclk),
    .aresetn        (aresetn),

    // Aurora data RX (chunked W with AW header)
    .rx_data_tdata  (rx_data_tdata),
    .rx_data_tkeep  (rx_data_tkeep),
    .rx_data_tvalid (rx_data_tvalid),
    .rx_in_cont_o   (rx_data_in_cont_o),
    .rx_in_cont_i   (rx_data_in_cont_i),

    // Aurora user-K RX (AR)
    .rx_userk_tdata  (rx_userk_tdata),
    .rx_userk_tvalid (rx_userk_tvalid),

    // AXI-Full master port (AW/W out, B/R gated in)
    .m_full_awid    (m_full_awid),
    .m_full_awaddr  (m_full_awaddr),
    .m_full_awlen   (m_full_awlen),
    .m_full_awsize  (m_full_awsize),
    .m_full_awburst (m_full_awburst),
    .m_full_awcache (m_full_awcache),
    .m_full_awprot  (m_full_awprot),
    .m_full_awvalid (m_full_awvalid),
    .m_full_awready (m_full_awready),
    .m_full_wdata   (m_full_wdata),
    .m_full_wstrb   (m_full_wstrb),
    .m_full_wlast   (m_full_wlast),
    .m_full_wvalid  (m_full_wvalid),
    .m_full_wready  (m_full_wready),
    .m_full_bid     (m_full_bid),
    .m_full_bresp   (m_full_bresp),
    .m_full_bvalid  (dep_full_bvalid),
    .m_full_bready  (),                  // tied=1 internally; packetizer drives slave bready
    .m_full_arid    (m_full_arid),
    .m_full_araddr  (m_full_araddr),
    .m_full_arlen   (m_full_arlen),
    .m_full_arsize  (m_full_arsize),
    .m_full_arburst (m_full_arburst),
    .m_full_arcache (m_full_arcache),
    .m_full_arprot  (m_full_arprot),
    .m_full_arvalid (m_full_arvalid),
    .m_full_arready (m_full_arready),
    .m_full_rid     (m_full_rid),
    .m_full_rdata   (m_full_rdata),
    .m_full_rresp   (m_full_rresp),
    .m_full_rlast   (m_full_rlast),
    .m_full_rvalid  (dep_full_rvalid),
    .m_full_rready  (),

    // AXI-Lite master port (AW/W out, B/R gated in)
    .m_lite_awaddr  (m_lite_awaddr),
    .m_lite_awprot  (m_lite_awprot),
    .m_lite_awvalid (m_lite_awvalid),
    .m_lite_awready (m_lite_awready),
    .m_lite_wdata   (m_lite_wdata),
    .m_lite_wstrb   (m_lite_wstrb),
    .m_lite_wvalid  (m_lite_wvalid),
    .m_lite_wready  (m_lite_wready),
    .m_lite_bresp   (m_lite_bresp),
    .m_lite_bvalid  (dep_lite_bvalid),
    .m_lite_bready  (),
    .m_lite_araddr  (m_lite_araddr),
    .m_lite_arprot  (m_lite_arprot),
    .m_lite_arvalid (m_lite_arvalid),
    .m_lite_arready (m_lite_arready),
    .m_lite_rdata   (m_lite_rdata),
    .m_lite_rresp   (m_lite_rresp),
    .m_lite_rvalid  (dep_lite_rvalid),
    .m_lite_rready  ()
  );

  axi_packetizer #(
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) u_packetizer (
    .aclk         (aclk),
    .aresetn      (aresetn),

    // B-Full input (snooped from slave; ready drives slave's bready)
    .b_full_id    (m_full_bid),
    .b_full_resp  (m_full_bresp),
    .b_full_valid (m_full_bvalid),
    .b_full_ready (pkt_b_full_ready),

    // R-Full input (per AXI R beat)
    .r_full_id    (m_full_rid),
    .r_full_data  (m_full_rdata),
    .r_full_resp  (m_full_rresp),
    .r_full_last  (m_full_rlast),
    .r_full_valid (m_full_rvalid),
    .r_full_ready (pkt_r_full_ready),

    // B-Lite input
    .b_lite_resp  (m_lite_bresp),
    .b_lite_valid (m_lite_bvalid),
    .b_lite_ready (pkt_b_lite_ready),

    // R-Lite input
    .r_lite_data  (m_lite_rdata),
    .r_lite_resp  (m_lite_rresp),
    .r_lite_valid (m_lite_rvalid),
    .r_lite_ready (pkt_r_lite_ready),

    // Aurora data TX (chunked R-Full only)
    .tx_data_tdata  (tx_data_tdata),
    .tx_data_tkeep  (tx_data_tkeep),
    .tx_data_tlast  (tx_data_tlast),
    .tx_data_tvalid (tx_data_tvalid),
    .tx_data_tready (tx_data_tready),

    // Aurora user-K TX (B + B-Lite + R-Lite, internally arbitrated)
    .tx_userk_tdata  (tx_userk_tdata),
    .tx_userk_tvalid (tx_userk_tvalid),
    .tx_userk_tready (tx_userk_tready)
  );

endmodule
