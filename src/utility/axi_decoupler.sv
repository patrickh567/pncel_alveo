// *************************************************************************
//
// AXI4 (full) decoupler — direction-agnostic.
//
// Sits between an upstream master and a downstream slave on a single
// `axi_if` bus and isolates them while `decouple` is asserted.  All data,
// address, ID, and protocol-attribute fields pass through unchanged at
// all times; the `*valid` and `*ready` handshake signals are gated to 0
// when `decouple == 1` so neither side observes any progress on the bus.
//
// Modport convention:
//   * `s_axi` (slave port)  — connects to whichever side carries the
//                              MASTER role on this interface (the one that
//                              issues transactions).
//   * `m_axi` (master port) — connects to whichever side carries the
//                              SLAVE role (the one that responds).
//
// So for the host_switch → PR partition control path the static region's
// `m_axil_dynamic` master attaches to `s_axi`, and the PR partition's
// `s_axil` slave attaches to `m_axi`.  For an HBM port the PR partition's
// `m_axi_hbm_NN` master attaches to `s_axi`, and the static region's
// `s_axi_hbm_NN` slave attaches to `m_axi`.  The decoupler is symmetric
// from a wiring standpoint — only the two endpoints differ.
//
// Decouple semantics (when `decouple == 1`):
//   * Every M→S `*valid` is forced low → no new transactions cross.
//   * Every S→M `*valid` is forced low → no responses cross.
//   * Every `*ready` (both directions) is forced low → neither side can
//     accept anything from the other.  This is a hard freeze.
//
// Software usage during a PR cycle:
//   1. Stop sending new transactions to the PR partition from the host.
//   2. Wait for any in-flight transactions to drain.
//   3. Assert `decouple` (write the bit in the static register that
//      drives this signal — see `alveo_u50_static.sv`).
//   4. Trigger reconfiguration via ICAP / PCAP / MCAP.
//   5. After reconfiguration completes, deassert `decouple`.
//   6. Resume host traffic.
//
// The decoupler is purely combinational pass-through — no clock or
// reset is needed because no state is held inside it.  The `decouple`
// input must be synchronous with `axi_if.aclk`; in this project it
// originates in the static register map (host clock domain) and is
// already in the right domain.
//
// *************************************************************************
`timescale 1ns/1ps
module axi_decoupler (
  input  logic   decouple,
  axi_if.slave   s_axi,    // upstream: master attaches here
  axi_if.master  m_axi     // downstream: slave attaches here
);

  // ---------------------------------------------------------------------
  // Master → slave direction (s_axi inputs forwarded to m_axi outputs).
  // Data and protocol-attribute fields pass through unchanged; *valid
  // signals get gated.  bready / rready (also master→slave) are gated
  // so that the upstream master cannot accept responses while decoupled.
  // ---------------------------------------------------------------------

  // Write address channel
  assign m_axi.awid     = s_axi.awid;
  assign m_axi.awaddr   = s_axi.awaddr;
  assign m_axi.awlen    = s_axi.awlen;
  assign m_axi.awsize   = s_axi.awsize;
  assign m_axi.awburst  = s_axi.awburst;
  assign m_axi.awlock   = s_axi.awlock;
  assign m_axi.awcache  = s_axi.awcache;
  assign m_axi.awprot   = s_axi.awprot;
  assign m_axi.awqos    = s_axi.awqos;
  assign m_axi.awregion = s_axi.awregion;
  assign m_axi.awvalid  = decouple ? 1'b0 : s_axi.awvalid;

  // Write data channel
  assign m_axi.wdata    = s_axi.wdata;
  assign m_axi.wstrb    = s_axi.wstrb;
  assign m_axi.wlast    = s_axi.wlast;
  assign m_axi.wvalid   = decouple ? 1'b0 : s_axi.wvalid;

  // Write response channel (master accepting)
  assign m_axi.bready   = decouple ? 1'b0 : s_axi.bready;

  // Read address channel
  assign m_axi.arid     = s_axi.arid;
  assign m_axi.araddr   = s_axi.araddr;
  assign m_axi.arlen    = s_axi.arlen;
  assign m_axi.arsize   = s_axi.arsize;
  assign m_axi.arburst  = s_axi.arburst;
  assign m_axi.arlock   = s_axi.arlock;
  assign m_axi.arcache  = s_axi.arcache;
  assign m_axi.arprot   = s_axi.arprot;
  assign m_axi.arqos    = s_axi.arqos;
  assign m_axi.arregion = s_axi.arregion;
  assign m_axi.arvalid  = decouple ? 1'b0 : s_axi.arvalid;

  // Read data channel (master accepting)
  assign m_axi.rready   = decouple ? 1'b0 : s_axi.rready;

  // ---------------------------------------------------------------------
  // Slave → master direction (m_axi inputs forwarded to s_axi outputs).
  // Data and protocol-attribute fields pass through; *ready and *valid
  // get gated.
  // ---------------------------------------------------------------------
  assign s_axi.awready  = decouple ? 1'b0 : m_axi.awready;
  assign s_axi.wready   = decouple ? 1'b0 : m_axi.wready;
  assign s_axi.bid      = m_axi.bid;
  assign s_axi.bresp    = m_axi.bresp;
  assign s_axi.bvalid   = decouple ? 1'b0 : m_axi.bvalid;
  assign s_axi.arready  = decouple ? 1'b0 : m_axi.arready;
  assign s_axi.rid      = m_axi.rid;
  assign s_axi.rdata    = m_axi.rdata;
  assign s_axi.rresp    = m_axi.rresp;
  assign s_axi.rlast    = m_axi.rlast;
  assign s_axi.rvalid   = decouple ? 1'b0 : m_axi.rvalid;

endmodule: axi_decoupler
