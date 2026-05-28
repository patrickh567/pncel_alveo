// *************************************************************************
//
// axi_packetizer -- B/R response packetizer for AXI-Full + AXI-Lite slaves.
//
// Takes the B-channel and R-channel response streams from both an
// AXI-Full and an AXI-Lite slave, arbitrates them onto a single 256-bit
// Aurora-style TX stream (intended for the user-K TX side).
//
// Each input is a standard AXI valid/ready stream; the packetizer presents
// a 1-deep staging slot per single-flit source. The R-Full path is a true
// chunked-stream sender, byte-granular (mirrors axi_to_aurora's W path):
// AXI R beats from the slave are sliced into BYTES and packed into a
// header flit (OP_R + rid + rresp + byte-align pad + R data bytes)
// followed by N continuation flits (pure 32 R data bytes each). Per-byte
// validity is conveyed on `tkeep` so the receiver can distinguish real
// data from zero-padded trailing bytes in the final flit — no separate
// rlen field is needed in the header.
//
// Packet formats (tlast=1 on final flit; tkeep marks valid bytes):
//
//   B-Full      (OP_B,        0x12):  single flit -- {bresp[2], bid[ID_W], OP_B}
//   B-Lite      (OP_B_LITE,   0x16):  single flit -- {bresp[2], OP_B_LITE}
//   R-Lite      (OP_R_LITE,   0x17):  single flit -- {rdata[DATA_W], rresp[2], OP_R_LITE}
//   R-Full      (OP_R,        0x14):  byte-granular, multi-flit
//                 header  : {data_bytes, byte-align pad, rresp, rid, OP_R}
//                           tkeep: low R_HDR_META_OFFSET_B bits = 1 always
//                                  high bits = 1 per valid data byte
//                 cont    : {data_bytes}   (no opcode; dispatched by tlast state)
//                           tkeep: 1 per valid data byte
//                 tlast=1 marks the FINAL flit of the burst.
//
// Frame boundary on the data TX is signalled by `tlast=1` on the final
// flit. Combined with per-byte `tkeep`, this lets the receiver consume
// exactly (rlen+1)*STRB_W data bytes without accumulating residual.
// The packetizer mirrors `m_rlast` from the slave into a `last_seen`
// flag, exactly like the W sender mirrors `s_wlast`.
//
// Arbitration priority:
//   1. R-Full cont (committed; cont flits carry no opcode -- non-preemptible)
//   2. B-Full
//   3. B-Lite
//   4. R-Lite
//   5. R-Full hdr (starts a new committed stream)
//
// *************************************************************************
`timescale 1ns/1ps
module axi_packetizer #(
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire                aclk,
  input  wire                aresetn,

  // ---- B-Full input (single-flit) ----
  input  wire [ID_W-1:0]     b_full_id,
  input  wire [1:0]          b_full_resp,
  input  wire                b_full_valid,
  output wire                b_full_ready,

  // ---- R-Full input (per AXI R beat; goes into chunked sender) ----
  input  wire [ID_W-1:0]     r_full_id,
  input  wire [DATA_W-1:0]   r_full_data,
  input  wire [1:0]          r_full_resp,
  input  wire                r_full_last,
  input  wire                r_full_valid,
  output wire                r_full_ready,

  // ---- B-Lite input (single-flit) ----
  input  wire [1:0]          b_lite_resp,
  input  wire                b_lite_valid,
  output wire                b_lite_ready,

  // ---- R-Lite input (single beat per transaction) ----
  input  wire [DATA_W-1:0]   r_lite_data,
  input  wire [1:0]          r_lite_resp,
  input  wire                r_lite_valid,
  output wire                r_lite_ready,

  // ---- Aurora data TX: chunked R-Full ----
  //   tlast = 1 on FINAL flit of each chunked frame so the top-level
  //   arbiter can release the data channel.
  output wire [255:0]        tx_data_tdata,
  output wire [31:0]         tx_data_tkeep,
  output wire                tx_data_tlast,
  output wire                tx_data_tvalid,
  input  wire                tx_data_tready,

  // ---- Aurora user-K TX: B + B-Lite + R-Lite (single-flit packets) ----
  output wire [255:0]        tx_userk_tdata,
  output wire                tx_userk_tvalid,
  input  wire                tx_userk_tready
);

  localparam logic [7:0] OP_B        = 8'h12;
  localparam logic [7:0] OP_R        = 8'h14;
  localparam logic [7:0] OP_B_LITE   = 8'h16;
  localparam logic [7:0] OP_R_LITE   = 8'h17;

  // ---- Byte-granular R-Full geometry (mirrors axi_to_aurora's W path).
  //      All counts/positions in BYTES.  Matches aurora_r_receiver.
  localparam int STRB_W              = DATA_W / 8;                          // bytes per R beat (64 @ 512)
  // AXI-Lite R payload is 32-bit per spec; see axi_lite_to_aurora.sv for
  // rationale. The receiver (axi_lite_to_aurora) uses the same constant.
  localparam int LITE_PKT_DATA_W     = 32;
  localparam int R_RESP_W            = 2;
  localparam int R_HDR_META_W        = 8 + ID_W + R_RESP_W;                  // 30 @ ID_W=20
  // Byte-align the metadata so data starts on a byte boundary.
  localparam int R_HDR_META_OFFSET   = ((R_HDR_META_W + 7) / 8) * 8;         // 32 @ ID_W=20
  localparam int R_HDR_META_OFFSET_B = R_HDR_META_OFFSET / 8;                // 4 bytes
  localparam int R_HDR_PAD_W         = R_HDR_META_OFFSET - R_HDR_META_W;     // 2 bits
  localparam int R_HDR_DATA_BYTES    = (256 - R_HDR_META_OFFSET) / 8;        // 28 @ ID_W=20
  localparam int R_CONT_DATA_BYTES   = 32;                                   // 256/8
  // Buffer: hold one full cont flit + one beat's worth of slack.
  localparam int R_BUF_BYTES         = R_CONT_DATA_BYTES + STRB_W;
  localparam int R_BUF_W             = R_BUF_BYTES * 8;
  localparam int R_CNT_W             = $clog2(R_BUF_BYTES + 1);

  // ========================================================================
  // Single-flit staging (B-Full, B-Lite, R-Lite)
  // ========================================================================
  logic              bf_pend_r;
  logic [ID_W-1:0]   bf_id_r;
  logic [1:0]        bf_resp_r;

  logic              bl_pend_r;
  logic [1:0]        bl_resp_r;

  logic                       rl_pend_r;
  logic [LITE_PKT_DATA_W-1:0] rl_data_r;
  logic [1:0]                 rl_resp_r;

  assign b_full_ready = ~bf_pend_r;
  assign b_lite_ready = ~bl_pend_r;
  assign r_lite_ready = ~rl_pend_r;

  // ========================================================================
  // R-Full chunked sender
  // ========================================================================
  typedef enum logic [1:0] {
    S_RF_IDLE,      // no burst in progress
    S_RF_TX_HDR,    // accumulating; will emit header flit when ready
    S_RF_TX_CONT    // emitting continuation flits
  } rf_state_e;

  rf_state_e rf_state_r, rf_state_n;

  logic [ID_W-1:0]         rf_id_r;
  logic [R_RESP_W-1:0]     rf_resp_r;
  logic [R_BUF_W-1:0]      rf_buf_r;
  logic [R_CNT_W-1:0]      rf_count_r;       // valid bytes currently in rf_buf_r
  logic                    rf_last_seen_r;   // m_rlast was accepted

  // R-Full packet builders (LSB = oldest byte).  Header carries metadata
  // in the low R_HDR_META_OFFSET bits, then R_HDR_DATA_BYTES of data.
  wire [255:0] rf_hdr_pkt = {
      rf_buf_r[0 +: R_HDR_DATA_BYTES*8],     // 28 bytes for ID_W=20
      {R_HDR_PAD_W{1'b0}},                   // byte-align pad after metadata
      rf_resp_r,
      rf_id_r,
      OP_R
  };
  // Cont flit: 32 bytes of pure data (no padding because 32*8 = 256).
  wire [255:0] rf_cont_pkt = rf_buf_r[0 +: R_CONT_DATA_BYTES*8];

  // r_full_ready: accept whenever the buffer has room for another beat.
  // The FSM walks IDLE -> TX_HDR -> (TX_CONT)* -> IDLE driven entirely by
  // the local last_seen flag.
  wire rf_room     = (R_CNT_W'(rf_count_r) + R_CNT_W'(STRB_W))
                     <= R_CNT_W'(R_BUF_BYTES);
  assign r_full_ready = rf_room;

  wire rf_push = r_full_valid & r_full_ready;

  // Emit cap depends on whether we're sending header (with metadata) or cont
  wire [R_CNT_W-1:0] rf_flit_cap = (rf_state_r == S_RF_TX_HDR)
                                     ? R_CNT_W'(R_HDR_DATA_BYTES)
                                     : R_CNT_W'(R_CONT_DATA_BYTES);
  wire rf_active     = (rf_state_r == S_RF_TX_HDR) || (rf_state_r == S_RF_TX_CONT);
  wire rf_emit_ready = rf_active &&
                       ((rf_count_r >= rf_flit_cap) ||
                        (rf_last_seen_r && (rf_count_r > '0)));
  wire [R_CNT_W-1:0] rf_emit_n = (rf_count_r >= rf_flit_cap)
                                   ? rf_flit_cap : rf_count_r;

  // Final flit of the byte-granular R frame: this emit drains the buffer
  // AND the slave already gave us rlast.
  wire rf_tx_is_final = rf_last_seen_r && (rf_count_r == rf_emit_n);

  // tkeep: per-byte validity.
  //   hdr flit : tkeep[R_HDR_META_OFFSET_B-1:0]   = all-1 (metadata bytes)
  //              tkeep[R_HDR_META_OFFSET_B +: emit_n] = 1 (real data bytes)
  //              remaining high bits              = 0 (padding bytes)
  //   cont flit: tkeep[emit_n-1:0]                = 1 (real data bytes)
  //              tkeep[31:emit_n]                 = 0 (padding bytes)
  //
  // We compute a "data valid" mask LSB-aligned, then shift into place.
  wire [31:0] data_valid_mask =
      (rf_emit_n == R_CNT_W'(0)) ? 32'h0 : ((32'h1 << rf_emit_n) - 32'h1);

  wire [31:0] rf_hdr_tkeep = (data_valid_mask << R_HDR_META_OFFSET_B)
                           | ({32{1'b1}} >> (32 - R_HDR_META_OFFSET_B));
  wire [31:0] rf_cont_tkeep = data_valid_mask;

  // rf_emit_fire / single-flit fires are resolved by the TX arbiter (below)
  wire rf_emit_fire;
  wire tx_bf_fire, tx_bl_fire, tx_rl_fire;

  // ========================================================================
  // Single-flit packet builders
  // ========================================================================
  wire [255:0] bf_pkt = {
      {(256 - 8 - ID_W - 2){1'b0}},
      bf_resp_r, bf_id_r, OP_B
  };
  wire [255:0] bl_pkt = {
      {(256 - 8 - 2){1'b0}},
      bl_resp_r, OP_B_LITE
  };
  wire [255:0] rl_pkt = {
      {(256 - 8 - 2 - LITE_PKT_DATA_W){1'b0}},
      rl_data_r, rl_resp_r, OP_R_LITE
  };

  // ========================================================================
  // TX path split:
  //   tx_data : chunked R-Full only. tlast=1 on FINAL flit of the frame.
  //   tx_userk: arbiter for single-flit packets {B-Full > B-Lite > R-Lite}.
  // ========================================================================
  wire tx_rf_cont_want = (rf_state_r == S_RF_TX_CONT) & rf_emit_ready;
  wire tx_rf_hdr_want  = (rf_state_r == S_RF_TX_HDR)  & rf_emit_ready;
  wire tx_rf_want      = tx_rf_cont_want | tx_rf_hdr_want;

  assign tx_data_tdata  = tx_rf_hdr_want ? rf_hdr_pkt : rf_cont_pkt;
  assign tx_data_tkeep  = tx_rf_hdr_want ? rf_hdr_tkeep : rf_cont_tkeep;
  assign tx_data_tlast  = rf_tx_is_final;
  assign tx_data_tvalid = tx_rf_want;

  // User-K arbiter for the single-flit sources
  wire tx_bf_want = bf_pend_r;
  wire tx_bl_want = bl_pend_r;
  wire tx_rl_want = rl_pend_r;

  reg [255:0] userk_data_mux;
  reg         userk_valid_mux;
  reg         sel_bf, sel_bl, sel_rl;
  always_comb begin
    userk_data_mux  = '0;
    userk_valid_mux = 1'b0;
    sel_bf = 1'b0; sel_bl = 1'b0; sel_rl = 1'b0;
    if (tx_bf_want) begin
      userk_data_mux  = bf_pkt;
      userk_valid_mux = 1'b1;
      sel_bf          = 1'b1;
    end else if (tx_bl_want) begin
      userk_data_mux  = bl_pkt;
      userk_valid_mux = 1'b1;
      sel_bl          = 1'b1;
    end else if (tx_rl_want) begin
      userk_data_mux  = rl_pkt;
      userk_valid_mux = 1'b1;
      sel_rl          = 1'b1;
    end
  end

  assign tx_userk_tdata  = userk_data_mux;
  assign tx_userk_tvalid = userk_valid_mux;

  assign tx_bf_fire   = sel_bf & tx_userk_tready;
  assign tx_bl_fire   = sel_bl & tx_userk_tready;
  assign tx_rl_fire   = sel_rl & tx_userk_tready;
  assign rf_emit_fire = tx_rf_want & tx_data_tready;

  // ========================================================================
  // R-Full FSM (combinational next-state)
  // ========================================================================
  always_comb begin
    rf_state_n = rf_state_r;
    case (rf_state_r)
      S_RF_IDLE:
        if (rf_push) rf_state_n = S_RF_TX_HDR;
      S_RF_TX_HDR:
        if (rf_emit_fire) begin
          if (rf_tx_is_final)
            rf_state_n = S_RF_IDLE;
          else
            rf_state_n = S_RF_TX_CONT;
        end
      S_RF_TX_CONT:
        if (rf_emit_fire && rf_tx_is_final)
          rf_state_n = S_RF_IDLE;
      default:
        rf_state_n = S_RF_IDLE;
    endcase
  end

  // ========================================================================
  // Main always_ff: staging + R-Full state + buffer
  // ========================================================================
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      bf_pend_r      <= 1'b0;
      bl_pend_r      <= 1'b0;
      rl_pend_r      <= 1'b0;
      rf_state_r     <= S_RF_IDLE;
      rf_buf_r       <= '0;
      rf_count_r     <= '0;
      rf_last_seen_r <= 1'b0;
    end else begin
      rf_state_r <= rf_state_n;

      // ---- B-Full single-flit ----
      if (b_full_valid & b_full_ready) begin
        bf_pend_r <= 1'b1;
        bf_id_r   <= b_full_id;
        bf_resp_r <= b_full_resp;
      end
      if (tx_bf_fire) bf_pend_r <= 1'b0;

      // ---- B-Lite single-flit ----
      if (b_lite_valid & b_lite_ready) begin
        bl_pend_r <= 1'b1;
        bl_resp_r <= b_lite_resp;
      end
      if (tx_bl_fire) bl_pend_r <= 1'b0;

      // ---- R-Lite single-flit ----
      if (r_lite_valid & r_lite_ready) begin
        rl_pend_r <= 1'b1;
        rl_data_r <= r_lite_data[LITE_PKT_DATA_W-1:0];
        rl_resp_r <= r_lite_resp;
      end
      if (tx_rl_fire) rl_pend_r <= 1'b0;

      // ---- R-Full chunked sender ----
      // First beat in IDLE: latch rid + rresp from the slave's beat
      if (rf_state_r == S_RF_IDLE && rf_push) begin
        rf_id_r   <= r_full_id;
        rf_resp_r <= r_full_resp;
      end

      // Latch m_rlast as it lands -- mirrors the W sender's last_seen handling
      if (rf_push && r_full_last) rf_last_seen_r <= 1'b1;

      // Clear last_seen on burst completion (state going back to IDLE)
      if (rf_state_r != S_RF_IDLE && rf_state_n == S_RF_IDLE)
        rf_last_seen_r <= 1'b0;

      // ---- Buffer update (push and/or emit).  All quantities in bytes.
      if (rf_push && rf_emit_fire) begin
        rf_buf_r   <= (rf_buf_r >> (rf_emit_n * 8))
                    | ({{(R_BUF_W - DATA_W){1'b0}}, r_full_data}
                       << ((rf_count_r - rf_emit_n) * 8));
        rf_count_r <= rf_count_r - rf_emit_n + R_CNT_W'(STRB_W);
      end else if (rf_emit_fire) begin
        rf_buf_r   <= rf_buf_r >> (rf_emit_n * 8);
        rf_count_r <= rf_count_r - rf_emit_n;
      end else if (rf_push) begin
        rf_buf_r   <= rf_buf_r | ({{(R_BUF_W - DATA_W){1'b0}}, r_full_data}
                                  << (rf_count_r * 8));
        rf_count_r <= rf_count_r + R_CNT_W'(STRB_W);
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (aresetn) begin
      // m_rlast arriving while we're still draining the previous burst's
      // tail flits would mean two R bursts have interleaved at the slave's
      // R channel -- shouldn't happen with single-outstanding reads.
      if (rf_push && r_full_last && rf_last_seen_r)
        $warning("axi_packetizer: m_rlast while previous R burst still draining");
    end
  end
`endif

endmodule
