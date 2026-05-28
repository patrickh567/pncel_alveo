# *************************************************************************
# Auto-generated IP creation script for axi_hbicap_0
# Source IP : xilinx.com:ip:axi_hbicap:1.0
# Generated : 2026-04-10 10:50:12
# *************************************************************************

create_ip -name axi_hbicap \
          -vendor xilinx.com \
          -library ip \
          -version 1.0 \
          -module_name axi_hbicap_0

set_ip_properties_safe axi_hbicap_0 [list \
  CONFIG.C_BRAM_SRL_FIFO_TYPE                                  {1} \
  CONFIG.C_DEVICE_ID                                           {0x04224093} \
  CONFIG.C_ENABLE_ASYNC                                        {1} \
  CONFIG.C_FAMILY                                              {virtexuplushbm} \
  CONFIG.C_ICAP_DWIDTH                                         {32} \
  CONFIG.C_ICAP_EXTERNAL                                       {0} \
  CONFIG.C_INCLUDE_STARTUP                                     {0} \
  CONFIG.C_MODE                                                {0} \
  CONFIG.C_NOREAD                                              {0} \
  CONFIG.C_OPERATION                                           {0} \
  CONFIG.C_READ_DELAY                                          {1} \
  CONFIG.C_READ_FIFO_DEPTH                                     {64} \
  CONFIG.C_READ_PATH                                           {0} \
  CONFIG.C_SHARED_STARTUP                                      {0} \
  CONFIG.C_SIMULATION                                          {2} \
  CONFIG.C_S_AXI_BASEADDR                                      {0xFFFFFFFF} \
  CONFIG.C_S_AXI_CTRL_BASEADDR                                 {0xFFFFFFFF} \
  CONFIG.C_S_AXI_CTRL_HIGHADDR                                 {0x00000000} \
  CONFIG.C_S_AXI_HIGHADDR                                      {0x00000000} \
  CONFIG.C_WRITE_FIFO_DEPTH                                    {1024} \
  CONFIG.Component_Name                                        {axi_hbicap_0} \
  CONFIG.ICAP_CLK.FREQ_HZ                                      {100000000} \
  CONFIG.ICAP_CLK.INSERT_VIP                                   {0} \
  CONFIG.M_AXIS_ACLK.FREQ_HZ                                   {250000000} \
  CONFIG.M_AXIS_ACLK.INSERT_VIP                                {0} \
  CONFIG.M_AXIS_ARESETN.INSERT_VIP                             {0} \
  CONFIG.M_AXIS_READ.INSERT_VIP                                {0} \
  CONFIG.S_AXI.INSERT_VIP                                      {0} \
  CONFIG.S_AXI_ACLK.FREQ_HZ                                    {250000000} \
  CONFIG.S_AXI_ACLK.INSERT_VIP                                 {0} \
  CONFIG.S_AXI_ARESETN.INSERT_VIP                              {0} \
  CONFIG.S_AXI_ARUSER_WIDTH                                    {0} \
  CONFIG.S_AXI_AWUSER_WIDTH                                    {0} \
  CONFIG.S_AXI_BUSER_WIDTH                                     {0} \
  CONFIG.S_AXI_CTRL.INSERT_VIP                                 {0} \
  CONFIG.S_AXI_CTRL_ACLK.FREQ_HZ                               {250000000} \
  CONFIG.S_AXI_CTRL_ACLK.INSERT_VIP                            {0} \
  CONFIG.S_AXI_CTRL_ARESETN.INSERT_VIP                         {0} \
  CONFIG.S_AXI_ID_WIDTH                                        {0} \
  CONFIG.S_AXI_RUSER_WIDTH                                     {0} \
  CONFIG.S_AXI_WUSER_WIDTH                                     {0} \
  CONFIG.UC_FAMILY                                             {1} \
]

