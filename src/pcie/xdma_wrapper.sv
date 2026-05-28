// *************************************************************************
//
// Wrapper around Xilinx XDMA IP for Alveo U50
//
// PCIe Gen3 x16, AXI4-MM 512-bit master, AXI-Lite 32-bit slave
//
// *************************************************************************
`timescale 1ns/1ps
module xdma_wrapper (
  // PCIe reference clock and reset
  input               sys_clk,
  input               sys_clk_gt,
  input               sys_rst_n,

  // PCIe lanes
  output       [15:0] pci_exp_txp,
  output       [15:0] pci_exp_txn,
  input        [15:0] pci_exp_rxp,
  input        [15:0] pci_exp_rxn,

  // User clock and reset (output from XDMA, 250MHz)
  output              axi_aclk,
  output              axi_aresetn,

  // Link status
  output              user_lnk_up,

  // AXI4-MM master interface (DMA, 512-bit)
  axi_if.master       m_axi,

  // AXI-Lite master interface (driven by BAR0, 32-bit)
  axi_if.master       m_axil,

  // User interrupts
  input         [0:0] usr_irq_req,
  output        [0:0] usr_irq_ack,
  output              msi_enable,
  output        [2:0] msi_vector_width,

  // PCIe configuration management
  input        [18:0] cfg_mgmt_addr,
  input               cfg_mgmt_write,
  input        [31:0] cfg_mgmt_write_data,
  input         [3:0] cfg_mgmt_byte_enable,
  input               cfg_mgmt_read,
  output       [31:0] cfg_mgmt_read_data,
  output              cfg_mgmt_read_write_done
);

  xdma_0 u_xdma (
    // PCIe
    .sys_clk                   (sys_clk),
    .sys_clk_gt                (sys_clk_gt),
    .sys_rst_n                 (sys_rst_n),
    .user_lnk_up               (user_lnk_up),
    .pci_exp_txp               (pci_exp_txp),
    .pci_exp_txn               (pci_exp_txn),
    .pci_exp_rxp               (pci_exp_rxp),
    .pci_exp_rxn               (pci_exp_rxn),

    // User clock/reset
    .axi_aclk                  (axi_aclk),
    .axi_aresetn               (axi_aresetn),

    // User interrupts
    .usr_irq_req               (usr_irq_req),
    .usr_irq_ack               (usr_irq_ack),
    .msi_enable                (msi_enable),
    .msi_vector_width          (msi_vector_width),

    // AXI4-MM master
    .m_axi_awid                (m_axi.awid),
    .m_axi_awaddr              (m_axi.awaddr),
    .m_axi_awlen               (m_axi.awlen),
    .m_axi_awsize              (m_axi.awsize),
    .m_axi_awburst             (m_axi.awburst),
    .m_axi_awlock              (m_axi.awlock),
    .m_axi_awcache             (m_axi.awcache),
    .m_axi_awprot              (m_axi.awprot),
    .m_axi_awvalid             (m_axi.awvalid),
    .m_axi_awready             (m_axi.awready),
    .m_axi_wdata               (m_axi.wdata),
    .m_axi_wstrb               (m_axi.wstrb),
    .m_axi_wlast               (m_axi.wlast),
    .m_axi_wvalid              (m_axi.wvalid),
    .m_axi_wready              (m_axi.wready),
    .m_axi_bid                 (m_axi.bid),
    .m_axi_bresp               (m_axi.bresp),
    .m_axi_bvalid              (m_axi.bvalid),
    .m_axi_bready              (m_axi.bready),
    .m_axi_arid                (m_axi.arid),
    .m_axi_araddr              (m_axi.araddr),
    .m_axi_arlen               (m_axi.arlen),
    .m_axi_arsize              (m_axi.arsize),
    .m_axi_arburst             (m_axi.arburst),
    .m_axi_arlock              (m_axi.arlock),
    .m_axi_arcache             (m_axi.arcache),
    .m_axi_arprot              (m_axi.arprot),
    .m_axi_arvalid             (m_axi.arvalid),
    .m_axi_arready             (m_axi.arready),
    .m_axi_rid                 (m_axi.rid),
    .m_axi_rdata               (m_axi.rdata),
    .m_axi_rresp               (m_axi.rresp),
    .m_axi_rlast               (m_axi.rlast),
    .m_axi_rvalid              (m_axi.rvalid),
    .m_axi_rready              (m_axi.rready),

    // AXI-Lite master (from BAR0)
    .m_axil_awaddr             (m_axil.awaddr),
    .m_axil_awprot             (m_axil.awprot),
    .m_axil_awvalid            (m_axil.awvalid),
    .m_axil_awready            (m_axil.awready),
    .m_axil_wdata              (m_axil.wdata),
    .m_axil_wstrb              (m_axil.wstrb),
    .m_axil_wvalid             (m_axil.wvalid),
    .m_axil_wready             (m_axil.wready),
    .m_axil_bresp              (m_axil.bresp),
    .m_axil_bvalid             (m_axil.bvalid),
    .m_axil_bready             (m_axil.bready),
    .m_axil_araddr             (m_axil.araddr),
    .m_axil_arprot             (m_axil.arprot),
    .m_axil_arvalid            (m_axil.arvalid),
    .m_axil_arready            (m_axil.arready),
    .m_axil_rdata              (m_axil.rdata),
    .m_axil_rresp              (m_axil.rresp),
    .m_axil_rvalid             (m_axil.rvalid),
    .m_axil_rready             (m_axil.rready),

    // PCIe configuration management
    .cfg_mgmt_addr             (cfg_mgmt_addr),
    .cfg_mgmt_write            (cfg_mgmt_write),
    .cfg_mgmt_write_data       (cfg_mgmt_write_data),
    .cfg_mgmt_byte_enable      (cfg_mgmt_byte_enable),
    .cfg_mgmt_read             (cfg_mgmt_read),
    .cfg_mgmt_read_data        (cfg_mgmt_read_data),
    .cfg_mgmt_read_write_done  (cfg_mgmt_read_write_done),

    // GT debug/status - tie off inputs
    .gt_pcieuserratedone       (16'b0),
    .gt_loopback               (48'b0),
    .gt_txprbsforceerr         (16'b0),
    .gt_txinhibit              (16'b0),
    .gt_txprbssel              (64'b0),
    .gt_rxprbssel              (64'b0),
    .gt_rxprbscntreset         (16'b0),
    .gt_dmonfiforeset          (16'b0),
    .gt_dmonitorclk            (16'b0),
    .gt_txpmareset             (16'b0),
    .gt_rxpmareset             (16'b0),
    .gt_txpcsreset             (16'b0),
    .gt_rxpcsreset             (16'b0),
    .gt_rxbufreset             (16'b0),
    .gt_rxcdrreset             (16'b0),
    .gt_rxdfelpmreset          (16'b0),

    // GT debug/status - leave outputs unconnected
    .gt_txelecidle             (),
    .gt_txresetdone            (),
    .gt_rxresetdone            (),
    .gt_rxpmaresetdone         (),
    .gt_txphaligndone          (),
    .gt_txphinitdone           (),
    .gt_txdlysresetdone        (),
    .gt_rxphaligndone          (),
    .gt_rxdlysresetdone        (),
    .gt_rxsyncdone             (),
    .gt_eyescandataerror       (),
    .gt_rxprbserr              (),
    .gt_dmonitorout            (),
    .gt_rxcommadet             (),
    .gt_phystatus              (),
    .gt_rxvalid                (),
    .gt_rxcdrlock              (),
    .gt_pcierateidle           (),
    .gt_pcieuserratestart      (),
    .gt_gtpowergood            (),
    .gt_cplllock               (),
    .gt_rxoutclk               (),
    .gt_rxrecclkout            (),
    .gt_qpll1lock              (),
    .gt_rxstatus               (),
    .gt_rxbufstatus            (),
    .gt_bufgtdiv               (),
    .phy_txeq_ctrl             (),
    .phy_txeq_preset           (),
    .phy_rst_fsm               (),
    .phy_txeq_fsm              (),
    .phy_rxeq_fsm              (),
    .phy_rst_idle              (),
    .phy_rrst_n                (),
    .phy_prst_n                (),
    .gt_qpll0lock              (),
    .gt_gen34_eios_det         (),
    .gt_txoutclk               (),
    .gt_txoutclkfabric         (),
    .gt_rxoutclkfabric         (),
    .gt_txoutclkpcs            (),
    .gt_rxoutclkpcs            (),
    .gt_txprogdivresetdone     (),
    .gt_txpmaresetdone         (),
    .gt_txsyncdone             (),
    .gt_rxprbslocked           (),

    // Pipe simulation interface - tie off
    .common_commands_in        (26'b0),
    .pipe_rx_0_sigs            (84'b0),
    .pipe_rx_1_sigs            (84'b0),
    .pipe_rx_2_sigs            (84'b0),
    .pipe_rx_3_sigs            (84'b0),
    .pipe_rx_4_sigs            (84'b0),
    .pipe_rx_5_sigs            (84'b0),
    .pipe_rx_6_sigs            (84'b0),
    .pipe_rx_7_sigs            (84'b0),
    .pipe_rx_8_sigs            (84'b0),
    .pipe_rx_9_sigs            (84'b0),
    .pipe_rx_10_sigs           (84'b0),
    .pipe_rx_11_sigs           (84'b0),
    .pipe_rx_12_sigs           (84'b0),
    .pipe_rx_13_sigs           (84'b0),
    .pipe_rx_14_sigs           (84'b0),
    .pipe_rx_15_sigs           (84'b0),
    .common_commands_out       (),
    .pipe_tx_0_sigs            (),
    .pipe_tx_1_sigs            (),
    .pipe_tx_2_sigs            (),
    .pipe_tx_3_sigs            (),
    .pipe_tx_4_sigs            (),
    .pipe_tx_5_sigs            (),
    .pipe_tx_6_sigs            (),
    .pipe_tx_7_sigs            (),
    .pipe_tx_8_sigs            (),
    .pipe_tx_9_sigs            (),
    .pipe_tx_10_sigs           (),
    .pipe_tx_11_sigs           (),
    .pipe_tx_12_sigs           (),
    .pipe_tx_13_sigs           (),
    .pipe_tx_14_sigs           (),
    .pipe_tx_15_sigs           ()
  );

endmodule: xdma_wrapper
