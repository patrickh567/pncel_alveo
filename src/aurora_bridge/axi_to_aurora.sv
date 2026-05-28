// *************************************************************************
//
// AXI-Full <-> Aurora 64b/66b packet bridge -- master / requester end.
//
// Accepts AXI4-Full transactions on a slave port and serialises the
// command channels (AW/W chunked + AR) onto the Aurora user-side TX
// stream (256-bit, tlast=1, tkeep=32'hFFFFFFFF).
//
// Response channels:
//   B response packets arrive on the same Aurora RX wire this module
//     consumes and are unpacked onto the AXI4 B channel here.
//   R responses are handled OUTSIDE this module (by aurora_r_receiver).
//     The R slave-port outputs (s_rid/s_rdata/s_rresp/s_rlast/s_rvalid)
//     are tied to 0 here; wire the AXI master's R channel inputs to the
//     aurora_r_receiver instance.
//
// rx_in_cont_i (input) must be driven by whichever module owns the
//   chunked R RX path on the shared Aurora RX wire (e.g.
//   aurora_r_receiver.rx_in_cont_o). The B decode gates off whenever
//   rx_in_cont_i = 1 so a cont-chunk byte equal to OP_B = 0x12 isn't
//   misread as a B response.
//
// Limitations:
//   - Single outstanding write transaction.
//   - Concurrent read and write are OK (independent FSMs share the TX bus).
//   - No interleaved write data; W beats of one burst sent atomically.
//   - Single-deep B inbound staging.
//
// Packet format (256 bits per flit, byte 0 = opcode at [7:0] for non-cont flits):
//
//   WRITE TRANSACTION (request, AXI -> Aurora): byte-striped, multi-flit.
//     tdata carries W data bytes; tkeep carries the per-byte W strobe.
//     Header flit (OP_AW, 0x10): AW metadata (byte-aligned) + HDR_DATA_BYTES
//                                of W data bytes (tkeep[8:0]=1 for metadata,
//                                tkeep[31:9] = strobe for those data bytes).
//     Continuation flit (NO opcode): 32 W data bytes (tkeep[31:0] = strobe).
//     Total W bytes per transaction = (awlen+1) * (DATA_W/8).
//     tlast=1 marks the FINAL flit of the burst.
//
//   B  (0x12): id, resp -- single-flit response.
//   AR (0x13): id, addr, len, size, burst, cache, prot, lite -- single-flit request.
//
// TX arbiter (this module): committed W-cont stream > AR > new W-hdr.
//   Once a W header flit is sent, cont flits cannot be interleaved (cont
//   flits carry no opcode). The arbiter enforces this.
//
// Default parameters (DATA_W=128, ID_W=4, ADDR_W=32):
//   W header chunk capacity = (256 - 65) / 36 = 5
//   W continuation chunk capacity = 256 / 36 = 7
//
// *************************************************************************
`timescale 1ns/1ps
module axi_to_aurora #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  // ---------------- AXI-Full slave port ----------------
  // AW
  input  wire [ID_W-1:0]         s_awid,
  input  wire [ADDR_W-1:0]       s_awaddr,
  input  wire [7:0]              s_awlen,
  input  wire [2:0]              s_awsize,
  input  wire [1:0]              s_awburst,
  input  wire [3:0]              s_awcache,
  input  wire [2:0]              s_awprot,
  input  wire                    s_aw_lite,   // 1 = AXI-Lite tag, 0 = AXI-Full
  input  wire                    s_awvalid,
  output wire                    s_awready,
  // W
  input  wire [DATA_W-1:0]       s_wdata,
  input  wire [DATA_W/8-1:0]     s_wstrb,
  input  wire                    s_wlast,
  input  wire                    s_wvalid,
  output wire                    s_wready,
  // B
  output wire [ID_W-1:0]         s_bid,
  output wire [1:0]              s_bresp,
  output wire                    s_bvalid,
  input  wire                    s_bready,
  // AR
  input  wire [ID_W-1:0]         s_arid,
  input  wire [ADDR_W-1:0]       s_araddr,
  input  wire [7:0]              s_arlen,
  input  wire [2:0]              s_arsize,
  input  wire [1:0]              s_arburst,
  input  wire [3:0]              s_arcache,
  input  wire [2:0]              s_arprot,
  input  wire                    s_ar_lite,   // 1 = AXI-Lite tag, 0 = AXI-Full
  input  wire                    s_arvalid,
  output wire                    s_arready,
  // R
  output wire [ID_W-1:0]         s_rid,
  output wire [DATA_W-1:0]       s_rdata,
  output wire [1:0]              s_rresp,
  output wire                    s_rlast,
  output wire                    s_rvalid,
  input  wire                    s_rready,

  // ---------------- Aurora data TX (chunked W with embedded AW) ----------
  // tlast = 1 on the FINAL flit of each chunked W frame; 0 on intermediate
  // flits. Lets the top-level arbiter release the data channel between
  // frames without interleaving cont flits from other sources.
  output wire [255:0]            tx_data_tdata,
  output wire [31:0]             tx_data_tkeep,
  output wire                    tx_data_tlast,
  output wire                    tx_data_tvalid,
  input  wire                    tx_data_tready,

  // ---------------- Aurora user-K TX (AR single-flit packets) ------------
  output wire [255:0]            tx_userk_tdata,
  output wire                    tx_userk_tvalid,
  input  wire                    tx_userk_tready,

  // ---------------- Aurora user-K RX (B single-flit packets) -------------
  input  wire [255:0]            rx_tdata,
  input  wire                    rx_tvalid,

  // External "RX is in a chunked-stream continuation" signal. Drive this
  // from whichever module owns chunked-stream RX on the SAME wire
  // (e.g. aurora_r_receiver.rx_in_cont_o when sharing user-K RX). When 1
  // the B decode is gated off. If user-K RX has no other consumer that
  // emits chunked streams, tie this to 1'b0.
  input  wire                    rx_in_cont_i
);

  localparam int STRB_W = DATA_W / 8;

  // Byte-stripe geometry. W data flows on `tdata` byte by byte; the per-
  // byte strobe rides in `tkeep`. The header flit's leading bytes carry
  // the AW metadata (always-valid tkeep=1); the trailing bytes are W data
  // with their strobe in the corresponding tkeep bits. Continuation flits
  // are pure W data (32 bytes per flit).
  localparam int LITE_W              = 1;
  localparam int HDR_AW_W            = 8 + ID_W + ADDR_W + 8 + 3 + 2 + 4 + 3 + LITE_W;  // 65
  localparam int HDR_DATA_OFFSET     = ((HDR_AW_W + 7) / 8) * 8;       // 72 (byte-aligned)
  localparam int HDR_DATA_OFFSET_B   = HDR_DATA_OFFSET / 8;            // 9 metadata bytes
  localparam int HDR_PAD_W           = HDR_DATA_OFFSET - HDR_AW_W;     // 7 bits
  localparam int HDR_DATA_BYTES      = (256 - HDR_DATA_OFFSET) / 8;    // 23 W bytes
  localparam int CONT_DATA_BYTES     = 32;                              // 256/8

  // Byte buffer: hold at least one full cont flit minus 1 + one fresh
  // W beat's worth of bytes.
  localparam int BUF_BYTES       = CONT_DATA_BYTES + STRB_W;           // 48 (DATA_W=128)
  localparam int BUF_DATA_W      = BUF_BYTES * 8;
  localparam int CNT_W           = $clog2(BUF_BYTES + 1);

  // Burst chunk-count width (max awlen=255 -> 1024 chunks for DATA_W=128)
  localparam int TOTAL_CNT_W     = 16;

  // R RX is handled externally by aurora_r_receiver, so no R chunk geometry
  // is needed here. The B RX path uses rx_in_cont_i to know when the shared
  // RX wire is carrying a chunked R cont flit.

  localparam logic [7:0] OP_AW = 8'h10;
  localparam logic [7:0] OP_B  = 8'h12;
  localparam logic [7:0] OP_AR = 8'h13;
  localparam logic [7:0] OP_R  = 8'h14;
  // (no OP for W/R continuation flits -- dispatched by chunks-remaining state)

  `ifdef ASSERT_PKT_FITS
    initial begin
      assert (HDR_DATA_OFFSET + HDR_DATA_BYTES*8 == 256)
        else $fatal(1, "axi_to_aurora: header flit doesn't fill 256 bits");
      assert (HDR_DATA_OFFSET_B + HDR_DATA_BYTES == 32)
        else $fatal(1, "axi_to_aurora: header tkeep doesn't fill 32 bits");
      assert (DATA_W % 8 == 0)
        else $fatal(1, "axi_to_aurora: DATA_W must be a multiple of 8");
    end
  `endif

  // =========================================================================
  // WRITE PATH — chunked W path
  //   Header flit (OP_AW): AW metadata + HDR_DATA_BYTES W bytes
  //   Continuation flit (NO OP): 32 W bytes
  //   Receiver knows total = (awlen+1)*STRB_W bytes; FSM tracks remainder.
  // =========================================================================
  typedef enum logic [1:0] {
    S_W_IDLE,
    S_W_TX_HDR,     // accumulating + emitting the header flit
    S_W_TX_CONT,    // accumulating + emitting continuation flits
    S_W_WAIT_B
  } write_state_e;

  write_state_e w_state_r, w_state_n;

  logic [ID_W-1:0]   aw_id_r;
  logic [ADDR_W-1:0] aw_addr_r;
  logic [7:0]        aw_len_r;
  logic [2:0]        aw_size_r;
  logic [1:0]        aw_burst_r;
  logic [3:0]        aw_cache_r;
  logic [2:0]        aw_prot_r;
  logic              aw_lite_r;

  // B inbound staging (1-deep)
  logic              b_pending_r;
  logic [ID_W-1:0]   b_id_r;
  logic [1:0]        b_resp_r;

  // Byte buffer: data bytes and strobe bits in parallel vectors. Bytes
  // are pushed at the tail (count_r) and popped from the head.
  logic [BUF_DATA_W-1:0] data_buf_r;
  logic [BUF_BYTES-1:0]  strb_buf_r;
  logic [CNT_W-1:0]      count_r;        // valid bytes currently in buffers
  logic                  last_seen_r;    // wlast has been accepted

  // Header flit tdata: AW metadata (byte-padded) at LSB; W data bytes fill
  // the rest of the flit. The header carries the first HDR_DATA_BYTES of
  // the burst.
  wire [255:0] hdr_pkt = {
      data_buf_r[0 +: HDR_DATA_BYTES * 8],   // 23 bytes for ID_W=4
      {HDR_PAD_W{1'b0}},                      // byte-align pad after metadata
      aw_lite_r,
      aw_prot_r,
      aw_cache_r,
      aw_burst_r,
      aw_size_r,
      aw_len_r,
      aw_addr_r,
      aw_id_r,
      OP_AW
  };

  // Cont flit tdata: 32 bytes of pure W data (256 bits exactly).
  wire [255:0] cont_pkt = data_buf_r[0 +: CONT_DATA_BYTES * 8];

  // Header flit tkeep: metadata bytes always valid; data bytes carry strb.
  wire [31:0] hdr_tkeep = {
      strb_buf_r[0 +: HDR_DATA_BYTES],       // 23 strb bits for ID_W=4
      {HDR_DATA_OFFSET_B{1'b1}}               // 9 metadata-byte valid bits
  };

  // Cont flit tkeep: 32 strb bits (one per byte). Bytes beyond count_r on
  // the final partial flit have strb_buf_r = 0 (buffer is zero-filled),
  // which encodes tkeep=0 -- correctly marked invalid on the wire.
  wire [31:0] cont_tkeep = strb_buf_r[0 +: CONT_DATA_BYTES];

  // =========================================================================
  // READ PATH (AR out, R in)
  // =========================================================================
  typedef enum logic [0:0] {
    S_R_IDLE,
    S_R_TX_AR
  } read_state_e;

  read_state_e r_state_r, r_state_n;

  logic [ID_W-1:0]   ar_id_r;
  logic [ADDR_W-1:0] ar_addr_r;
  logic [7:0]        ar_len_r;
  logic [2:0]        ar_size_r;
  logic [1:0]        ar_burst_r;
  logic [3:0]        ar_cache_r;
  logic [2:0]        ar_prot_r;
  logic              ar_lite_r;

  // Build the AR packet
  // Field order (MSB -> LSB): padding | lite | prot | cache | burst | size | len | addr | id | OP_AR
  wire [255:0] ar_pkt = {
      {(256 - 8 - ID_W - ADDR_W - 8 - 3 - 2 - 4 - 3 - LITE_W){1'b0}},
      ar_lite_r,
      ar_prot_r,
      ar_cache_r,
      ar_burst_r,
      ar_size_r,
      ar_len_r,
      ar_addr_r,
      ar_id_r,
      OP_AR
  };

  // (R RX path removed; aurora_r_receiver handles the chunked R stream and
  //  drives the AXI master's R channel directly. s_r* outputs below are
  //  tied to 0 to preserve the slave-port shape.)

  // =========================================================================
  // Chunk accumulator control
  //   push: accept a W beat (when there's room for STRB_W more bytes)
  //   emit: send a flit (when buffer has enough chunks, or when wlast seen with
  //         residual chunks to drain)
  // =========================================================================
  wire active        = (w_state_r == S_W_TX_HDR) || (w_state_r == S_W_TX_CONT);
  wire room_for_w    = (count_r + STRB_W[CNT_W-1:0]) <= BUF_BYTES[CNT_W-1:0];
  // BUG-FIX: once the final W beat of the current AW has been accepted
  // (last_seen_r is set), refuse subsequent W beats until the FSM
  // returns to S_W_IDLE on bresp.  Without this guard, the next AW's
  // W beat is absorbed into the CURRENT packet — the receiver still
  // writes only `(awlen+1)*STRB_W` bytes to HBM, but the AXI master
  // believes its W beat was consumed and advances W's pointer.  Net
  // effect: W beats slip relative to AW beats and HBM ends up with
  // the wrong (or zero) data at most addresses in a multi-write
  // burst.  Caught by combined_sim's smoke-test-5 memory sweep.
  wire push          = s_wvalid & active & room_for_w & ~last_seen_r;

  // Per-state flit data capacity (bytes) and emit decision
  wire [CNT_W-1:0] flit_data_cap = (w_state_r == S_W_TX_HDR)
                                     ? HDR_DATA_BYTES[CNT_W-1:0]
                                     : CONT_DATA_BYTES[CNT_W-1:0];
  wire emit_ready    = active &&
                       ((count_r >= flit_data_cap) ||
                        (last_seen_r && (count_r > 0)));
  wire emit_fire     = emit_ready & tx_data_tready;

  // bytes actually emitted this flit (cap, or all remaining on final partial flit)
  wire [CNT_W-1:0] emit_n = (count_r >= flit_data_cap) ? flit_data_cap : count_r;

  // =========================================================================
  // TX paths
  //   tx_data : chunked W (header flit OP_AW + cont flits, no opcode)
  //             tlast=1 ONLY on the final flit of the frame so top-level
  //             arbiter can release the data channel between frames.
  //   tx_userk: AR single-flit packet, tlast=1 (a complete Aurora frame).
  // =========================================================================
  wire w_tx_want_hdr  = (w_state_r == S_W_TX_HDR)  && emit_ready;
  wire w_tx_want_cont = (w_state_r == S_W_TX_CONT) && emit_ready;
  wire w_tx_want      = w_tx_want_hdr | w_tx_want_cont;

  // Final flit of the chunked W frame: all data has been received (wlast was
  // accepted) AND this emit drains the rest of the buffer.
  wire w_tx_is_final  = last_seen_r && (count_r == emit_n);

  assign tx_data_tdata  = w_tx_want_hdr ? hdr_pkt   : cont_pkt;
  assign tx_data_tkeep  = w_tx_want_hdr ? hdr_tkeep : cont_tkeep;
  assign tx_data_tlast  = w_tx_is_final;
  assign tx_data_tvalid = w_tx_want;

  assign tx_userk_tdata  = ar_pkt;
  assign tx_userk_tvalid = (r_state_r == S_R_TX_AR);

  // =========================================================================
  // Write FSM
  // =========================================================================
  always_comb begin
    w_state_n = w_state_r;
    case (w_state_r)
      S_W_IDLE:
        if (s_awvalid) w_state_n = S_W_TX_HDR;
      S_W_TX_HDR:
        // Header flit egresses; if any chunks remain after this emit, go to CONT.
        if (emit_fire) begin
          if (last_seen_r && (count_r == emit_n))
            w_state_n = S_W_WAIT_B;
          else
            w_state_n = S_W_TX_CONT;
        end
      S_W_TX_CONT:
        if (emit_fire && last_seen_r && (count_r == emit_n))
          w_state_n = S_W_WAIT_B;
      S_W_WAIT_B:
        if (b_pending_r && s_bready) w_state_n = S_W_IDLE;
      default:
        w_state_n = S_W_IDLE;
    endcase
  end

  // Byte-buffer state update (data and strb tracked in parallel)
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      w_state_r   <= S_W_IDLE;
      data_buf_r  <= '0;
      strb_buf_r  <= '0;
      count_r     <= '0;
      last_seen_r <= 1'b0;
    end else begin
      w_state_r <= w_state_n;

      // Latch AW when accepting it
      if (w_state_r == S_W_IDLE && s_awvalid) begin
        aw_id_r    <= s_awid;
        aw_addr_r  <= s_awaddr;
        aw_len_r   <= s_awlen;
        aw_size_r  <= s_awsize;
        aw_burst_r <= s_awburst;
        aw_cache_r <= s_awcache;
        aw_prot_r  <= s_awprot;
        aw_lite_r  <= s_aw_lite;
        last_seen_r <= 1'b0;       // reset on new transaction
      end

      // Update byte buffer with push and/or emit on this cycle
      if (push && emit_fire) begin
        data_buf_r <= (data_buf_r >> (emit_n * 8))
                    | ({{(BUF_DATA_W - DATA_W){1'b0}}, s_wdata}
                       << ((count_r - emit_n) * 8));
        strb_buf_r <= (strb_buf_r >> emit_n)
                    | ({{(BUF_BYTES - STRB_W){1'b0}}, s_wstrb}
                       << (count_r - emit_n));
        count_r    <= count_r - emit_n + STRB_W[CNT_W-1:0];
      end else if (emit_fire) begin
        data_buf_r <= data_buf_r >> (emit_n * 8);
        strb_buf_r <= strb_buf_r >> emit_n;
        count_r    <= count_r - emit_n;
      end else if (push) begin
        data_buf_r <= data_buf_r
                    | ({{(BUF_DATA_W - DATA_W){1'b0}}, s_wdata} << (count_r * 8));
        strb_buf_r <= strb_buf_r
                    | ({{(BUF_BYTES - STRB_W){1'b0}}, s_wstrb} << count_r);
        count_r    <= count_r + STRB_W[CNT_W-1:0];
      end

      // Latch wlast when consuming the final W beat
      if (push && s_wlast) last_seen_r <= 1'b1;

      // Clear accumulator state on transaction completion
      if (w_state_r == S_W_WAIT_B && w_state_n == S_W_IDLE) begin
        count_r     <= '0;
        last_seen_r <= 1'b0;
        data_buf_r  <= '0;
        strb_buf_r  <= '0;
      end
    end
  end

  assign s_awready = (w_state_r == S_W_IDLE);
  assign s_wready  = push;             // accept this W beat (chunks go into buf this cycle)
  assign s_bid     = b_id_r;
  assign s_bresp   = b_resp_r;
  assign s_bvalid  = (w_state_r == S_W_WAIT_B) & b_pending_r;

  // =========================================================================
  // Read FSM
  //   The R response carries its own rlen in the header, so this module
  //   does NOT need to keep ar_len_r alive across the round trip. AR can
  //   re-issue back-to-back; multi-outstanding is bounded only by the
  //   master's own tag space and the responder's ordering guarantees.
  // =========================================================================
  wire ar_pkt_fire = tx_userk_tvalid & tx_userk_tready;

  always_comb begin
    r_state_n = r_state_r;
    case (r_state_r)
      S_R_IDLE:   if (s_arvalid)   r_state_n = S_R_TX_AR;
      S_R_TX_AR:  if (ar_pkt_fire) r_state_n = S_R_IDLE;
      default:                     r_state_n = S_R_IDLE;
    endcase
  end

  // =========================================================================
  // RX field extractors (B only -- R is handled externally by aurora_r_receiver)
  // =========================================================================
  wire [7:0]              rx_op       = rx_tdata[7:0];
  wire [ID_W-1:0]         rx_b_id     = rx_tdata[8                            +: ID_W];
  wire [1:0]              rx_b_resp   = rx_tdata[8 + ID_W                     +: 2];

  // B fires only on OP_B AND when we're not inside an R chunked cont stream
  // (signalled externally via rx_in_cont_i, typically from aurora_r_receiver).
  wire b_rx_fire = rx_tvalid & ~rx_in_cont_i & (rx_op == OP_B);

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      r_state_r   <= S_R_IDLE;
      b_pending_r <= 1'b0;
    end else begin
      r_state_r <= r_state_n;

      // Latch AR on s_ar handshake
      if (r_state_r == S_R_IDLE && s_arvalid) begin
        ar_id_r    <= s_arid;
        ar_addr_r  <= s_araddr;
        ar_len_r   <= s_arlen;
        ar_size_r  <= s_arsize;
        ar_burst_r <= s_arburst;
        ar_cache_r <= s_arcache;
        ar_prot_r  <= s_arprot;
        ar_lite_r  <= s_ar_lite;
      end

      // B inbound staging (1-deep)
      if (s_bvalid && s_bready) b_pending_r <= 1'b0;
      if (b_rx_fire) begin
        b_pending_r <= 1'b1;
        b_id_r      <= rx_b_id;
        b_resp_r    <= rx_b_resp;
      end
    end
  end

  // R channel: not handled here. Tie outputs to 0 (the AXI master will
  // get its R from aurora_r_receiver instead).
  assign s_rid     = '0;
  assign s_rdata   = '0;
  assign s_rresp   = 2'b00;
  assign s_rlast   = 1'b0;
  assign s_rvalid  = 1'b0;

  assign s_arready = (r_state_r == S_R_IDLE);

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (aresetn) begin
      // B inbound overrun (single-deep staging)
      if (b_rx_fire && b_pending_r && !(s_bvalid && s_bready))
        $warning("axi_to_aurora: B packet overrun (previous B not yet consumed)");
    end
  end
`endif

endmodule
