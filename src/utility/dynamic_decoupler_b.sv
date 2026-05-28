// *************************************************************************
//
// PR-boundary decoupler bank for HBM channels 16..31, plus the RM
// AXI-Lite control plane.
//
// Bundles 16 HBM-channel axi_decoupler instances and the lone AXI-Lite
// (DMA-side control) decoupler.  Static-side mapping (matching
// alveo_u50_static.sv) is 1-to-1 by port number:
//
//   axi_hbm_NN  → HBM port NN  for NN = 16..30
//   axi_hbm_31  → HBM port 31  (via static-side axi_hbm_switch.s01,
//                                merged with the XDMA-direct path on
//                                S00 onto HBM port 31; 4-bit ID, AXI3)
//   axil_dynamic → RM control-plane AXI-Lite (XDMA M_AXIL → RM s_axil)
//
// Each HBM decoupler routes the RM-side master (axi_hbm_NN_dy) to the
// static-side slave (axi_hbm_NN_st).  The AXI-Lite decoupler runs the
// other direction
// (static-side master axil_dynamic_st → RM-side slave axil_dynamic_dy);
// the s_axi / m_axi modport convention on `axi_decoupler` is "upstream
// master → s_axi, downstream slave → m_axi" for both flows.  All
// decouplers gate off the shared `decouple` control bit driven from
// static reg 0 bit 0.
//
// *************************************************************************
`timescale 1ns/1ps
module dynamic_decoupler_b (
  input wire decouple,

  // AXI-Lite control plane (static → dynamic)
  axi_if.slave  axil_dynamic_st,
  axi_if.master axil_dynamic_dy,

  // HBM channels 16..30 + mux (dynamic → static)
  axi_if.slave  axi_hbm_16_dy,
  axi_if.master axi_hbm_16_st,
  axi_if.slave  axi_hbm_17_dy,
  axi_if.master axi_hbm_17_st,
  axi_if.slave  axi_hbm_18_dy,
  axi_if.master axi_hbm_18_st,
  axi_if.slave  axi_hbm_19_dy,
  axi_if.master axi_hbm_19_st,
  axi_if.slave  axi_hbm_20_dy,
  axi_if.master axi_hbm_20_st,
  axi_if.slave  axi_hbm_21_dy,
  axi_if.master axi_hbm_21_st,
  axi_if.slave  axi_hbm_22_dy,
  axi_if.master axi_hbm_22_st,
  axi_if.slave  axi_hbm_23_dy,
  axi_if.master axi_hbm_23_st,
  axi_if.slave  axi_hbm_24_dy,
  axi_if.master axi_hbm_24_st,
  axi_if.slave  axi_hbm_25_dy,
  axi_if.master axi_hbm_25_st,
  axi_if.slave  axi_hbm_26_dy,
  axi_if.master axi_hbm_26_st,
  axi_if.slave  axi_hbm_27_dy,
  axi_if.master axi_hbm_27_st,
  axi_if.slave  axi_hbm_28_dy,
  axi_if.master axi_hbm_28_st,
  axi_if.slave  axi_hbm_29_dy,
  axi_if.master axi_hbm_29_st,
  axi_if.slave  axi_hbm_30_dy,
  axi_if.master axi_hbm_30_st,
  axi_if.slave  axi_hbm_31_dy,
  axi_if.master axi_hbm_31_st
);

  axi_decoupler decouple_axil_dynamic (.decouple(decouple), .s_axi(axil_dynamic_st), .m_axi(axil_dynamic_dy));

  axi_decoupler decouple_axi_hbm_16  (.decouple(decouple), .s_axi(axi_hbm_16_dy),  .m_axi(axi_hbm_16_st));
  axi_decoupler decouple_axi_hbm_17  (.decouple(decouple), .s_axi(axi_hbm_17_dy),  .m_axi(axi_hbm_17_st));
  axi_decoupler decouple_axi_hbm_18  (.decouple(decouple), .s_axi(axi_hbm_18_dy),  .m_axi(axi_hbm_18_st));
  axi_decoupler decouple_axi_hbm_19  (.decouple(decouple), .s_axi(axi_hbm_19_dy),  .m_axi(axi_hbm_19_st));
  axi_decoupler decouple_axi_hbm_20  (.decouple(decouple), .s_axi(axi_hbm_20_dy),  .m_axi(axi_hbm_20_st));
  axi_decoupler decouple_axi_hbm_21  (.decouple(decouple), .s_axi(axi_hbm_21_dy),  .m_axi(axi_hbm_21_st));
  axi_decoupler decouple_axi_hbm_22  (.decouple(decouple), .s_axi(axi_hbm_22_dy),  .m_axi(axi_hbm_22_st));
  axi_decoupler decouple_axi_hbm_23  (.decouple(decouple), .s_axi(axi_hbm_23_dy),  .m_axi(axi_hbm_23_st));
  axi_decoupler decouple_axi_hbm_24  (.decouple(decouple), .s_axi(axi_hbm_24_dy),  .m_axi(axi_hbm_24_st));
  axi_decoupler decouple_axi_hbm_25  (.decouple(decouple), .s_axi(axi_hbm_25_dy),  .m_axi(axi_hbm_25_st));
  axi_decoupler decouple_axi_hbm_26  (.decouple(decouple), .s_axi(axi_hbm_26_dy),  .m_axi(axi_hbm_26_st));
  axi_decoupler decouple_axi_hbm_27  (.decouple(decouple), .s_axi(axi_hbm_27_dy),  .m_axi(axi_hbm_27_st));
  axi_decoupler decouple_axi_hbm_28  (.decouple(decouple), .s_axi(axi_hbm_28_dy),  .m_axi(axi_hbm_28_st));
  axi_decoupler decouple_axi_hbm_29  (.decouple(decouple), .s_axi(axi_hbm_29_dy),  .m_axi(axi_hbm_29_st));
  axi_decoupler decouple_axi_hbm_30  (.decouple(decouple), .s_axi(axi_hbm_30_dy),  .m_axi(axi_hbm_30_st));
  axi_decoupler decouple_axi_hbm_31 (.decouple(decouple), .s_axi(axi_hbm_31_dy), .m_axi(axi_hbm_31_st));

endmodule : dynamic_decoupler_b
