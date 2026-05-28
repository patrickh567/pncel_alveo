// *************************************************************************
//
// Aurora 64b/66b ↔ AXI-Lite packet bridge (remote / responder end).
//
// The inverse of `axil_to_aurora`.  Sits on the far side of the Aurora
// link: receives request packets on the framed data RX channel, drives
// them as AXI-Lite master transactions toward a downstream slave, and
// (for reads) ships the captured response back on the user-K TX
// channel as a response packet.
//
// Packet format (single 256-bit beat — same layout as `axil_to_aurora`):
//
//   byte  0    : opcode
//                  0x01 WRITE_REQ  (incoming on aurora.rx_*)
//                  0x02 READ_REQ   (incoming on aurora.rx_*)
//                  0x82 READ_RESP  (outgoing on aurora.user_k_tx_*)
//   byte  1    : wstrb (WRITE_REQ)
//                rresp (READ_RESP)
//   bytes 2-3  : reserved (0)
//   bytes 4-7  : address (LE, ADDR_W ≤ 32 bits)
//   bytes 8-11 : write data (WRITE_REQ) / read data (READ_RESP), LE
//   bytes 12-31: padding (0)
//
// Clock domain
//   Both `m_axil` and `aurora` must be in the same clock domain — the
//   module clocks itself off `aurora.user_clk` and reset off
//   `aurora.user_aresetn`.  Wire `m_axil.aclk` to the same source.
//
// Concurrency
//   Single transaction at a time.  Incoming `rx_*` words while the
//   bridge is mid-transaction are ignored (no buffering).  Pair this
//   end with a single-outstanding `axil_to_aurora` master; if you need
//   more than one in flight, add an inbound packet FIFO and tag IDs.
//
// *************************************************************************
`timescale 1ns/1ps
module aurora_to_axil #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32
) (
  axi_lite_if.master m_axil,
  aurora_if.rm       aurora
);

  localparam int STRB_W = DATA_W / 8;

  localparam logic [7:0] OP_WRITE_REQ = 8'h01;
  localparam logic [7:0] OP_READ_REQ  = 8'h02;
  localparam logic [7:0] OP_READ_RESP = 8'h82;

  wire clk     = aurora.user_clk;
  wire aresetn = aurora.user_aresetn;

  // ---------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_W_DRIVE,    // driving AW + W concurrently
    S_W_B,        // waiting for B
    S_R_AR,       // driving AR
    S_R_R,        // waiting for R
    S_R_TX        // emitting READ_RESP on user-K TX
  } state_t;

  state_t state, state_next;

  // ---- Latched transaction fields ----
  logic [ADDR_W-1:0] addr_q;
  logic [DATA_W-1:0] wdata_q;
  logic [STRB_W-1:0] wstrb_q;
  logic [DATA_W-1:0] rdata_q;
  logic        [1:0] rresp_q;

  // Per-channel done flags for the concurrent AW + W drive
  logic aw_done_q, w_done_q;

  // ---- AXI-Lite output registers ----
  logic awvalid_r;
  logic wvalid_r;
  logic bready_r;
  logic arvalid_r;
  logic rready_r;

  assign m_axil.awaddr  = addr_q;
  assign m_axil.awprot  = 3'b000;
  assign m_axil.awvalid = awvalid_r;
  assign m_axil.wdata   = wdata_q;
  assign m_axil.wstrb   = wstrb_q;
  assign m_axil.wvalid  = wvalid_r;
  assign m_axil.bready  = bready_r;
  assign m_axil.araddr  = addr_q;
  assign m_axil.arprot  = 3'b000;
  assign m_axil.arvalid = arvalid_r;
  assign m_axil.rready  = rready_r;

  // ---- Aurora user-K TX outputs ----
  logic [255:0] user_k_tx_tdata_r;
  logic         user_k_tx_tvalid_r;

  assign aurora.user_k_tx_tdata  = user_k_tx_tdata_r;
  assign aurora.user_k_tx_tvalid = user_k_tx_tvalid_r;

  // This bridge is the responder only — never drives the framed TX
  // (requests come in on rx_*; it doesn't generate any).
  assign aurora.tx_tdata  = 256'h0;
  assign aurora.tx_tkeep  = 32'h0;
  assign aurora.tx_tlast  = 1'b0;
  assign aurora.tx_tvalid = 1'b0;

  // ---------------------------------------------------------------------
  // Packet build / decode helpers
  // ---------------------------------------------------------------------
  function automatic logic [255:0] pack_read_resp(
      input logic [DATA_W-1:0] data,
      input logic        [1:0] resp);
    logic [255:0] p;
    p          = '0;
    p[7:0]     = OP_READ_RESP;
    p[9:8]     = resp;
    p[95:64]   = {{(32-DATA_W){1'b0}}, data};
    return p;
  endfunction

  // Slices of the incoming packet (combinational).
  wire [7:0]         rx_opcode = aurora.rx_tdata[7:0];
  wire [STRB_W-1:0]  rx_wstrb  = aurora.rx_tdata[8 +: STRB_W];
  wire [ADDR_W-1:0]  rx_addr   = aurora.rx_tdata[32 +: ADDR_W];
  wire [DATA_W-1:0]  rx_wdata  = aurora.rx_tdata[64 +: DATA_W];

  // ---------------------------------------------------------------------
  // FSM — combinational next-state
  // ---------------------------------------------------------------------
  always_comb begin
    state_next = state;
    unique case (state)
      S_IDLE: begin
        if (aurora.rx_tvalid && aurora.rx_tlast) begin
          unique case (rx_opcode)
            OP_WRITE_REQ: state_next = S_W_DRIVE;
            OP_READ_REQ:  state_next = S_R_AR;
            default:      state_next = S_IDLE;  // unknown → drop
          endcase
        end
      end

      S_W_DRIVE:
        // Wait for both AW and W to complete (using the registered
        // _done flags plus any handshake completing this very cycle).
        if ((aw_done_q || (awvalid_r && m_axil.awready)) &&
            (w_done_q  || (wvalid_r  && m_axil.wready)))
          state_next = S_W_B;

      S_W_B: if (m_axil.bvalid && bready_r) state_next = S_IDLE;

      S_R_AR: if (m_axil.arready)              state_next = S_R_R;

      S_R_R:  if (m_axil.rvalid)               state_next = S_R_TX;

      S_R_TX: if (aurora.user_k_tx_tready)     state_next = S_IDLE;

      default: state_next = S_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------
  // FSM — registered state and outputs
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      state              <= S_IDLE;
      addr_q             <= '0;
      wdata_q            <= '0;
      wstrb_q            <= '0;
      rdata_q            <= '0;
      rresp_q            <= 2'b00;
      aw_done_q          <= 1'b0;
      w_done_q           <= 1'b0;
      awvalid_r          <= 1'b0;
      wvalid_r           <= 1'b0;
      bready_r           <= 1'b0;
      arvalid_r          <= 1'b0;
      rready_r           <= 1'b0;
      user_k_tx_tdata_r  <= '0;
      user_k_tx_tvalid_r <= 1'b0;
    end else begin
      // ---- Latch incoming request on transition out of S_IDLE ----
      if (state == S_IDLE && aurora.rx_tvalid && aurora.rx_tlast) begin
        unique case (rx_opcode)
          OP_WRITE_REQ: begin
            addr_q    <= rx_addr;
            wdata_q   <= rx_wdata;
            wstrb_q   <= rx_wstrb;
            awvalid_r <= 1'b1;
            wvalid_r  <= 1'b1;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
          end
          OP_READ_REQ: begin
            addr_q    <= rx_addr;
            arvalid_r <= 1'b1;
          end
          default: ;
        endcase
      end

      // ---- AXI-Lite write phase ----
      if (state == S_W_DRIVE) begin
        if (awvalid_r && m_axil.awready) begin
          awvalid_r <= 1'b0;
          aw_done_q <= 1'b1;
        end
        if (wvalid_r && m_axil.wready) begin
          wvalid_r <= 1'b0;
          w_done_q <= 1'b1;
        end
        if ((aw_done_q || (awvalid_r && m_axil.awready)) &&
            (w_done_q  || (wvalid_r  && m_axil.wready))) begin
          bready_r <= 1'b1;
        end
      end

      if (state == S_W_B && m_axil.bvalid && bready_r) begin
        bready_r  <= 1'b0;
        aw_done_q <= 1'b0;
        w_done_q  <= 1'b0;
      end

      // ---- AXI-Lite read phase ----
      if (state == S_R_AR && m_axil.arready) begin
        arvalid_r <= 1'b0;
        rready_r  <= 1'b1;
      end

      if (state == S_R_R && m_axil.rvalid) begin
        rdata_q   <= m_axil.rdata;
        rresp_q   <= m_axil.rresp;
        rready_r  <= 1'b0;
      end

      // ---- Build / drive READ_RESP on user-K TX ----
      if (state_next == S_R_TX && state != S_R_TX) begin
        // Use either the just-latched rdata_q or, on the same-cycle
        // transition, the live m_axil.rdata.
        user_k_tx_tdata_r <= pack_read_resp(
                               (state == S_R_R && m_axil.rvalid)
                                 ? m_axil.rdata : rdata_q,
                               (state == S_R_R && m_axil.rvalid)
                                 ? m_axil.rresp : rresp_q);
        user_k_tx_tvalid_r <= 1'b1;
      end
      if (state == S_R_TX && aurora.user_k_tx_tready) begin
        user_k_tx_tvalid_r <= 1'b0;
      end

      state <= state_next;
    end
  end

endmodule : aurora_to_axil
