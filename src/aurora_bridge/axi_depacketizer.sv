// *************************************************************************
//
// axi_depacketizer -- chunked AXI request depacketizer with Full/Lite demux.
//
// Receives chunked AW/W/AR packets on a 256-bit Aurora-style RX stream and
// drives them onto one of two AXI master ports, selected by the
// per-transaction `lite` flag carried in the AW/AR header:
//
//   lite = 0  -> AXI-Full master port (m_full_*)
//   lite = 1  -> AXI-Lite master port (m_lite_*)
//
// Packet format matches axi_to_aurora (the sender):
//   AW header (OP_AW, 0x10): id, addr, len, size, burst, cache, prot, lite
//                             + HDR_DATA_BYTES of W data (tdata) with
//                             matching per-byte strb in tkeep
//   W continuation (NO opcode): 32 bytes of W data with tkeep = strobe
//   AR header (OP_AR, 0x13):  id, addr, len, size, burst, cache, prot, lite
//
// B and R responses from the slaves are accepted (m_*_bready / m_*_rready
// tied high) but NOT packetized back to the sender. Wire a separate
// response packetizer if you need to relay them.
//
// Both ports are single-outstanding (W FSM waits for B before next AW,
// R FSM waits for rlast before next AR).
//
// The lite port omits id/len/size/burst/cache (AXI-Lite is a strict
// subset). For W data, the lite port presents the same DATA_W as the
// full port; narrow externally with a downsizer if your lite slave
// is narrower (typically 32-bit).
//
// *************************************************************************
`timescale 1ns/1ps
module axi_depacketizer #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 128,
  parameter int ID_W   = 4
) (
  input  wire                    aclk,
  input  wire                    aresetn,

  // ---------------- Aurora data RX (chunked W with embedded AW) ----------
  // tkeep carries the per-byte W strobe at the chunk byte positions.
  input  wire [255:0]            rx_data_tdata,
  input  wire [31:0]             rx_data_tkeep,
  input  wire                    rx_data_tvalid,
  // Status: 1 while a chunked-W stream is in progress on rx_data_*. Routed
  // externally to gate other consumers of the same data RX wire (e.g.
  // aurora_r_receiver's R header decode).
  output wire                    rx_in_cont_o,
  // Cross-gate input: 1 while another module owns the data RX (e.g.
  // aurora_r_receiver mid-R-cont). When 1, this module's W header decode
  // is suppressed so it doesn't misread a chunk byte equal to OP_AW.
  input  wire                    rx_in_cont_i,

  // ---------------- Aurora user-K RX (AR single-flit packets) ------------
  input  wire [255:0]            rx_userk_tdata,
  input  wire                    rx_userk_tvalid,

  // ---------------- AXI-Full master port (lite=0 transactions) ------------
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

  // ---------------- AXI-Lite master port (lite=1 transactions) ------------
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

  // Byte-stripe wire format: tdata = W bytes, tkeep = W per-byte strobe.
  // Internal buffer is byte-level (data + strb in parallel).
  localparam int STRB_W              = DATA_W / 8;
  // Lite-frame payload width — must match axi_lite_to_aurora.sv's
  // LITE_PKT_DATA_W. AXI-Lite is 32-bit per spec; the wrapper's wider
  // DATA_W applies only to the Full path. Without this, the depacketizer
  // would expect STRB_W (e.g. 64) bytes per lite beat, stall waiting for
  // cont flits that don't come, and stick rx_in_cont_o asserted —
  // cross-gating off the R receiver and dropping every cache-read
  // response (see axi_aurora_bridge.sv responder cross-gating).
  localparam int LITE_PKT_STRB_W     = 4;
  localparam int LITE_W              = 1;
  localparam int HDR_AW_W            = 8 + ID_W + ADDR_W + 8 + 3 + 2 + 4 + 3 + LITE_W;  // 65
  localparam int HDR_DATA_OFFSET     = ((HDR_AW_W + 7) / 8) * 8;                       // 72
  localparam int HDR_DATA_OFFSET_B   = HDR_DATA_OFFSET / 8;                            // 9
  localparam int HDR_DATA_BYTES      = (256 - HDR_DATA_OFFSET) / 8;                    // 23
  localparam int CONT_DATA_BYTES     = 32;
  localparam int RX_BUF_BYTES        = CONT_DATA_BYTES + STRB_W + 64;  // slack for back-to-back flits + 1 beat
  localparam int RX_BUF_DATA_W       = RX_BUF_BYTES * 8;
  localparam int RX_CNT_W            = $clog2(RX_BUF_BYTES + 1);
  localparam int TOTAL_CNT_W         = 16;

  localparam logic [7:0] OP_AW = 8'h10;
  localparam logic [7:0] OP_AR = 8'h13;

  // ---- RX field extractors ----
  // ---- AW header + W chunks come in on rx_data_* (chunked frame) ----
  wire [7:0]            rx_d_op       = rx_data_tdata[7:0];

  // Slice the W data and strobe bytes out of the incoming flit. Header flit
  // data bytes start at HDR_DATA_OFFSET_B; cont flit data starts at byte 0.
  wire [HDR_DATA_BYTES*8-1:0]  rx_hdr_data  = rx_data_tdata[HDR_DATA_OFFSET +: HDR_DATA_BYTES*8];
  wire [HDR_DATA_BYTES-1:0]    rx_hdr_strb  = rx_data_tkeep[HDR_DATA_OFFSET_B +: HDR_DATA_BYTES];
  wire [CONT_DATA_BYTES*8-1:0] rx_cont_data = rx_data_tdata[0                +: CONT_DATA_BYTES*8];
  wire [CONT_DATA_BYTES-1:0]   rx_cont_strb = rx_data_tkeep[0                +: CONT_DATA_BYTES];

  // AW metadata extracted from the W header flit on rx_data_*
  wire [ID_W-1:0]       rx_aw_id     = rx_data_tdata[8                                  +: ID_W];
  wire [ADDR_W-1:0]     rx_aw_addr   = rx_data_tdata[8 + ID_W                           +: ADDR_W];
  wire [7:0]            rx_aw_len    = rx_data_tdata[8 + ID_W + ADDR_W                  +: 8];
  wire [2:0]            rx_aw_size   = rx_data_tdata[8 + ID_W + ADDR_W + 8              +: 3];
  wire [1:0]            rx_aw_burst  = rx_data_tdata[8 + ID_W + ADDR_W + 8 + 3          +: 2];
  wire [3:0]            rx_aw_cache  = rx_data_tdata[8 + ID_W + ADDR_W + 8 + 3 + 2      +: 4];
  wire [2:0]            rx_aw_prot   = rx_data_tdata[8 + ID_W + ADDR_W + 8 + 3 + 2 + 4  +: 3];
  wire                  rx_aw_lite   = rx_data_tdata[8 + ID_W + ADDR_W + 8 + 3 + 2 + 4 + 3];

  // ---- AR metadata comes in on rx_userk_* (single-flit packet) ----
  wire [7:0]            rx_u_op      = rx_userk_tdata[7:0];
  wire [ID_W-1:0]       rx_ar_id     = rx_userk_tdata[8                                  +: ID_W];
  wire [ADDR_W-1:0]     rx_ar_addr   = rx_userk_tdata[8 + ID_W                           +: ADDR_W];
  wire [7:0]            rx_ar_len    = rx_userk_tdata[8 + ID_W + ADDR_W                  +: 8];
  wire [2:0]            rx_ar_size   = rx_userk_tdata[8 + ID_W + ADDR_W + 8              +: 3];
  wire [1:0]            rx_ar_burst  = rx_userk_tdata[8 + ID_W + ADDR_W + 8 + 3          +: 2];
  wire [3:0]            rx_ar_cache  = rx_userk_tdata[8 + ID_W + ADDR_W + 8 + 3 + 2      +: 4];
  wire [2:0]            rx_ar_prot   = rx_userk_tdata[8 + ID_W + ADDR_W + 8 + 3 + 2 + 4  +: 3];
  wire                  rx_ar_lite   = rx_userk_tdata[8 + ID_W + ADDR_W + 8 + 3 + 2 + 4 + 3];

  // =========================================================================
  // WRITE PATH
  // =========================================================================
  typedef enum logic [1:0] {
    S_W_IDLE,
    S_W_DRIVE_AW,
    S_W_DRIVE_W,
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

  // -- 1-deep AW shadow.  Decouples RX from AXI drive: while the FSM is
  // mid-drive of the current AW, a new AW can be received and held here
  // so the bridge can stream packets back-to-back without waiting for
  // the prior packet's HBM bresp roundtrip.  See axi_to_aurora.sv's
  // serialization: it accepts the next AW the cycle after OP_B arrives,
  // which is several cycles AFTER the depacketizer's WAIT_B → IDLE
  // transition opens up here.  The shadow absorbs that gap.
  logic              aw_pending_r;
  logic [ID_W-1:0]   aw_id_shadow_r;
  logic [ADDR_W-1:0] aw_addr_shadow_r;
  logic [7:0]        aw_len_shadow_r;
  logic [2:0]        aw_size_shadow_r;
  logic [1:0]        aw_burst_shadow_r;
  logic [3:0]        aw_cache_shadow_r;
  logic [2:0]        aw_prot_shadow_r;
  logic              aw_lite_shadow_r;

  logic [RX_BUF_DATA_W-1:0] rx_data_buf_r;
  logic [RX_BUF_BYTES-1:0]  rx_strb_buf_r;
  logic [RX_CNT_W-1:0]      rx_count_r;       // bytes currently in buffer
  logic [TOTAL_CNT_W-1:0]   bytes_rem_rx_r;   // bytes not yet received via RX
  logic [TOTAL_CNT_W-1:0]   bytes_rem_drv_r;  // bytes not yet driven to m_w

  // =========================================================================
  // READ PATH
  // =========================================================================
  typedef enum logic [1:0] {
    S_R_IDLE,
    S_R_DRIVE_AR,
    S_R_WAIT_R
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

  // =========================================================================
  // RX classification
  //   AW + W bytes come from rx_data_*; AR from rx_userk_*. The data-RX
  //   classifier gates AW header decode on:
  //     - own bytes_rem_rx_r == 0 (not mid-W-cont)
  //     - rx_in_cont_i == 0 (some other module isn't mid-cont on this wire)
  //     - rx_d_op == OP_AW
  // =========================================================================
  wire rx_is_cont    = (bytes_rem_rx_r != '0);
  assign rx_in_cont_o = rx_is_cont;

  // aw_rx_fire allows a new AW packet to be received when:
  //   (a) the FSM is in IDLE  (no current write), OR
  //   (b) the current write has fully drained to AXI (bytes_rem_drv_r==0)
  //       — i.e., we're sitting in WAIT_B waiting for bresp, the buffer
  //         is empty, and we can start receiving the NEXT packet's bytes
  //         while the FSM still drains the bresp roundtrip.
  // AND there's no AW already queued in the shadow regs.
  wire pipeline_ready = (w_state_r == S_W_IDLE) || (bytes_rem_drv_r == '0);
  wire aw_rx_fire    = rx_data_tvalid & ~rx_is_cont & ~rx_in_cont_i
                       & (rx_d_op == OP_AW) & pipeline_ready & ~aw_pending_r;
  wire cont_rx_fire  = rx_data_tvalid &  rx_is_cont;

  // Total bytes for the shadow AW (used when transitioning shadow → current).
  wire [TOTAL_CNT_W-1:0] aw_shadow_beat_bytes = aw_lite_shadow_r
                                                  ? TOTAL_CNT_W'(LITE_PKT_STRB_W)
                                                  : TOTAL_CNT_W'(STRB_W);
  wire [TOTAL_CNT_W-1:0] aw_shadow_total_bytes =
      (TOTAL_CNT_W'(aw_len_shadow_r) + TOTAL_CNT_W'(1)) * aw_shadow_beat_bytes;

  // Pipeline transition: WAIT_B → DRIVE_AW (skip IDLE) when shadow is valid.
  // (b_fire_active is hoisted up here from its later definition because
  // VCS doesn't allow forward references to module-scope wires.)
  wire b_fire_active_early = aw_lite_r ? (m_lite_bvalid & m_lite_bready)
                                       : (m_full_bvalid & m_full_bready);
  wire pipe_advance = (w_state_r == S_W_WAIT_B) & b_fire_active_early & aw_pending_r;

  wire ar_rx_fire    = rx_userk_tvalid & (rx_u_op == OP_AR) & (r_state_r == S_R_IDLE);

  // Bytes per beat: STRB_W for Full, LITE_PKT_STRB_W for Lite (= 4 always).
  wire [TOTAL_CNT_W-1:0] rx_beat_bytes = rx_aw_lite
                                          ? TOTAL_CNT_W'(LITE_PKT_STRB_W)
                                          : TOTAL_CNT_W'(STRB_W);
  wire [TOTAL_CNT_W-1:0] aw_total_bytes =
      (TOTAL_CNT_W'(rx_aw_len) + TOTAL_CNT_W'(1)) * rx_beat_bytes;

  // Bytes pushed into the buffer this cycle
  wire [RX_CNT_W-1:0] push_n =
      aw_rx_fire   ? ((aw_total_bytes >= TOTAL_CNT_W'(HDR_DATA_BYTES))
                        ? RX_CNT_W'(HDR_DATA_BYTES)
                        : RX_CNT_W'(aw_total_bytes)) :
      cont_rx_fire ? ((bytes_rem_rx_r >= TOTAL_CNT_W'(CONT_DATA_BYTES))
                        ? RX_CNT_W'(CONT_DATA_BYTES)
                        : RX_CNT_W'(bytes_rem_rx_r)) :
                     RX_CNT_W'(0);

  // Zero-extended push data/strb (selected based on header vs cont)
  wire [RX_BUF_DATA_W-1:0] push_data =
      aw_rx_fire   ? {{(RX_BUF_DATA_W - HDR_DATA_BYTES*8){1'b0}}, rx_hdr_data} :
      cont_rx_fire ? {{(RX_BUF_DATA_W - CONT_DATA_BYTES*8){1'b0}}, rx_cont_data} :
                     '0;
  wire [RX_BUF_BYTES-1:0] push_strb =
      aw_rx_fire   ? {{(RX_BUF_BYTES - HDR_DATA_BYTES){1'b0}}, rx_hdr_strb} :
      cont_rx_fire ? {{(RX_BUF_BYTES - CONT_DATA_BYTES){1'b0}}, rx_cont_strb} :
                     '0;

  // Active W-side handshake (the slave being driven this transaction)
  wire m_w_valid_active = aw_lite_r ? m_lite_wvalid : m_full_wvalid;
  wire m_w_ready_active = aw_lite_r ? m_lite_wready : m_full_wready;
  wire m_w_fire         = m_w_valid_active & m_w_ready_active;
  // Beat-byte count, latched-AW edition (used by W drive logic below).
  wire [TOTAL_CNT_W-1:0] beat_bytes = aw_lite_r
                                       ? TOTAL_CNT_W'(LITE_PKT_STRB_W)
                                       : TOTAL_CNT_W'(STRB_W);
  wire [RX_CNT_W-1:0] pop_n = m_w_fire ? RX_CNT_W'(beat_bytes) : RX_CNT_W'(0);

  // =========================================================================
  // Main always_ff: state, AW/AR latches, chunk buffer
  // =========================================================================
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      w_state_r        <= S_W_IDLE;
      r_state_r        <= S_R_IDLE;
      rx_data_buf_r    <= '0;
      rx_strb_buf_r    <= '0;
      rx_count_r       <= '0;
      bytes_rem_rx_r   <= '0;
      bytes_rem_drv_r  <= '0;
      aw_pending_r     <= 1'b0;
    end else begin
      w_state_r <= w_state_n;
      r_state_r <= r_state_n;

      // AW latch — go directly to current regs if FSM is IDLE, else
      // hold in shadow until the FSM cycles back through WAIT_B.
      if (aw_rx_fire) begin
        if (w_state_r == S_W_IDLE) begin
          aw_id_r    <= rx_aw_id;
          aw_addr_r  <= rx_aw_addr;
          aw_len_r   <= rx_aw_len;
          aw_size_r  <= rx_aw_size;
          aw_burst_r <= rx_aw_burst;
          aw_cache_r <= rx_aw_cache;
          aw_prot_r  <= rx_aw_prot;
          aw_lite_r  <= rx_aw_lite;
        end else begin
          aw_id_shadow_r    <= rx_aw_id;
          aw_addr_shadow_r  <= rx_aw_addr;
          aw_len_shadow_r   <= rx_aw_len;
          aw_size_shadow_r  <= rx_aw_size;
          aw_burst_shadow_r <= rx_aw_burst;
          aw_cache_shadow_r <= rx_aw_cache;
          aw_prot_shadow_r  <= rx_aw_prot;
          aw_lite_shadow_r  <= rx_aw_lite;
          aw_pending_r      <= 1'b1;
        end
      end

      // Pipeline advance: move shadow → current on WAIT_B → DRIVE_AW.
      if (pipe_advance) begin
        aw_id_r      <= aw_id_shadow_r;
        aw_addr_r    <= aw_addr_shadow_r;
        aw_len_r     <= aw_len_shadow_r;
        aw_size_r    <= aw_size_shadow_r;
        aw_burst_r   <= aw_burst_shadow_r;
        aw_cache_r   <= aw_cache_shadow_r;
        aw_prot_r    <= aw_prot_shadow_r;
        aw_lite_r    <= aw_lite_shadow_r;
        aw_pending_r <= 1'b0;
      end

      if (ar_rx_fire) begin
        ar_id_r    <= rx_ar_id;
        ar_addr_r  <= rx_ar_addr;
        ar_len_r   <= rx_ar_len;
        ar_size_r  <= rx_ar_size;
        ar_burst_r <= rx_ar_burst;
        ar_cache_r <= rx_ar_cache;
        ar_prot_r  <= rx_ar_prot;
        ar_lite_r  <= rx_ar_lite;
      end

      // bytes_rem_rx_r: tracks RECEPTION of the most-recently-arrived AW
      // (whether destined for current or shadow regs).
      if (aw_rx_fire) begin
        bytes_rem_rx_r <= aw_total_bytes - TOTAL_CNT_W'(push_n);
      end else if (cont_rx_fire) begin
        bytes_rem_rx_r <= bytes_rem_rx_r - TOTAL_CNT_W'(push_n);
      end

      // bytes_rem_drv_r: tracks DRIVE of currently-being-driven AW.
      //   - On aw_rx_fire INTO current (FSM was IDLE): set to new bytes.
      //   - On pipe_advance (shadow → current): set to shadow's bytes.
      //   - On m_w_fire: decrement.
      if (aw_rx_fire && (w_state_r == S_W_IDLE)) begin
        bytes_rem_drv_r <= aw_total_bytes;
      end else if (pipe_advance) begin
        bytes_rem_drv_r <= aw_shadow_total_bytes;
      end else if (m_w_fire) begin
        bytes_rem_drv_r <= bytes_rem_drv_r - TOTAL_CNT_W'(pop_n);
      end

      if (push_n != '0 && pop_n != '0) begin
        rx_data_buf_r <= (rx_data_buf_r >> (pop_n * 8))
                       | (push_data << ((rx_count_r - pop_n) * 8));
        rx_strb_buf_r <= (rx_strb_buf_r >> pop_n)
                       | (push_strb << (rx_count_r - pop_n));
        rx_count_r    <= rx_count_r - pop_n + push_n;
      end else if (push_n != '0) begin
        rx_data_buf_r <= rx_data_buf_r | (push_data << (rx_count_r * 8));
        rx_strb_buf_r <= rx_strb_buf_r | (push_strb << rx_count_r);
        rx_count_r    <= rx_count_r + push_n;
      end else if (pop_n != '0) begin
        rx_data_buf_r <= rx_data_buf_r >> (pop_n * 8);
        rx_strb_buf_r <= rx_strb_buf_r >> pop_n;
        rx_count_r    <= rx_count_r - pop_n;
      end
    end
  end

  // =========================================================================
  // Write FSM (combinational next-state)
  // =========================================================================
  wire b_fire_active = aw_lite_r ? (m_lite_bvalid & m_lite_bready)
                                 : (m_full_bvalid & m_full_bready);
  wire aw_handshake  = aw_lite_r ? (m_lite_awvalid & m_lite_awready)
                                 : (m_full_awvalid & m_full_awready);

  always_comb begin
    w_state_n = w_state_r;
    case (w_state_r)
      S_W_IDLE:     if (aw_rx_fire)               w_state_n = S_W_DRIVE_AW;
      S_W_DRIVE_AW: if (aw_handshake)             w_state_n = S_W_DRIVE_W;
      S_W_DRIVE_W:
        if (m_w_fire && (bytes_rem_drv_r == beat_bytes))
          w_state_n = S_W_WAIT_B;
      // Pipelined: if a shadow AW is queued, skip IDLE and drive it next.
      S_W_WAIT_B:   if (b_fire_active)            w_state_n = aw_pending_r ? S_W_DRIVE_AW : S_W_IDLE;
      default:                                    w_state_n = S_W_IDLE;
    endcase
  end

  // ---- Drive m_full AW / m_lite AW ----
  assign m_full_awid    = aw_id_r;
  assign m_full_awaddr  = aw_addr_r;
  assign m_full_awlen   = aw_len_r;
  assign m_full_awsize  = aw_size_r;
  assign m_full_awburst = aw_burst_r;
  assign m_full_awcache = aw_cache_r;
  assign m_full_awprot  = aw_prot_r;
  assign m_full_awvalid = (w_state_r == S_W_DRIVE_AW) & ~aw_lite_r;

  assign m_lite_awaddr  = aw_addr_r;
  assign m_lite_awprot  = aw_prot_r;
  assign m_lite_awvalid = (w_state_r == S_W_DRIVE_AW) &  aw_lite_r;

  // ---- Drive m_full W / m_lite W from byte buffer ----
  wire [DATA_W-1:0]   w_data_unpacked = rx_data_buf_r[0 +: DATA_W];
  wire [STRB_W-1:0]   w_strb_unpacked = rx_strb_buf_r[0 +: STRB_W];

  wire w_have_beat = (w_state_r == S_W_DRIVE_W) &
                     (rx_count_r >= RX_CNT_W'(beat_bytes));
  wire w_is_last   = (bytes_rem_drv_r == beat_bytes);

  assign m_full_wdata  = w_data_unpacked;
  assign m_full_wstrb  = w_strb_unpacked;
  assign m_full_wlast  = w_is_last;
  assign m_full_wvalid = w_have_beat & ~aw_lite_r;

  assign m_lite_wdata  = w_data_unpacked;
  assign m_lite_wstrb  = w_strb_unpacked;
  assign m_lite_wvalid = w_have_beat &  aw_lite_r;

  // ---- B: always ready, discard (no response packetization back) ----
  assign m_full_bready = 1'b1;
  assign m_lite_bready = 1'b1;

  // =========================================================================
  // Read FSM
  // =========================================================================
  wire ar_handshake = ar_lite_r ? (m_lite_arvalid & m_lite_arready)
                                : (m_full_arvalid & m_full_arready);
  wire r_burst_done = ar_lite_r ? (m_lite_rvalid & m_lite_rready)
                                : (m_full_rvalid & m_full_rready & m_full_rlast);

  always_comb begin
    r_state_n = r_state_r;
    case (r_state_r)
      S_R_IDLE:     if (ar_rx_fire)    r_state_n = S_R_DRIVE_AR;
      S_R_DRIVE_AR: if (ar_handshake)  r_state_n = S_R_WAIT_R;
      S_R_WAIT_R:   if (r_burst_done)  r_state_n = S_R_IDLE;
      default:                         r_state_n = S_R_IDLE;
    endcase
  end

  // ---- Drive m_full AR / m_lite AR ----
  assign m_full_arid    = ar_id_r;
  assign m_full_araddr  = ar_addr_r;
  assign m_full_arlen   = ar_len_r;
  assign m_full_arsize  = ar_size_r;
  assign m_full_arburst = ar_burst_r;
  assign m_full_arcache = ar_cache_r;
  assign m_full_arprot  = ar_prot_r;
  assign m_full_arvalid = (r_state_r == S_R_DRIVE_AR) & ~ar_lite_r;

  assign m_lite_araddr  = ar_addr_r;
  assign m_lite_arprot  = ar_prot_r;
  assign m_lite_arvalid = (r_state_r == S_R_DRIVE_AR) &  ar_lite_r;

  // ---- R: always ready, discard (drains the slave's response) ----
  assign m_full_rready  = 1'b1;
  assign m_lite_rready  = 1'b1;

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (aresetn) begin
      if ((push_n != '0) &&
          ((TOTAL_CNT_W'(rx_count_r) + TOTAL_CNT_W'(push_n) -
            TOTAL_CNT_W'(pop_n)) > TOTAL_CNT_W'(RX_BUF_BYTES)))
        $warning("axi_depacketizer: W RX chunk buffer overrun");
    end
  end
`endif

endmodule
