## Digilent Arty A7-100T (xc7a100tcsg324-1). Pin names follow the Digilent
## master XDC. nextpnr-xilinx reads only PACKAGE_PIN / IOSTANDARD here; the
## clock target is passed with --freq (see fpga/Makefile).

set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
set_property -dict { PACKAGE_PIN C2  IOSTANDARD LVCMOS33 } [get_ports { ck_rst }]

set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }]
set_property -dict { PACKAGE_PIN A9  IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in }]

set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
