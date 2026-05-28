// *************************************************************************
//
// AXI-Lite ↔ Aurora 64b/66b packet bridge.
//
// Accepts AXI-Lite transactions on a slave port and serialises them
// onto the aurora user-side stream as fixed-format single-beat packets
// (256-bit, tlast=1, tkeep all-ones) — requests egress on the regular
// data TX (`aurora.tx_*`).  For reads, it waits for a matching
// response packet on the user-K RX side (`aurora.user_k_rx_*`) and
// unpacks it into the AXI-Lite R channel; writes are acked locally on
// the B channel as soon as the WRITE_REQ packet egresses (this bridge
// does not round-trip a write response over Aurora).
//
// Packet format (single 256-bit beat, tlast=1, tkeep=32'hFFFFFFFF):
//
//   byte  0    : opcode
//                  0x01 WRITE_REQ  (master → remote)
//                  0x02 READ_REQ   (master → remote)
//                  0x82 READ_RESP  (remote → master)
//   byte  1    : wstrb (WRITE_REQ, low STRB_W bits)
//                rresp (READ_RESP, low 2 bits)
//   bytes 2-3  : reserved (0)
//   bytes 4-7  : address (LE, ADDR_W ≤ 32 bits)
//   bytes 8-11 : write data (WRITE_REQ) / read data (READ_RESP), LE
//   bytes 12-31: padding (0)
//
// Clock domain
//   Both `s_axil` and `aurora` must be in the same clock domain — the
//   module clocks itself off `aurora.user_clk` and reset off
//   `aurora.user_aresetn`.  Wire `s_axil.aclk` to the same source.
//
// Concurrency
//   Single transaction at a time.  When both AW+W and AR are pending,
//   writes win (so a long-stalled read response packet can't block a
//   write that's already in flight).  Reads block until the matching
//   READ_RESP packet arrives on the user-K RX side; non-READ_RESP
//   packets received while waiting are dropped.
//
// *************************************************************************
`timescale 1ns/1ps
module axil_to_aurora #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32
) (
  axi_lite_if.slave s_axil,
  aurora_if.rm      aurora
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
    S_W_GOT_AW,   // latched AW, waiting for W
    S_W_GOT_W,    // latched W,  waiting for AW
    S_W_TX,       // egressing WRITE_REQ packet
    S_W_B,        // driving B response
    S_R_TX,       // egressing READ_REQ packet
    S_R_WAIT,     // waiting for READ_RESP on RX
    S_R_R         // driving R response
  } state_t;

  state_t state, state_next;

  // ---- Latched transaction fields ----
  logic [ADDR_W-1:0] addr_q;
  logic [DATA_W-1:0] data_q;
  logic [STRB_W-1:0] wstrb_q;

  logic [DATA_W-1:0] rdata_q;
  logic        [1:0] rresp_q;

  // ---- AXI-Lite output registers ----
  logic              awready_r, wready_r;
  logic              bvalid_r;
  logic              arready_r;
  logic              rvalid_r;

  assign s_axil.awready = awready_r;
  assign s_axil.wready  = wready_r;
  assign s_axil.bresp   = 2'b00;     // OKAY (write was successfully sent)
  assign s_axil.bvalid  = bvalid_r;
  assign s_axil.arready = arready_r;
  assign s_axil.rdata   = rdata_q;
  assign s_axil.rresp   = rresp_q;
  assign s_axil.rvalid  = rvalid_r;

  // ---- Aurora TX outputs ----
  logic [255:0] tx_tdata_r;
  logic         tx_tvalid_r;

  assign aurora.tx_tdata  = tx_tdata_r;
  assign aurora.tx_tkeep  = 32'hFFFFFFFF;
  assign aurora.tx_tlast  = tx_tvalid_r;     // single-beat packet
  assign aurora.tx_tvalid = tx_tvalid_r;

  // This bridge is the request initiator only — never drives the
  // user-K TX side (that's where remote-side responses come back from
  // the *other* end of the link).  Hold it idle.
  assign aurora.user_k_tx_tdata  = 256'h0;
  assign aurora.user_k_tx_tvalid = 1'b0;

  // ---------------------------------------------------------------------
  // Packet construction helpers
  //
  // Layout matches the comment block at the top: all fields little-endian
  // within their byte spans, padded with zeros up to 256 bits.
  // ---------------------------------------------------------------------
  function automatic logic [255:0] pack_write_req(
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] data,
      input logic [STRB_W-1:0] strb);
    logic [255:0] p;
    p              = '0;
    p[7:0]         = OP_WRITE_REQ;
    p[15:8]        = {{(8-STRB_W){1'b0}}, strb};
    p[63:32]       = {{(32-ADDR_W){1'b0}}, addr};
    p[95:64]       = {{(32-DATA_W){1'b0}}, data};
    return p;
  endfunction

  function automatic logic [255:0] pack_read_req(
      input logic [ADDR_W-1:0] addr);
    logic [255:0] p;
    p              = '0;
    p[7:0]         = OP_READ_REQ;
    p[63:32]       = {{(32-ADDR_W){1'b0}}, addr};
    return p;
  endfunction

  // ---------------------------------------------------------------------
  // FSM — combinational next-state
  // ---------------------------------------------------------------------
  always_comb begin
    state_next = state;
    unique case (state)
      S_IDLE: begin
        // Writes win when both are pending so an in-flight write can't
        // be stalled behind a read awaiting an RX response.
        if (s_axil.awvalid && s_axil.wvalid)
          state_next = S_W_TX;
        else if (s_axil.awvalid)
          state_next = S_W_GOT_AW;
        else if (s_axil.wvalid)
          state_next = S_W_GOT_W;
        else if (s_axil.arvalid)
          state_next = S_R_TX;
      end

      S_W_GOT_AW: if (s_axil.wvalid)  state_next = S_W_TX;
      S_W_GOT_W:  if (s_axil.awvalid) state_next = S_W_TX;

      S_W_TX:
        if (aurora.tx_tready) state_next = S_W_B;

      S_W_B:
        if (s_axil.bready)    state_next = S_IDLE;

      S_R_TX:
        if (aurora.tx_tready) state_next = S_R_WAIT;

      S_R_WAIT:
        if (aurora.user_k_rx_tvalid && aurora.user_k_rx_tdata[7:0] == OP_READ_RESP)
          state_next = S_R_R;

      S_R_R:
        if (s_axil.rready)    state_next = S_IDLE;

      default: state_next = S_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------
  // FSM — registered state and outputs
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      state       <= S_IDLE;
      addr_q      <= '0;
      data_q      <= '0;
      wstrb_q     <= '0;
      rdata_q     <= '0;
      rresp_q     <= 2'b00;
      awready_r   <= 1'b0;
      wready_r    <= 1'b0;
      bvalid_r    <= 1'b0;
      arready_r   <= 1'b0;
      rvalid_r    <= 1'b0;
      tx_tdata_r  <= '0;
      tx_tvalid_r <= 1'b0;
    end else begin
      // Default: deassert all single-cycle handshake outputs.
      awready_r <= 1'b0;
      wready_r  <= 1'b0;
      arready_r <= 1'b0;

      // ---- Channel-handshake captures ----
      if (state == S_IDLE || state == S_W_GOT_W) begin
        if (s_axil.awvalid && !awready_r) begin
          addr_q    <= s_axil.awaddr;
          awready_r <= 1'b1;
        end
      end
      if (state == S_IDLE || state == S_W_GOT_AW) begin
        if (s_axil.wvalid && !wready_r) begin
          data_q   <= s_axil.wdata;
          wstrb_q  <= s_axil.wstrb;
          wready_r <= 1'b1;
        end
      end
      if (state == S_IDLE && !s_axil.awvalid && !s_axil.wvalid) begin
        if (s_axil.arvalid && !arready_r) begin
          addr_q    <= s_axil.araddr;
          arready_r <= 1'b1;
        end
      end

      // ---- Same-cycle latches when entering S_W_TX directly ----
      if (state == S_IDLE && s_axil.awvalid && s_axil.wvalid) begin
        addr_q    <= s_axil.awaddr;
        data_q    <= s_axil.wdata;
        wstrb_q   <= s_axil.wstrb;
        awready_r <= 1'b1;
        wready_r  <= 1'b1;
      end

      // ---- TX packet driver ----
      // Drive the packet on entry to S_W_TX / S_R_TX, hold until tready.
      // The pack functions take whichever fields are already latched and
      // grab the rest live from the bus, since non-blocking assigns to
      // addr_q / data_q / wstrb_q in this same cycle aren't visible
      // inside this always_ff block.
      if (state_next == S_W_TX && state != S_W_TX) begin
        unique case (state)
          S_IDLE:     tx_tdata_r <= pack_write_req(s_axil.awaddr, s_axil.wdata, s_axil.wstrb);
          S_W_GOT_AW: tx_tdata_r <= pack_write_req(addr_q,        s_axil.wdata, s_axil.wstrb);
          S_W_GOT_W:  tx_tdata_r <= pack_write_req(s_axil.awaddr, data_q,       wstrb_q);
          default:    tx_tdata_r <= pack_write_req(addr_q,        data_q,       wstrb_q);
        endcase
        tx_tvalid_r <= 1'b1;
      end
      if (state_next == S_R_TX && state != S_R_TX) begin
        // Coming from S_IDLE — araddr is live; addr_q is being latched
        // this same cycle so isn't visible yet.
        tx_tdata_r  <= pack_read_req(s_axil.araddr);
        tx_tvalid_r <= 1'b1;
      end
      if ((state == S_W_TX || state == S_R_TX) && aurora.tx_tready) begin
        tx_tvalid_r <= 1'b0;
      end

      // ---- B response ----
      if (state == S_W_TX && aurora.tx_tready) begin
        bvalid_r <= 1'b1;
      end
      if (state == S_W_B && s_axil.bready) begin
        bvalid_r <= 1'b0;
      end

      // ---- User-K RX response capture ----
      if (state == S_R_WAIT &&
          aurora.user_k_rx_tvalid &&
          aurora.user_k_rx_tdata[7:0] == OP_READ_RESP) begin
        // bytes 8..11 carry the read data; byte 1 the rresp.
        rdata_q  <= aurora.user_k_rx_tdata[64 +: DATA_W];
        rresp_q  <= aurora.user_k_rx_tdata[9:8];
        rvalid_r <= 1'b1;
      end
      if (state == S_R_R && s_axil.rready) begin
        rvalid_r <= 1'b0;
      end

      state <= state_next;
    end
  end

endmodule : axil_to_aurora
