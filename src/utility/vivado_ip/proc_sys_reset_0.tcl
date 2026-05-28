# *************************************************************************
# Auto-generated IP creation script for proc_sys_reset_0
# Source IP : xilinx.com:ip:proc_sys_reset:5.0
# Generated : 2026-04-10 10:25:37
# *************************************************************************

create_ip -name proc_sys_reset \
          -vendor xilinx.com \
          -library ip \
          -version 5.0 \
          -module_name proc_sys_reset_0

set_ip_properties_safe proc_sys_reset_0 [list \
  CONFIG.AUX_RESET.INSERT_VIP                                  {0} \
  CONFIG.BUS_STRUCT_RESET.INSERT_VIP                           {0} \
  CONFIG.CLOCK.FREQ_HZ                                         {100000000} \
  CONFIG.CLOCK.INSERT_VIP                                      {0} \
  CONFIG.C_AUX_RESET_HIGH                                      {0} \
  CONFIG.C_AUX_RST_WIDTH                                       {4} \
  CONFIG.C_EXT_RESET_HIGH                                      {0} \
  CONFIG.C_EXT_RST_WIDTH                                       {1} \
  CONFIG.C_NUM_BUS_RST                                         {1} \
  CONFIG.C_NUM_INTERCONNECT_ARESETN                            {1} \
  CONFIG.C_NUM_PERP_ARESETN                                    {1} \
  CONFIG.C_NUM_PERP_RST                                        {1} \
  CONFIG.Component_Name                                        {proc_sys_reset_0} \
  CONFIG.DBG_RESET.INSERT_VIP                                  {0} \
  CONFIG.EXT_RESET.INSERT_VIP                                  {0} \
  CONFIG.INTERCONNECT_LOW_RST.INSERT_VIP                       {0} \
  CONFIG.MB_RST.INSERT_VIP                                     {0} \
  CONFIG.PERIPHERAL_HIGH_RST.INSERT_VIP                        {0} \
  CONFIG.PERIPHERAL_LOW_RST.INSERT_VIP                         {0} \
  CONFIG.RESET_BOARD_INTERFACE                                 {Custom} \
  CONFIG.USE_BOARD_FLOW                                        {false} \
]

