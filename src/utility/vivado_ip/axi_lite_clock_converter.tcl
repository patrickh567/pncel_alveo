# *************************************************************************
# Auto-generated IP creation script for axi_lite_clock_converter
# Source IP : xilinx.com:ip:axi_clock_converter:2.1
# Generated : 2026-04-09 09:06:42
# *************************************************************************

create_ip -name axi_clock_converter \
          -vendor xilinx.com \
          -library ip \
          -version 2.1 \
          -module_name axi_lite_clock_converter

set_ip_properties_safe axi_lite_clock_converter [list \
  CONFIG.ACLK_ASYNC                                            {1} \
  CONFIG.ACLK_RATIO                                            {1:2} \
  CONFIG.ADDR_WIDTH                                            {32} \
  CONFIG.ARUSER_WIDTH                                          {0} \
  CONFIG.AWUSER_WIDTH                                          {0} \
  CONFIG.BUSER_WIDTH                                           {0} \
  CONFIG.Component_Name                                        {axi_lite_clock_converter} \
  CONFIG.DATA_WIDTH                                            {32} \
  CONFIG.ID_WIDTH                                              {0} \
  CONFIG.MI_CLK.FREQ_HZ                                        {10000000} \
  CONFIG.MI_CLK.INSERT_VIP                                     {0} \
  CONFIG.MI_RST.INSERT_VIP                                     {0} \
  CONFIG.M_AXI.INSERT_VIP                                      {0} \
  CONFIG.PROTOCOL                                              {AXI4LITE} \
  CONFIG.READ_WRITE_MODE                                       {READ_WRITE} \
  CONFIG.RUSER_WIDTH                                           {0} \
  CONFIG.SI_CLK.FREQ_HZ                                        {10000000} \
  CONFIG.SI_CLK.INSERT_VIP                                     {0} \
  CONFIG.SI_RST.INSERT_VIP                                     {0} \
  CONFIG.SYNCHRONIZATION_STAGES                                {2} \
  CONFIG.S_AXI.INSERT_VIP                                      {0} \
  CONFIG.WUSER_WIDTH                                           {0} \
]

