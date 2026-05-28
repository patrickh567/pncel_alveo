// *************************************************************************
//
// Aurora-design dynamic region — interface wrapper.
//
// Same role as `alveo_u50_dynamic` (used by the host design): keeps a
// clean axi_if / aurora_if port surface for the rest of the project,
// but flattens every interface into individual signals and forwards
// them to the partition top — `aurora_region` in this design —
// which has flat ports as DFX requires.
//
// *************************************************************************
`timescale 1ns/1ps

`define AXI_IF_TO_FLAT(PFX)               \
  .PFX``_awid     (PFX.awid),             \
  .PFX``_awaddr   (PFX.awaddr),           \
  .PFX``_awlen    (PFX.awlen),            \
  .PFX``_awsize   (PFX.awsize),           \
  .PFX``_awburst  (PFX.awburst),          \
  .PFX``_awlock   (PFX.awlock),           \
  .PFX``_awcache  (PFX.awcache),          \
  .PFX``_awprot   (PFX.awprot),           \
  .PFX``_awqos    (PFX.awqos),            \
  .PFX``_awregion (PFX.awregion),         \
  .PFX``_awvalid  (PFX.awvalid),          \
  .PFX``_awready  (PFX.awready),          \
  .PFX``_wdata    (PFX.wdata),            \
  .PFX``_wstrb    (PFX.wstrb),            \
  .PFX``_wlast    (PFX.wlast),            \
  .PFX``_wvalid   (PFX.wvalid),           \
  .PFX``_wready   (PFX.wready),           \
  .PFX``_bid      (PFX.bid),              \
  .PFX``_bresp    (PFX.bresp),            \
  .PFX``_bvalid   (PFX.bvalid),           \
  .PFX``_bready   (PFX.bready),           \
  .PFX``_arid     (PFX.arid),             \
  .PFX``_araddr   (PFX.araddr),           \
  .PFX``_arlen    (PFX.arlen),            \
  .PFX``_arsize   (PFX.arsize),           \
  .PFX``_arburst  (PFX.arburst),          \
  .PFX``_arlock   (PFX.arlock),           \
  .PFX``_arcache  (PFX.arcache),          \
  .PFX``_arprot   (PFX.arprot),           \
  .PFX``_arqos    (PFX.arqos),            \
  .PFX``_arregion (PFX.arregion),         \
  .PFX``_arvalid  (PFX.arvalid),          \
  .PFX``_arready  (PFX.arready),          \
  .PFX``_rid      (PFX.rid),              \
  .PFX``_rdata    (PFX.rdata),            \
  .PFX``_rresp    (PFX.rresp),            \
  .PFX``_rlast    (PFX.rlast),            \
  .PFX``_rvalid   (PFX.rvalid),           \
  .PFX``_rready   (PFX.rready)

module alveo_u50_dynamic_aurora (
  input          aresetn,

  axi_if.slave   s_axil,

  axi_if.master  m_axi_hbm_00,
  axi_if.master  m_axi_hbm_01,
  axi_if.master  m_axi_hbm_02,
  axi_if.master  m_axi_hbm_03,
  axi_if.master  m_axi_hbm_04,
  axi_if.master  m_axi_hbm_05,
  axi_if.master  m_axi_hbm_06,
  axi_if.master  m_axi_hbm_07,
  axi_if.master  m_axi_hbm_08,
  axi_if.master  m_axi_hbm_09,
  axi_if.master  m_axi_hbm_10,
  axi_if.master  m_axi_hbm_11,
  axi_if.master  m_axi_hbm_12,
  axi_if.master  m_axi_hbm_13,
  axi_if.master  m_axi_hbm_14,
  axi_if.master  m_axi_hbm_15,
  axi_if.master  m_axi_hbm_16,
  axi_if.master  m_axi_hbm_17,
  axi_if.master  m_axi_hbm_18,
  axi_if.master  m_axi_hbm_19,
  axi_if.master  m_axi_hbm_20,
  axi_if.master  m_axi_hbm_21,
  axi_if.master  m_axi_hbm_22,
  axi_if.master  m_axi_hbm_23,
  axi_if.master  m_axi_hbm_24,
  axi_if.master  m_axi_hbm_25,
  axi_if.master  m_axi_hbm_26,
  axi_if.master  m_axi_hbm_27,
  axi_if.master  m_axi_hbm_28,
  axi_if.master  m_axi_hbm_29,
  axi_if.master  m_axi_hbm_30,
  axi_if.master  m_axi_hbm_31,

  aurora_if.rm   aurora
);

  aurora_region u_region (
    .aclk   (s_axil.aclk),
    .aresetn(aresetn),
    `AXI_IF_TO_FLAT(s_axil),
    `AXI_IF_TO_FLAT(m_axi_hbm_00),
    `AXI_IF_TO_FLAT(m_axi_hbm_01),
    `AXI_IF_TO_FLAT(m_axi_hbm_02),
    `AXI_IF_TO_FLAT(m_axi_hbm_03),
    `AXI_IF_TO_FLAT(m_axi_hbm_04),
    `AXI_IF_TO_FLAT(m_axi_hbm_05),
    `AXI_IF_TO_FLAT(m_axi_hbm_06),
    `AXI_IF_TO_FLAT(m_axi_hbm_07),
    `AXI_IF_TO_FLAT(m_axi_hbm_08),
    `AXI_IF_TO_FLAT(m_axi_hbm_09),
    `AXI_IF_TO_FLAT(m_axi_hbm_10),
    `AXI_IF_TO_FLAT(m_axi_hbm_11),
    `AXI_IF_TO_FLAT(m_axi_hbm_12),
    `AXI_IF_TO_FLAT(m_axi_hbm_13),
    `AXI_IF_TO_FLAT(m_axi_hbm_14),
    `AXI_IF_TO_FLAT(m_axi_hbm_15),
    `AXI_IF_TO_FLAT(m_axi_hbm_16),
    `AXI_IF_TO_FLAT(m_axi_hbm_17),
    `AXI_IF_TO_FLAT(m_axi_hbm_18),
    `AXI_IF_TO_FLAT(m_axi_hbm_19),
    `AXI_IF_TO_FLAT(m_axi_hbm_20),
    `AXI_IF_TO_FLAT(m_axi_hbm_21),
    `AXI_IF_TO_FLAT(m_axi_hbm_22),
    `AXI_IF_TO_FLAT(m_axi_hbm_23),
    `AXI_IF_TO_FLAT(m_axi_hbm_24),
    `AXI_IF_TO_FLAT(m_axi_hbm_25),
    `AXI_IF_TO_FLAT(m_axi_hbm_26),
    `AXI_IF_TO_FLAT(m_axi_hbm_27),
    `AXI_IF_TO_FLAT(m_axi_hbm_28),
    `AXI_IF_TO_FLAT(m_axi_hbm_29),
    `AXI_IF_TO_FLAT(m_axi_hbm_30),
    `AXI_IF_TO_FLAT(m_axi_hbm_31),

    .aurora_user_clk         (aurora.user_clk),
    .aurora_user_aresetn     (aurora.user_aresetn),
    .aurora_channel_up       (aurora.channel_up),
    .aurora_tx_tdata         (aurora.tx_tdata),
    .aurora_tx_tkeep         (aurora.tx_tkeep),
    .aurora_tx_tlast         (aurora.tx_tlast),
    .aurora_tx_tvalid        (aurora.tx_tvalid),
    .aurora_tx_tready        (aurora.tx_tready),
    .aurora_rx_tdata         (aurora.rx_tdata),
    .aurora_rx_tkeep         (aurora.rx_tkeep),
    .aurora_rx_tlast         (aurora.rx_tlast),
    .aurora_rx_tvalid        (aurora.rx_tvalid),
    .aurora_user_k_tx_tdata  (aurora.user_k_tx_tdata),
    .aurora_user_k_tx_tvalid (aurora.user_k_tx_tvalid),
    .aurora_user_k_tx_tready (aurora.user_k_tx_tready),
    .aurora_user_k_rx_tdata  (aurora.user_k_rx_tdata),
    .aurora_user_k_rx_tvalid (aurora.user_k_rx_tvalid)
  );

endmodule : alveo_u50_dynamic_aurora

`undef AXI_IF_TO_FLAT
