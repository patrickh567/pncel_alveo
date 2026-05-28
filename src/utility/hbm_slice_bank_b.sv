// *************************************************************************
//
// HBM register-slice bank — boundary stages on the static-side AXI buses
// for HBM channels 16..30.
//
// Mirrors `dynamic_decoupler_b` one stage downstream for the 15
// HBM-shape buses it carries (256 b data, 6-bit ID, 4-bit AWLEN,
// AXI3).  Port 31 (the muxed XDMA+RM landing, `axi_hbm_31`) is
// intentionally NOT sliced here: it has a 4-bit ID (this slice IP is
// 6-bit), is sliced separately by `u_slice_axi_hbm_31` on the
// dynamic side of the decoupler, and gains additional buffering
// from the static-side `axi_protocol_converter_0` chain before
// reaching the HBM switch.
//
// HBM-port mapping (matches `dynamic_decoupler_b`):
//   axi_hbm_NN  → HBM port NN  for NN = 16..30
//
// *************************************************************************
`timescale 1ns/1ps
module hbm_slice_bank_b (
  input  wire   aclk,
  input  wire   aresetn,

  axi_if.slave  axi_hbm_16_st,    axi_if.master axi_hbm_16_sliced,
  axi_if.slave  axi_hbm_17_st,    axi_if.master axi_hbm_17_sliced,
  axi_if.slave  axi_hbm_18_st,    axi_if.master axi_hbm_18_sliced,
  axi_if.slave  axi_hbm_19_st,    axi_if.master axi_hbm_19_sliced,
  axi_if.slave  axi_hbm_20_st,    axi_if.master axi_hbm_20_sliced,
  axi_if.slave  axi_hbm_21_st,    axi_if.master axi_hbm_21_sliced,
  axi_if.slave  axi_hbm_22_st,    axi_if.master axi_hbm_22_sliced,
  axi_if.slave  axi_hbm_23_st,    axi_if.master axi_hbm_23_sliced,
  axi_if.slave  axi_hbm_24_st,    axi_if.master axi_hbm_24_sliced,
  axi_if.slave  axi_hbm_25_st,    axi_if.master axi_hbm_25_sliced,
  axi_if.slave  axi_hbm_26_st,    axi_if.master axi_hbm_26_sliced,
  axi_if.slave  axi_hbm_27_st,    axi_if.master axi_hbm_27_sliced,
  axi_if.slave  axi_hbm_28_st,    axi_if.master axi_hbm_28_sliced,
  axi_if.slave  axi_hbm_29_st,    axi_if.master axi_hbm_29_sliced,
  axi_if.slave  axi_hbm_30_st,    axi_if.master axi_hbm_30_sliced
);

  axi_register_slice_hbm_wrapper rs_axi_hbm_16 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_16_st), .m(axi_hbm_16_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_17 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_17_st), .m(axi_hbm_17_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_18 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_18_st), .m(axi_hbm_18_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_19 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_19_st), .m(axi_hbm_19_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_20 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_20_st), .m(axi_hbm_20_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_21 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_21_st), .m(axi_hbm_21_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_22 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_22_st), .m(axi_hbm_22_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_23 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_23_st), .m(axi_hbm_23_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_24 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_24_st), .m(axi_hbm_24_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_25 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_25_st), .m(axi_hbm_25_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_26 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_26_st), .m(axi_hbm_26_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_27 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_27_st), .m(axi_hbm_27_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_28 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_28_st), .m(axi_hbm_28_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_29 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_29_st), .m(axi_hbm_29_sliced));
  axi_register_slice_hbm_wrapper rs_axi_hbm_30 (.aclk(aclk), .aresetn(aresetn), .s(axi_hbm_30_st), .m(axi_hbm_30_sliced));

endmodule : hbm_slice_bank_b
