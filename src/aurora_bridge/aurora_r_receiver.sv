// *************************************************************************
//
// aurora_r_receiver -- chunked R-response receiver (byte-granular).
//
// Decodes chunked R packets on a 256-bit Aurora user stream (shares the
// data RX wire with axi_depacketizer; cross-gated via rx_in_cont_*).
// Drives the AXI R channel toward an AXI master adapter.
//
// Packet format matches axi_packetizer's R path (byte-granular, mirroring
// axi_to_aurora's W path):
//   Header flit (OP_R, 0x14):
//     bits[ 7: 0]   = OP_R
//     bits[ 7+ID_W : 8 ]    = rid
//     bits[ 9+ID_W : 8+ID_W ] = rresp
//     bits[ R_HDR_META_OFFSET-1 : 8+ID_W+2 ] = padding (to byte-align)
//     bits[ 255 : R_HDR_META_OFFSET ] = R data bytes
//     tkeep[R_HDR_META_OFFSET_B-1 : 0] = 1 always (metadata bytes)
//     tkeep[31 : R_HDR_META_OFFSET_B] = 1 if data byte is valid, 0 if padding
//   Continuation flit (NO opcode): 32 data bytes, tkeep[i]=1 if valid.
//   tlast=1 marks the FINAL flit of the burst.
//
// Each valid byte = rdata byte. The receiver pushes only valid bytes (per
// tkeep) so no padding accumulates as residual between bursts.
//
// Because the data RX has no backpressure, the byte buffer is sized for
// slack — at least one full cont flit plus one beat's worth.
//
// *************************************************************************
`timescale 1ns/1ps
module aurora_r_receiver #(
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire              aclk,
  input  wire              aresetn,

  // Aurora data RX stream (256-bit, 32-bit tkeep, no rx_tready -- no backpressure)
  input  wire [255:0]      rx_tdata,
  input  wire [31:0]       rx_tkeep,
  input  wire              rx_tlast,
  input  wire              rx_tvalid,

  // Cross-gating: rx_in_cont_o signals "I'm mid-R-cont"; rx_in_cont_i tells
  // me "another module is mid-cont on this wire" so I should suppress my
  // own header decode (a chunk byte equal to OP_R would otherwise be
  // misread).
  output wire              rx_in_cont_o,
  input  wire              rx_in_cont_i,

  // AXI R channel master output (to AXI adapter)
  output wire [ID_W-1:0]   m_rid,
  output wire [DATA_W-1:0] m_rdata,
  output wire [1:0]        m_rresp,
  output wire              m_rlast,
  output wire              m_rvalid,
  input  wire              m_rready
);

  localparam int R_RESP_W           = 2;
  localparam int STRB_W             = DATA_W / 8;            // bytes per AXI R beat
  localparam int R_HDR_META_W       = 8 + ID_W + R_RESP_W;   // 30 for ID_W=20
  // Byte-align the metadata so data bytes start on a byte boundary.
  localparam int R_HDR_META_OFFSET   = ((R_HDR_META_W + 7) / 8) * 8;     // 32 for ID_W=20
  localparam int R_HDR_META_OFFSET_B = R_HDR_META_OFFSET / 8;             // 4 metadata bytes
  localparam int R_HDR_PAD_W         = R_HDR_META_OFFSET - R_HDR_META_W;  // 2 bits
  localparam int R_HDR_DATA_BYTES    = (256 - R_HDR_META_OFFSET) / 8;     // 28 for ID_W=20
  localparam int R_CONT_DATA_BYTES   = 32;                                // 256/8

  // Byte buffer: hold at least one full cont flit + one beat's worth.
  localparam int R_BUF_BYTES         = R_CONT_DATA_BYTES + STRB_W;
  localparam int R_BUF_W             = R_BUF_BYTES * 8;
  localparam int R_CNT_W             = $clog2(R_BUF_BYTES + 1);

  localparam logic [7:0] OP_R = 8'h14;

  // ----------- RX state -----------
  logic                     rx_in_cont_r;
  logic                     last_seen_r;     // tlast was observed for this burst
  logic [R_BUF_W-1:0]       r_rx_buf_r;
  logic [R_CNT_W-1:0]       r_rx_count_r;    // valid bytes currently in buffer
  logic [ID_W-1:0]          rid_latched_r;
  logic [R_RESP_W-1:0]      rresp_latched_r;

  // ----------- Field extractors -----------
  wire [7:0]                rx_op       = rx_tdata[7:0];
  wire [ID_W-1:0]           rx_r_id     = rx_tdata[8                +: ID_W];
  wire [R_RESP_W-1:0]       rx_r_resp   = rx_tdata[8 + ID_W         +: R_RESP_W];
  // Header data bytes occupy bytes [R_HDR_META_OFFSET_B .. 31] of rx_tdata.
  wire [R_HDR_DATA_BYTES*8-1:0]  rx_r_hdr_data  =
      rx_tdata[R_HDR_META_OFFSET +: R_HDR_DATA_BYTES*8];
  // Cont data bytes occupy bytes [0 .. 31].
  wire [R_CONT_DATA_BYTES*8-1:0] rx_r_cont_data = rx_tdata[0 +: R_CONT_DATA_BYTES*8];

  // ----------- Classification -----------
  wire r_hdr_fire  = rx_tvalid & ~rx_in_cont_r & ~rx_in_cont_i & (rx_op == OP_R);
  wire r_cont_fire = rx_tvalid &  rx_in_cont_r;
  assign rx_in_cont_o = rx_in_cont_r;

  // ----------- Per-flit valid byte count, derived from tkeep -----------
  //
  // For the hdr flit, only the data-byte portion of tkeep is variable
  // (bytes [0..R_HDR_META_OFFSET_B-1] are always valid metadata).  The
  // packetizer fills data bytes contiguously starting at the lowest data
  // byte, so the count of valid data bytes = popcount of the data-byte
  // tkeep slice (equivalently, the position of the lowest 0 bit since
  // the packetizer never leaves gaps).
  //
  // For the cont flit, the count of valid bytes = popcount of tkeep.
  //
  // We compute popcount with a simple combinational adder tree.  No
  // need to be fancy at 32 bits.
  function automatic [R_CNT_W-1:0] popcount32 (input [31:0] x);
    integer pi;
    popcount32 = '0;
    for (pi = 0; pi < 32; pi = pi + 1)
      popcount32 = popcount32 + R_CNT_W'(x[pi]);
  endfunction

  wire [R_HDR_DATA_BYTES-1:0] hdr_data_tkeep = rx_tkeep[31:R_HDR_META_OFFSET_B];
  wire [R_CNT_W-1:0] hdr_data_valid_n  = popcount32({{(32-R_HDR_DATA_BYTES){1'b0}}, hdr_data_tkeep});
  wire [R_CNT_W-1:0] cont_data_valid_n = popcount32(rx_tkeep);

  wire [R_CNT_W-1:0] r_push_n =
      r_hdr_fire  ? hdr_data_valid_n  :
      r_cont_fire ? cont_data_valid_n :
                    R_CNT_W'(0);

  // r_push_chunks: bottom hdr_data_valid_n bytes from rx_r_hdr_data, or
  // bottom cont_data_valid_n bytes from rx_r_cont_data.  Because the
  // packetizer fills contiguously from byte 0 upward, masking by the
  // valid count = taking the bottom N*8 bits.
  wire [R_BUF_W-1:0] r_push_data =
      r_hdr_fire  ? {{(R_BUF_W - R_HDR_DATA_BYTES*8){1'b0}}, rx_r_hdr_data}  :
      r_cont_fire ? {{(R_BUF_W - R_CONT_DATA_BYTES*8){1'b0}}, rx_r_cont_data} :
                    '0;

  wire r_axi_fire = m_rvalid & m_rready;
  wire [R_CNT_W-1:0] r_pop_n = r_axi_fire ? R_CNT_W'(STRB_W) : R_CNT_W'(0);

  // Frame boundary flags
  wire r_rx_flit_fire   = rx_tvalid & (r_hdr_fire | r_cont_fire);
  wire r_frame_end_now  = r_rx_flit_fire & rx_tlast;

  // -- Residual reset on new-burst.  No padding bytes should be pushed
  // (we push only popcount(tkeep) bytes), so in principle residual is
  // always zero at hdr-fire.  Belt-and-suspenders: reset anyway.
  wire [R_CNT_W-1:0]  effective_count = r_hdr_fire ? '0 : r_rx_count_r;
  wire [R_BUF_W-1:0]  effective_buf   = r_hdr_fire ? '0 : r_rx_buf_r;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rx_in_cont_r    <= 1'b0;
      last_seen_r     <= 1'b0;
      r_rx_buf_r      <= '0;
      r_rx_count_r    <= '0;
    end else begin
      // rx_in_cont_r tracks "expecting more flits from this burst"
      if (r_hdr_fire && !rx_tlast)            rx_in_cont_r <= 1'b1;
      else if (r_cont_fire && rx_tlast)       rx_in_cont_r <= 1'b0;

      // last_seen_r: set on the tlast flit; cleared when the AXI master
      // accepts the final beat (m_rlast=1) or on a new burst.
      if (r_hdr_fire)                         last_seen_r <= 1'b0;
      else if (r_frame_end_now)               last_seen_r <= 1'b1;
      else if (r_axi_fire && m_rlast)         last_seen_r <= 1'b0;

      // Latch rid + rresp from header flit
      if (r_hdr_fire) begin
        rid_latched_r   <= rx_r_id;
        rresp_latched_r <= rx_r_resp;
      end

      // Buffer update (push and/or pop).  All quantities in bytes.
      if (r_push_n != '0 && r_pop_n != '0) begin
        r_rx_buf_r   <= (effective_buf >> (r_pop_n * 8))
                      | (r_push_data << ((effective_count - r_pop_n) * 8));
        r_rx_count_r <= effective_count - r_pop_n + r_push_n;
      end else if (r_push_n != '0) begin
        r_rx_buf_r   <= effective_buf | (r_push_data << (effective_count * 8));
        r_rx_count_r <= effective_count + r_push_n;
      end else if (r_pop_n != '0) begin
        r_rx_buf_r   <= r_rx_buf_r >> (r_pop_n * 8);
        r_rx_count_r <= r_rx_count_r - r_pop_n;
      end
    end
  end

  // Drive AXI R channel: bottom STRB_W bytes of r_rx_buf_r = next beat
  assign m_rdata   = r_rx_buf_r[0 +: DATA_W];
  assign m_rresp   = rresp_latched_r;
  assign m_rid     = rid_latched_r;
  // Final beat: tlast has been received AND this beat drains the buffer
  // (count after pop will be zero).  Because pushes only put real bytes
  // in, the buffer always holds an integer number of beats at burst end.
  assign m_rlast   = last_seen_r & (r_rx_count_r == R_CNT_W'(STRB_W));
  assign m_rvalid  = (r_rx_count_r >= R_CNT_W'(STRB_W));

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (aresetn) begin
      if (r_hdr_fire && last_seen_r)
        $warning("aurora_r_receiver: R header while previous R not fully drained");
      if ((r_push_n != '0) &&
          ((effective_count + r_push_n - r_pop_n) > R_CNT_W'(R_BUF_BYTES)))
        $warning("aurora_r_receiver: R RX byte buffer overrun (count=%0d push=%0d pop=%0d cap=%0d)",
                  effective_count, r_push_n, r_pop_n, R_BUF_BYTES);
    end
  end
`endif

endmodule
