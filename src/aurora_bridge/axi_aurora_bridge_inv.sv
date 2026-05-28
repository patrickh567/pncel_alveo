// *************************************************************************
//
// axi_aurora_bridge_inv -- inverse of axi_aurora_bridge for the other
// end of the Aurora link.
//
// Where the FPGA-side `axi_aurora_bridge` has:
//   1 AXI4-Full SLAVE  port  (cache adapter drives in)
//   2 AXI    MASTER ports    (Full + Lite, drives downstream slaves)
//
// the inverse bridge has:
//   2 AXI    SLAVE  ports    (Full + Lite, host initiators drive in)
//   1 AXI4-Full MASTER port  (drives the local memory)
//
// Internally:
//   axi_to_aurora           -- handles the Full slave port (lite=0 traffic)
//   axi_lite_to_aurora      -- handles the Lite slave port (lite=1 traffic)
//   aurora_r_receiver       -- chunked R-Full responses for the Full slave
//   axi_aurora_responder    -- AW/W/AR coming from the far end -> drives
//                              the local memory master (the responder's
//                              Lite master port is dangling because the
//                              far end's bridge only ever ships lite=0)
//   data-TX arbiter         -- chunked W (Full) vs chunked W (Lite) vs
//                              chunked R-Full responses (responder),
//                              frame-atomic via tlast
//   user-K TX arbiter       -- AR (Full) vs AR (Lite) vs B/B-Lite/R-Lite
//                              from the responder; all single-flit
//   data RX cross-gating    -- aurora_r_receiver (R cont) vs responder
//                              depacketizer (W cont) -- exact mirror of
//                              the FPGA-side bridge
//
// Channel allocation (same protocol as axi_aurora_bridge):
//   data    interface : chunked W (with AW header), chunked R-Full
//   user-K  interface : AR + B + B-Lite + R-Lite (all single-flit)
//
// *************************************************************************
`timescale 1ns/1ps
module axi_aurora_bridge_inv #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  // ============================ AXI4-Full slave port =====================
  input  wire [ID_W-1:0]         s_full_awid,
  input  wire [ADDR_W-1:0]       s_full_awaddr,
  input  wire [7:0]              s_full_awlen,
  input  wire [2:0]              s_full_awsize,
  input  wire [1:0]              s_full_awburst,
  input  wire [3:0]              s_full_awcache,
  input  wire [2:0]              s_full_awprot,
  input  wire                    s_full_awvalid,
  output wire                    s_full_awready,
  input  wire [DATA_W-1:0]       s_full_wdata,
  input  wire [DATA_W/8-1:0]     s_full_wstrb,
  input  wire                    s_full_wlast,
  input  wire                    s_full_wvalid,
  output wire                    s_full_wready,
  output wire [ID_W-1:0]         s_full_bid,
  output wire [1:0]              s_full_bresp,
  output wire                    s_full_bvalid,
  input  wire                    s_full_bready,
  input  wire [ID_W-1:0]         s_full_arid,
  input  wire [ADDR_W-1:0]       s_full_araddr,
  input  wire [7:0]              s_full_arlen,
  input  wire [2:0]              s_full_arsize,
  input  wire [1:0]              s_full_arburst,
  input  wire [3:0]              s_full_arcache,
  input  wire [2:0]              s_full_arprot,
  input  wire                    s_full_arvalid,
  output wire                    s_full_arready,
  output wire [ID_W-1:0]         s_full_rid,
  output wire [DATA_W-1:0]       s_full_rdata,
  output wire [1:0]              s_full_rresp,
  output wire                    s_full_rlast,
  output wire                    s_full_rvalid,
  input  wire                    s_full_rready,

  // ============================ AXI-Lite slave port ======================
  input  wire [ADDR_W-1:0]       s_lite_awaddr,
  input  wire [2:0]              s_lite_awprot,
  input  wire                    s_lite_awvalid,
  output wire                    s_lite_awready,
  input  wire [DATA_W-1:0]       s_lite_wdata,
  input  wire [DATA_W/8-1:0]     s_lite_wstrb,
  input  wire                    s_lite_wvalid,
  output wire                    s_lite_wready,
  output wire [1:0]              s_lite_bresp,
  output wire                    s_lite_bvalid,
  input  wire                    s_lite_bready,
  input  wire [ADDR_W-1:0]       s_lite_araddr,
  input  wire [2:0]              s_lite_arprot,
  input  wire                    s_lite_arvalid,
  output wire                    s_lite_arready,
  output wire [DATA_W-1:0]       s_lite_rdata,
  output wire [1:0]              s_lite_rresp,
  output wire                    s_lite_rvalid,
  input  wire                    s_lite_rready,

  // ============================ AXI4-Full master port (to local memory) ==
  output wire [ID_W-1:0]         m_awid,
  output wire [ADDR_W-1:0]       m_awaddr,
  output wire [7:0]              m_awlen,
  output wire [2:0]              m_awsize,
  output wire [1:0]              m_awburst,
  output wire [3:0]              m_awcache,
  output wire [2:0]              m_awprot,
  output wire                    m_awvalid,
  input  wire                    m_awready,
  output wire [DATA_W-1:0]       m_wdata,
  output wire [DATA_W/8-1:0]     m_wstrb,
  output wire                    m_wlast,
  output wire                    m_wvalid,
  input  wire                    m_wready,
  input  wire [ID_W-1:0]         m_bid,
  input  wire [1:0]              m_bresp,
  input  wire                    m_bvalid,
  output wire                    m_bready,
  output wire [ID_W-1:0]         m_arid,
  output wire [ADDR_W-1:0]       m_araddr,
  output wire [7:0]              m_arlen,
  output wire [2:0]              m_arsize,
  output wire [1:0]              m_arburst,
  output wire [3:0]              m_arcache,
  output wire [2:0]              m_arprot,
  output wire                    m_arvalid,
  input  wire                    m_arready,
  input  wire [ID_W-1:0]         m_rid,
  input  wire [DATA_W-1:0]       m_rdata,
  input  wire [1:0]              m_rresp,
  input  wire                    m_rlast,
  input  wire                    m_rvalid,
  output wire                    m_rready,

  // ======================== Aurora user-side streams =====================
  output wire [255:0]            tx_data_tdata,
  output wire [31:0]             tx_data_tkeep,
  output wire                    tx_data_tlast,
  output wire                    tx_data_tvalid,
  input  wire                    tx_data_tready,

  input  wire [255:0]            rx_data_tdata,
  input  wire [31:0]             rx_data_tkeep,
  input  wire                    rx_data_tlast,
  input  wire                    rx_data_tvalid,

  output wire [255:0]            tx_userk_tdata,
  output wire                    tx_userk_tvalid,
  input  wire                    tx_userk_tready,

  input  wire [255:0]            rx_userk_tdata,
  input  wire                    rx_userk_tvalid
);

  // ===== Per-source TX outputs (pre-arbitration) =====
  // axi_to_aurora (Full slave)
  wire [255:0] ato_full_tx_data_tdata;
  wire [31:0]  ato_full_tx_data_tkeep;
  wire         ato_full_tx_data_tlast;
  wire         ato_full_tx_data_tvalid;
  wire         ato_full_tx_data_tready;
  wire [255:0] ato_full_tx_userk_tdata;
  wire         ato_full_tx_userk_tvalid;
  wire         ato_full_tx_userk_tready;

  // axi_lite_to_aurora (Lite slave)
  wire [255:0] ato_lite_tx_data_tdata;
  wire [31:0]  ato_lite_tx_data_tkeep;
  wire         ato_lite_tx_data_tlast;
  wire         ato_lite_tx_data_tvalid;
  wire         ato_lite_tx_data_tready;
  wire [255:0] ato_lite_tx_userk_tdata;
  wire         ato_lite_tx_userk_tvalid;
  wire         ato_lite_tx_userk_tready;

  // axi_aurora_responder (incoming AW/W/AR -> local memory; sends B/R back)
  wire [255:0] resp_tx_data_tdata;
  wire [31:0]  resp_tx_data_tkeep;
  wire         resp_tx_data_tlast;
  wire         resp_tx_data_tvalid;
  wire         resp_tx_data_tready;
  wire [255:0] resp_tx_userk_tdata;
  wire         resp_tx_userk_tvalid;
  wire         resp_tx_userk_tready;

  // Cross-gating between R receiver (R cont) and responder (W cont) on data RX
  wire rrx_in_cont;
  wire dep_in_cont;

  // =========================================================================
  // axi_to_aurora -- handles the Full slave port (lite=0 traffic)
  // =========================================================================
  axi_to_aurora #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) u_axi_to_aurora_full (
    .aclk    (aclk),
    .aresetn (aresetn),

    .s_awid    (s_full_awid),
    .s_awaddr  (s_full_awaddr),
    .s_awlen   (s_full_awlen),
    .s_awsize  (s_full_awsize),
    .s_awburst (s_full_awburst),
    .s_awcache (s_full_awcache),
    .s_awprot  (s_full_awprot),
    .s_aw_lite (1'b0),                // hardwired: this instance is Full
    .s_awvalid (s_full_awvalid),
    .s_awready (s_full_awready),
    .s_wdata   (s_full_wdata),
    .s_wstrb   (s_full_wstrb),
    .s_wlast   (s_full_wlast),
    .s_wvalid  (s_full_wvalid),
    .s_wready  (s_full_wready),
    .s_bid     (s_full_bid),
    .s_bresp   (s_full_bresp),
    .s_bvalid  (s_full_bvalid),
    .s_bready  (s_full_bready),
    .s_arid    (s_full_arid),
    .s_araddr  (s_full_araddr),
    .s_arlen   (s_full_arlen),
    .s_arsize  (s_full_arsize),
    .s_arburst (s_full_arburst),
    .s_arcache (s_full_arcache),
    .s_arprot  (s_full_arprot),
    .s_ar_lite (1'b0),
    .s_arvalid (s_full_arvalid),
    .s_arready (s_full_arready),
    .s_rid     (),                    // R for Full comes from aurora_r_receiver
    .s_rdata   (),
    .s_rresp   (),
    .s_rlast   (),
    .s_rvalid  (),
    .s_rready  (1'b1),

    .tx_data_tdata  (ato_full_tx_data_tdata),
    .tx_data_tkeep  (ato_full_tx_data_tkeep),
    .tx_data_tlast  (ato_full_tx_data_tlast),
    .tx_data_tvalid (ato_full_tx_data_tvalid),
    .tx_data_tready (ato_full_tx_data_tready),

    .tx_userk_tdata  (ato_full_tx_userk_tdata),
    .tx_userk_tvalid (ato_full_tx_userk_tvalid),
    .tx_userk_tready (ato_full_tx_userk_tready),

    // user-K RX is shared with axi_lite_to_aurora and the responder; each
    // decodes its own opcode, so no chunked-stream cross-gating is needed.
    .rx_tdata     (rx_userk_tdata),
    .rx_tvalid    (rx_userk_tvalid),
    .rx_in_cont_i (1'b0)
  );

  // =========================================================================
  // aurora_r_receiver -- chunked R-Full response for the Full slave
  // =========================================================================
  aurora_r_receiver #(
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) u_aurora_r_rx (
    .aclk         (aclk),
    .aresetn      (aresetn),

    .rx_tdata     (rx_data_tdata),
    .rx_tkeep     (rx_data_tkeep),
    .rx_tlast     (rx_data_tlast),
    .rx_tvalid    (rx_data_tvalid),
    .rx_in_cont_o (rrx_in_cont),
    .rx_in_cont_i (dep_in_cont),

    .m_rid        (s_full_rid),
    .m_rdata      (s_full_rdata),
    .m_rresp      (s_full_rresp),
    .m_rlast      (s_full_rlast),
    .m_rvalid     (s_full_rvalid),
    .m_rready     (s_full_rready)
  );

  // =========================================================================
  // axi_lite_to_aurora -- handles the Lite slave port (lite=1 traffic).
  //   B-Lite and R-Lite responses arrive on user-K RX inside this module.
  // =========================================================================
  axi_lite_to_aurora #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) u_axi_to_aurora_lite (
    .aclk    (aclk),
    .aresetn (aresetn),

    .s_awaddr  (s_lite_awaddr),
    .s_awprot  (s_lite_awprot),
    .s_awvalid (s_lite_awvalid),
    .s_awready (s_lite_awready),
    .s_wdata   (s_lite_wdata),
    .s_wstrb   (s_lite_wstrb),
    .s_wvalid  (s_lite_wvalid),
    .s_wready  (s_lite_wready),
    .s_bresp   (s_lite_bresp),
    .s_bvalid  (s_lite_bvalid),
    .s_bready  (s_lite_bready),
    .s_araddr  (s_lite_araddr),
    .s_arprot  (s_lite_arprot),
    .s_arvalid (s_lite_arvalid),
    .s_arready (s_lite_arready),
    .s_rdata   (s_lite_rdata),
    .s_rresp   (s_lite_rresp),
    .s_rvalid  (s_lite_rvalid),
    .s_rready  (s_lite_rready),

    .tx_data_tdata  (ato_lite_tx_data_tdata),
    .tx_data_tkeep  (ato_lite_tx_data_tkeep),
    .tx_data_tlast  (ato_lite_tx_data_tlast),
    .tx_data_tvalid (ato_lite_tx_data_tvalid),
    .tx_data_tready (ato_lite_tx_data_tready),

    .tx_userk_tdata  (ato_lite_tx_userk_tdata),
    .tx_userk_tvalid (ato_lite_tx_userk_tvalid),
    .tx_userk_tready (ato_lite_tx_userk_tready),

    .rx_userk_tdata  (rx_userk_tdata),
    .rx_userk_tvalid (rx_userk_tvalid)
  );

  // =========================================================================
  // axi_aurora_responder -- incoming AW/W/AR (from FPGA cache adapter) ->
  // local memory master. The far end only sends lite=0, so the responder's
  // m_lite_* master port is left dangling.
  // =========================================================================
  axi_aurora_responder #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W),
    .ID_W   (ID_W)
  ) u_axi_aurora_responder (
    .aclk    (aclk),
    .aresetn (aresetn),

    .tx_data_tdata  (resp_tx_data_tdata),
    .tx_data_tkeep  (resp_tx_data_tkeep),
    .tx_data_tlast  (resp_tx_data_tlast),
    .tx_data_tvalid (resp_tx_data_tvalid),
    .tx_data_tready (resp_tx_data_tready),

    .rx_data_tdata     (rx_data_tdata),
    .rx_data_tkeep     (rx_data_tkeep),
    .rx_data_tvalid    (rx_data_tvalid),
    .rx_data_in_cont_o (dep_in_cont),
    .rx_data_in_cont_i (rrx_in_cont),

    .tx_userk_tdata  (resp_tx_userk_tdata),
    .tx_userk_tvalid (resp_tx_userk_tvalid),
    .tx_userk_tready (resp_tx_userk_tready),

    .rx_userk_tdata  (rx_userk_tdata),
    .rx_userk_tvalid (rx_userk_tvalid),

    // ---- AXI-Full master to local memory ----
    .m_full_awid    (m_awid),
    .m_full_awaddr  (m_awaddr),
    .m_full_awlen   (m_awlen),
    .m_full_awsize  (m_awsize),
    .m_full_awburst (m_awburst),
    .m_full_awcache (m_awcache),
    .m_full_awprot  (m_awprot),
    .m_full_awvalid (m_awvalid),
    .m_full_awready (m_awready),
    .m_full_wdata   (m_wdata),
    .m_full_wstrb   (m_wstrb),
    .m_full_wlast   (m_wlast),
    .m_full_wvalid  (m_wvalid),
    .m_full_wready  (m_wready),
    .m_full_bid     (m_bid),
    .m_full_bresp   (m_bresp),
    .m_full_bvalid  (m_bvalid),
    .m_full_bready  (m_bready),
    .m_full_arid    (m_arid),
    .m_full_araddr  (m_araddr),
    .m_full_arlen   (m_arlen),
    .m_full_arsize  (m_arsize),
    .m_full_arburst (m_arburst),
    .m_full_arcache (m_arcache),
    .m_full_arprot  (m_arprot),
    .m_full_arvalid (m_arvalid),
    .m_full_arready (m_arready),
    .m_full_rid     (m_rid),
    .m_full_rdata   (m_rdata),
    .m_full_rresp   (m_rresp),
    .m_full_rlast   (m_rlast),
    .m_full_rvalid  (m_rvalid),
    .m_full_rready  (m_rready),

    // ---- AXI-Lite master port -- dangling; the far end never sends lite=1 ----
    .m_lite_awaddr  (), .m_lite_awprot (), .m_lite_awvalid(), .m_lite_awready(1'b1),
    .m_lite_wdata   (), .m_lite_wstrb  (), .m_lite_wvalid (), .m_lite_wready (1'b1),
    .m_lite_bresp   (2'b00), .m_lite_bvalid (1'b0), .m_lite_bready (),
    .m_lite_araddr  (), .m_lite_arprot (), .m_lite_arvalid(), .m_lite_arready(1'b1),
    .m_lite_rdata   ({DATA_W{1'b0}}),
    .m_lite_rresp   (2'b00),
    .m_lite_rvalid  (1'b0),
    .m_lite_rready  ()
  );

  // =========================================================================
  // Data-TX arbiter: chunked W (Full slave) vs chunked W (Lite slave) vs
  // chunked R-Full responses (responder). Frame-atomic via tlast.
  // Fixed priority: Full W > Lite W > R-Full response.
  // =========================================================================
  typedef enum logic [1:0] {
    ATX_IDLE,
    ATX_W_FULL,
    ATX_W_LITE,
    ATX_R_RESP
  } atx_state_e;

  atx_state_e atx_state_r, atx_state_n;

  always_comb begin
    atx_state_n = atx_state_r;
    case (atx_state_r)
      ATX_IDLE:
        if      (ato_full_tx_data_tvalid) atx_state_n = ATX_W_FULL;
        else if (ato_lite_tx_data_tvalid) atx_state_n = ATX_W_LITE;
        else if (resp_tx_data_tvalid)     atx_state_n = ATX_R_RESP;
      ATX_W_FULL:
        if (ato_full_tx_data_tvalid & ato_full_tx_data_tready & ato_full_tx_data_tlast)
          atx_state_n = ATX_IDLE;
      ATX_W_LITE:
        if (ato_lite_tx_data_tvalid & ato_lite_tx_data_tready & ato_lite_tx_data_tlast)
          atx_state_n = ATX_IDLE;
      ATX_R_RESP:
        if (resp_tx_data_tvalid & resp_tx_data_tready & resp_tx_data_tlast)
          atx_state_n = ATX_IDLE;
      default:
        atx_state_n = ATX_IDLE;
    endcase
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) atx_state_r <= ATX_IDLE;
    else          atx_state_r <= atx_state_n;
  end

  assign tx_data_tdata  = (atx_state_r == ATX_W_FULL) ? ato_full_tx_data_tdata
                        : (atx_state_r == ATX_W_LITE) ? ato_lite_tx_data_tdata
                        : (atx_state_r == ATX_R_RESP) ? resp_tx_data_tdata
                        : 256'b0;
  assign tx_data_tkeep  = (atx_state_r == ATX_W_FULL) ? ato_full_tx_data_tkeep
                        : (atx_state_r == ATX_W_LITE) ? ato_lite_tx_data_tkeep
                        : (atx_state_r == ATX_R_RESP) ? resp_tx_data_tkeep
                        : 32'h0;
  assign tx_data_tlast  = (atx_state_r == ATX_W_FULL) ? ato_full_tx_data_tlast
                        : (atx_state_r == ATX_W_LITE) ? ato_lite_tx_data_tlast
                        : (atx_state_r == ATX_R_RESP) ? resp_tx_data_tlast
                        : 1'b0;
  assign tx_data_tvalid = (atx_state_r == ATX_W_FULL) ? ato_full_tx_data_tvalid
                        : (atx_state_r == ATX_W_LITE) ? ato_lite_tx_data_tvalid
                        : (atx_state_r == ATX_R_RESP) ? resp_tx_data_tvalid
                        : 1'b0;

  assign ato_full_tx_data_tready = (atx_state_r == ATX_W_FULL) & tx_data_tready;
  assign ato_lite_tx_data_tready = (atx_state_r == ATX_W_LITE) & tx_data_tready;
  assign resp_tx_data_tready     = (atx_state_r == ATX_R_RESP) & tx_data_tready;

  // =========================================================================
  // User-K TX arbiter: 3 single-flit sources (AR Full, AR Lite, responder).
  // Fixed priority Full AR > Lite AR > responder.
  // =========================================================================
  wire utx_full_sel = ato_full_tx_userk_tvalid;
  wire utx_lite_sel = ~utx_full_sel & ato_lite_tx_userk_tvalid;
  wire utx_resp_sel = ~utx_full_sel & ~utx_lite_sel & resp_tx_userk_tvalid;

  assign tx_userk_tdata  = utx_full_sel ? ato_full_tx_userk_tdata
                         : utx_lite_sel ? ato_lite_tx_userk_tdata
                         : utx_resp_sel ? resp_tx_userk_tdata
                         : 256'b0;
  assign tx_userk_tvalid = utx_full_sel | utx_lite_sel | utx_resp_sel;

  assign ato_full_tx_userk_tready = utx_full_sel & tx_userk_tready;
  assign ato_lite_tx_userk_tready = utx_lite_sel & tx_userk_tready;
  assign resp_tx_userk_tready     = utx_resp_sel & tx_userk_tready;

endmodule
