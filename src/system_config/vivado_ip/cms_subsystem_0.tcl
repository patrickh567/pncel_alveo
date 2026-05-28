# *************************************************************************
# Auto-generated IP creation script for cms_subsystem_0
# Source IP : xilinx.com:ip:cms_subsystem:4.0
# Generated : 2026-04-09 09:06:42
# *************************************************************************

create_ip -name cms_subsystem \
          -vendor xilinx.com \
          -library ip \
          -version 4.0 \
          -module_name cms_subsystem_0

set_ip_properties_safe cms_subsystem_0 [list \
  CONFIG.CARD_TYPE                                             {U50} \
  CONFIG.Component_Name                                        {cms_subsystem_0} \
  CONFIG.ENABLE_AXI_IC_PIPELINING                              {false} \
  CONFIG.HAS_MDM                                               {false} \
  CONFIG.VERSION.CORE_REVISION                                 {14} \
  CONFIG.VERSION.MAJOR_VERSION                                 {4} \
  CONFIG.VERSION.MINOR_VERSION                                 {0} \
  CONFIG.VERSION.PATCH_REVISION                                {0} \
  CONFIG.VERSION.PERFORCE_CL                                   {6138677} \
  CONFIG.VERSION.RESERVED_TAG                                  {0x00000000} \
  CONFIG.VERSION.SUBSYSTEM_ID                                  {0x02} \
  CONFIG.VERSION.VIV_VERSION                                   {0x202510} \
]

