// *************************************************************************
//
// PR-boundary decoupler bank for HBM channels 0..15.
//
// Bundles 16 axi_decoupler instances, one per HBM-shape master bus that
// the dynamic region drives onto an HBM channel in the 0..15 range.
// The static-side switch network maps these RM signals onto HBM ports
// 1-to-1 (matching alveo_u50_static.sv):
//
//   axi_hbm_NN  → HBM port NN  for NN = 00..15
//
// Each decoupler routes the RM-side master (axi_hbm_NN_dy) to the
// static-side slave (axi_hbm_NN_st), gated by the shared `decouple`
// control bit (driven from static reg 0 bit 0).
//
// *************************************************************************
`timescale 1ns/1ps
module dynamic_decoupler_a (
  input wire decouple,

  axi_if.slave  axi_hbm_00_dy,
  axi_if.master axi_hbm_00_st,
  axi_if.slave  axi_hbm_01_dy,
  axi_if.master axi_hbm_01_st,
  axi_if.slave  axi_hbm_02_dy,
  axi_if.master axi_hbm_02_st,
  axi_if.slave  axi_hbm_03_dy,
  axi_if.master axi_hbm_03_st,
  axi_if.slave  axi_hbm_04_dy,
  axi_if.master axi_hbm_04_st,
  axi_if.slave  axi_hbm_05_dy,
  axi_if.master axi_hbm_05_st,
  axi_if.slave  axi_hbm_06_dy,
  axi_if.master axi_hbm_06_st,
  axi_if.slave  axi_hbm_07_dy,
  axi_if.master axi_hbm_07_st,
  axi_if.slave  axi_hbm_08_dy,
  axi_if.master axi_hbm_08_st,
  axi_if.slave  axi_hbm_09_dy,
  axi_if.master axi_hbm_09_st,
  axi_if.slave  axi_hbm_10_dy,
  axi_if.master axi_hbm_10_st,
  axi_if.slave  axi_hbm_11_dy,
  axi_if.master axi_hbm_11_st,
  axi_if.slave  axi_hbm_12_dy,
  axi_if.master axi_hbm_12_st,
  axi_if.slave  axi_hbm_13_dy,
  axi_if.master axi_hbm_13_st,
  axi_if.slave  axi_hbm_14_dy,
  axi_if.master axi_hbm_14_st,
  axi_if.slave  axi_hbm_15_dy,
  axi_if.master axi_hbm_15_st
);

  axi_decoupler decouple_axi_hbm_00 (.decouple(decouple), .s_axi(axi_hbm_00_dy), .m_axi(axi_hbm_00_st));
  axi_decoupler decouple_axi_hbm_01 (.decouple(decouple), .s_axi(axi_hbm_01_dy), .m_axi(axi_hbm_01_st));
  axi_decoupler decouple_axi_hbm_02 (.decouple(decouple), .s_axi(axi_hbm_02_dy), .m_axi(axi_hbm_02_st));
  axi_decoupler decouple_axi_hbm_03 (.decouple(decouple), .s_axi(axi_hbm_03_dy), .m_axi(axi_hbm_03_st));
  axi_decoupler decouple_axi_hbm_04 (.decouple(decouple), .s_axi(axi_hbm_04_dy), .m_axi(axi_hbm_04_st));
  axi_decoupler decouple_axi_hbm_05 (.decouple(decouple), .s_axi(axi_hbm_05_dy), .m_axi(axi_hbm_05_st));
  axi_decoupler decouple_axi_hbm_06 (.decouple(decouple), .s_axi(axi_hbm_06_dy), .m_axi(axi_hbm_06_st));
  axi_decoupler decouple_axi_hbm_07 (.decouple(decouple), .s_axi(axi_hbm_07_dy), .m_axi(axi_hbm_07_st));
  axi_decoupler decouple_axi_hbm_08 (.decouple(decouple), .s_axi(axi_hbm_08_dy), .m_axi(axi_hbm_08_st));
  axi_decoupler decouple_axi_hbm_09 (.decouple(decouple), .s_axi(axi_hbm_09_dy), .m_axi(axi_hbm_09_st));
  axi_decoupler decouple_axi_hbm_10 (.decouple(decouple), .s_axi(axi_hbm_10_dy), .m_axi(axi_hbm_10_st));
  axi_decoupler decouple_axi_hbm_11 (.decouple(decouple), .s_axi(axi_hbm_11_dy), .m_axi(axi_hbm_11_st));
  axi_decoupler decouple_axi_hbm_12 (.decouple(decouple), .s_axi(axi_hbm_12_dy), .m_axi(axi_hbm_12_st));
  axi_decoupler decouple_axi_hbm_13 (.decouple(decouple), .s_axi(axi_hbm_13_dy), .m_axi(axi_hbm_13_st));
  axi_decoupler decouple_axi_hbm_14 (.decouple(decouple), .s_axi(axi_hbm_14_dy), .m_axi(axi_hbm_14_st));
  axi_decoupler decouple_axi_hbm_15 (.decouple(decouple), .s_axi(axi_hbm_15_dy), .m_axi(axi_hbm_15_st));

endmodule : dynamic_decoupler_a
