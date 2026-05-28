// *************************************************************************
//
// axi_lite_to_aurora -- AXI-Lite <-> Aurora packet bridge (requester end).
//
// Mirrors axi_to_aurora but for an AXI-Lite slave port. AXI-Lite is
// always single-beat, single-outstanding, no transaction IDs, no burst,
// so this is a trimmed-down version of the Full variant.
//
// Sends on Aurora:
//   data TX  : chunked W frame (header flit with OP_AW + AW metadata
//              + lite=1 + the single W beat's bytes; tlast=1 on that
//              one flit). One flit per write transaction.
//   user-K TX: single-flit AR packet with lite=1.
//
// Receives on Aurora:
//   user-K RX: OP_B_LITE single-flit -> s_b*
//              OP_R_LITE single-flit -> s_r* (with single rdata beat)
//
// id is parameterized only to keep the packet format identical to the
// Full path; ar_id / aw_id are always sent as 0 (AXI-Lite has no id).
//
// *************************************************************************
`timescale 1ns/1ps
module axi_lite_to_aurora #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  // ---------------- AXI-Lite slave port ----------------------------------
  input  wire [ADDR_W-1:0]       s_awaddr,
  input  wire [2:0]              s_awprot,
  input  wire                    s_awvalid,
  output wire                    s_awready,

  input  wire [DATA_W-1:0]       s_wdata,
  input  wire [DATA_W/8-1:0]     s_wstrb,
  input  wire                    s_wvalid,
  output wire                    s_wready,

  output wire [1:0]              s_bresp,
  output wire                    s_bvalid,
  input  wire                    s_bready,

  input  wire [ADDR_W-1:0]       s_araddr,
  input  wire [2:0]              s_arprot,
  input  wire                    s_arvalid,
  output wire                    s_arready,

  output wire [DATA_W-1:0]       s_rdata,
  output wire [1:0]              s_rresp,
  output wire                    s_rvalid,
  input  wire                    s_rready,

  // ---------------- Aurora data TX (chunked W with AW header) ------------
  output wire [255:0]            tx_data_tdata,
  output wire [31:0]             tx_data_tkeep,
  output wire                    tx_data_tlast,
  output wire                    tx_data_tvalid,
  input  wire                    tx_data_tready,

  // ---------------- Aurora user-K TX (AR single-flit) --------------------
  output wire [255:0]            tx_userk_tdata,
  output wire                    tx_userk_tvalid,
  input  wire                    tx_userk_tready,

  // ---------------- Aurora user-K RX (B-Lite + R-Lite single-flit) ------
  input  wire [255:0]            rx_userk_tdata,
  input  wire                    rx_userk_tvalid
);

  localparam int STRB_W              = DATA_W / 8;
  // AXI-Lite payload is 32-bit per spec; the wrapper's DATA_W (which can be
  // up to the AXI-Full data width, e.g. 512) is wider so the bridge's lite
  // and full master ports share a parameter, but only the bottom
  // LITE_PKT_DATA_W bits are meaningful on the wire.
  localparam int LITE_PKT_DATA_W     = 32;
  localparam int LITE_PKT_STRB_W     = LITE_PKT_DATA_W / 8;
  localparam int LITE_W              = 1;
  localparam int R_RESP_W            = 2;
  localparam int HDR_AW_W            = 8 + ID_W + ADDR_W + 8 + 3 + 2 + 4 + 3 + LITE_W;
  localparam int HDR_DATA_OFFSET     = ((HDR_AW_W + 7) / 8) * 8;
  localparam int HDR_DATA_OFFSET_B   = HDR_DATA_OFFSET / 8;
  localparam int HDR_PAD_W           = HDR_DATA_OFFSET - HDR_AW_W;
  localparam int HDR_DATA_BYTES      = (256 - HDR_DATA_OFFSET) / 8;

  localparam logic [7:0] OP_AW       = 8'h10;
  localparam logic [7:0] OP_AR       = 8'h13;
  localparam logic [7:0] OP_B_LITE   = 8'h16;
  localparam logic [7:0] OP_R_LITE   = 8'h17;

  // Fixed AXI-Lite "constants" -- the bridge ships these in the packet
  // headers so the responder sees a well-formed transaction with lite=1.
  localparam logic [ID_W-1:0]  LITE_ID    = '0;
  localparam logic [7:0]       LITE_LEN   = 8'd0;
  // LITE_SIZE must reflect the actual lite payload width (LITE_PKT_DATA_W),
  // not the wrapper's wider DATA_W. The depacketizer derives "bytes per
  // beat" from this — if it's 6 (=64B) when only 4 bytes are sent, the
  // depacketizer stalls forever waiting for cont flits and its
  // rx_in_cont_o stays asserted, cross-gating off the R receiver.
  localparam logic [2:0]       LITE_SIZE  = $clog2(LITE_PKT_STRB_W);
  localparam logic [1:0]       LITE_BURST = 2'b01;     // INCR
  localparam logic [3:0]       LITE_CACHE = 4'b0000;

  // -------------------------------------------------------------------------
  // WRITE PATH
  //   IDLE   : wait for s_aw + s_w (we need both to compose the single flit)
  //   TX_HDR : drive the one chunked-W flit on data TX
  //   WAIT_B : wait for B-Lite response on user-K RX
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_W_IDLE,
    S_W_TX_HDR,
    S_W_WAIT_B
  } write_state_e;

  write_state_e w_state_r, w_state_n;

  logic [ADDR_W-1:0]   aw_addr_r;
  logic [2:0]          aw_prot_r;
  logic [DATA_W-1:0]   w_data_r;
  logic [STRB_W-1:0]   w_strb_r;

  // B inbound staging (1-deep)
  logic                b_pending_r;
  logic [1:0]          b_resp_r;

  // Header flit: AW metadata (lite=1) + W data bytes. Only the bottom
  // LITE_PKT_DATA_W bits of w_data_r/w_strb_r ride the wire; the upper
  // bits (present only because the wrapper shares DATA_W with the full
  // path) are dropped here.
  wire [255:0] hdr_pkt = {
      {(256 - HDR_DATA_OFFSET - LITE_PKT_DATA_W){1'b0}},
      w_data_r[LITE_PKT_DATA_W-1:0],
      {HDR_PAD_W{1'b0}},
      1'b1,                           // lite
      aw_prot_r,
      LITE_CACHE,
      LITE_BURST,
      LITE_SIZE,
      LITE_LEN,
      aw_addr_r,
      LITE_ID,
      OP_AW
  };

  wire [31:0] hdr_tkeep = {
      {(32 - HDR_DATA_OFFSET_B - LITE_PKT_STRB_W){1'b0}}, // trailing pad bytes invalid
      w_strb_r[LITE_PKT_STRB_W-1:0],                      // strb for valid W bytes
      {HDR_DATA_OFFSET_B{1'b1}}                           // metadata bytes always valid
  };

  always_comb begin
    w_state_n = w_state_r;
    case (w_state_r)
      S_W_IDLE:    if (s_awvalid & s_wvalid)             w_state_n = S_W_TX_HDR;
      S_W_TX_HDR:  if (tx_data_tvalid & tx_data_tready)  w_state_n = S_W_WAIT_B;
      S_W_WAIT_B:  if (s_bvalid & s_bready)              w_state_n = S_W_IDLE;
      default:                                           w_state_n = S_W_IDLE;
    endcase
  end

  // Latch AW + W together (must accept both on the same cycle so we have
  // the data ready for the single header flit).
  assign s_awready = (w_state_r == S_W_IDLE) & s_wvalid;
  assign s_wready  = (w_state_r == S_W_IDLE) & s_awvalid;

  assign tx_data_tdata  = hdr_pkt;
  assign tx_data_tkeep  = hdr_tkeep;
  assign tx_data_tlast  = 1'b1;                  // single-flit W frame
  assign tx_data_tvalid = (w_state_r == S_W_TX_HDR);

  // -------------------------------------------------------------------------
  // READ PATH
  // -------------------------------------------------------------------------
  typedef enum logic [0:0] {
    S_R_IDLE,
    S_R_TX_AR
  } read_state_e;

  read_state_e r_state_r, r_state_n;

  logic [ADDR_W-1:0]   ar_addr_r;
  logic [2:0]          ar_prot_r;

  // R inbound staging (1-deep)
  logic                       r_pending_r;
  logic [1:0]                 r_resp_r;
  logic [LITE_PKT_DATA_W-1:0] r_data_r;

  // AR packet (single flit, lite=1)
  wire [255:0] ar_pkt = {
      {(256 - HDR_AW_W){1'b0}},
      1'b1,                           // lite
      ar_prot_r,
      LITE_CACHE,
      LITE_BURST,
      LITE_SIZE,
      LITE_LEN,
      ar_addr_r,
      LITE_ID,
      OP_AR
  };

  always_comb begin
    r_state_n = r_state_r;
    case (r_state_r)
      S_R_IDLE:   if (s_arvalid)                              r_state_n = S_R_TX_AR;
      S_R_TX_AR:  if (tx_userk_tvalid & tx_userk_tready)      r_state_n = S_R_IDLE;
      default:                                                r_state_n = S_R_IDLE;
    endcase
  end

  assign s_arready       = (r_state_r == S_R_IDLE);
  assign tx_userk_tdata  = ar_pkt;
  assign tx_userk_tvalid = (r_state_r == S_R_TX_AR);

  // -------------------------------------------------------------------------
  // RX decode (B-Lite + R-Lite single-flit on user-K)
  // -------------------------------------------------------------------------
  wire [7:0]            rx_op       = rx_userk_tdata[7:0];
  wire [1:0]            rx_bl_resp  = rx_userk_tdata[8 +: 2];
  wire [1:0]            rx_rl_resp  = rx_userk_tdata[8 +: 2];
  wire [LITE_PKT_DATA_W-1:0] rx_rl_data = rx_userk_tdata[8 + 2 +: LITE_PKT_DATA_W];

  wire bl_rx_fire = rx_userk_tvalid & (rx_op == OP_B_LITE);
  wire rl_rx_fire = rx_userk_tvalid & (rx_op == OP_R_LITE);

  // -------------------------------------------------------------------------
  // Sequential state
  // -------------------------------------------------------------------------
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      w_state_r   <= S_W_IDLE;
      r_state_r   <= S_R_IDLE;
      b_pending_r <= 1'b0;
      r_pending_r <= 1'b0;
    end else begin
      w_state_r <= w_state_n;
      r_state_r <= r_state_n;

      // Latch AW + W on the cycle they're accepted together
      if ((w_state_r == S_W_IDLE) & s_awvalid & s_wvalid) begin
        aw_addr_r <= s_awaddr;
        aw_prot_r <= s_awprot;
        w_data_r  <= s_wdata;
        w_strb_r  <= s_wstrb;
      end

      // Latch AR
      if ((r_state_r == S_R_IDLE) & s_arvalid) begin
        ar_addr_r <= s_araddr;
        ar_prot_r <= s_arprot;
      end

      // B inbound staging
      if (s_bvalid & s_bready) b_pending_r <= 1'b0;
      if (bl_rx_fire) begin
        b_pending_r <= 1'b1;
        b_resp_r    <= rx_bl_resp;
      end

      // R inbound staging
      if (s_rvalid & s_rready) r_pending_r <= 1'b0;
      if (rl_rx_fire) begin
        r_pending_r <= 1'b1;
        r_resp_r    <= rx_rl_resp;
        r_data_r    <= rx_rl_data;
      end
    end
  end

  assign s_bresp  = b_resp_r;
  assign s_bvalid = b_pending_r;

  assign s_rdata  = {{(DATA_W-LITE_PKT_DATA_W){1'b0}}, r_data_r};
  assign s_rresp  = r_resp_r;
  assign s_rvalid = r_pending_r;

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (aresetn) begin
      if (bl_rx_fire & b_pending_r & !(s_bvalid & s_bready))
        $warning("axi_lite_to_aurora: B-Lite overrun (previous B not consumed)");
      if (rl_rx_fire & r_pending_r & !(s_rvalid & s_rready))
        $warning("axi_lite_to_aurora: R-Lite overrun (previous R not consumed)");
    end
  end
`endif

endmodule
