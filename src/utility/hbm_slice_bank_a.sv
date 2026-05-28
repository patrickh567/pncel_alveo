// *************************************************************************
//
// HBM register-slice bank — boundary stages on the static-side AXI buses
// for HBM channels 0..15.
//
// Mirrors `dynamic_decoupler_a` one stage downstream: the same 16 buses
// (HBM-shape: 256 b data, 6-bit ID, 4-bit AWLEN, AXI3) come in on the
// `_st` side from the decoupler outputs, get registered through one
// `axi_register_slice_hbm` instance each, and exit on the `_sliced`
// side toward `alveo_u50_static`.  The slices break the long timing
// path from the partition boundary into the HBM IP.
//
// Indexing matches `dynamic_decoupler_a` 1-to-1:
//
//   axi_hbm_NN  → HBM port NN  for NN = 00..15
//
// HBM port 31 (the mux landing) is *not* in this bank — it lives in
// `dynamic_decoupler_b` and already has buffering from the static-side
// `axi_protocol_converter_0` chain before the HBM switch.
//
// *************************************************************************
`timescale 1ns/1ps
module hbm_slice_bank_a (
  input  wire   aclk,
  input  wire   aresetn,

  axi_if.slave  axi_hbm_00_st,    axi_if.master axi_hbm_00_sliced,
  axi_if.slave  axi_hbm_01_st,    axi_if.master axi_hbm_01_sliced,
  axi_if.slave  axi_hbm_02_st,    axi_if.master axi_hbm_02_sliced,
  axi_if.slave  axi_hbm_03_st,    axi_if.master axi_hbm_03_sliced,
  axi_if.slave  axi_hbm_04_st,    axi_if.master axi_hbm_04_sliced,
  axi_if.slave  axi_hbm_05_st,    axi_if.master axi_hbm_05_sliced,
  axi_if.slave  axi_hbm_06_st,    axi_if.master axi_hbm_06_sliced,
  axi_if.slave  axi_hbm_07_st,    axi_if.master axi_hbm_07_sliced,
  axi_if.slave  axi_hbm_08_st,    axi_if.master axi_hbm_08_sliced,
  axi_if.slave  axi_hbm_09_st,    axi_if.master axi_hbm_09_sliced,
  axi_if.slave  axi_hbm_10_st,    axi_if.master axi_hbm_10_sliced,
  axi_if.slave  axi_hbm_11_st,    axi_if.master axi_hbm_11_sliced,
  axi_if.slave  axi_hbm_12_st,    axi_if.master axi_hbm_12_sliced,
  axi_if.slave  axi_hbm_13_st,    axi_if.master axi_hbm_13_sliced,
  axi_if.slave  axi_hbm_14_st,    axi_if.master axi_hbm_14_sliced,
  axi_if.slave  axi_hbm_15_st,    axi_if.master axi_hbm_15_sliced
);

  axi_register_slice_hbm_wrapper rs_axi_hbm_00 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_00_st), .m(axi_hbm_00_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_01 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_01_st), .m(axi_hbm_01_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_02 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_02_st), .m(axi_hbm_02_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_03 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_03_st), .m(axi_hbm_03_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_04 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_04_st), .m(axi_hbm_04_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_05 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_05_st), .m(axi_hbm_05_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_06 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_06_st), .m(axi_hbm_06_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_07 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_07_st), .m(axi_hbm_07_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_08 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_08_st), .m(axi_hbm_08_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_09 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_09_st), .m(axi_hbm_09_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_10 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_10_st), .m(axi_hbm_10_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_11 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_11_st), .m(axi_hbm_11_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_12 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_12_st), .m(axi_hbm_12_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_13 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_13_st), .m(axi_hbm_13_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_14 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_14_st), .m(axi_hbm_14_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_15 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_15_st), .m(axi_hbm_15_sliced));

endmodule : hbm_slice_bank_a
