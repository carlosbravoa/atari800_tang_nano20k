# Tang Nano 20K timing constraints
# sys_clk: 27 MHz onboard oscillator (pin 4, LPLL1_T_in, Bank 7)
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]

# clk_5x: 371.25 MHz from rPLL (rpll_371m: FBDIV_SEL=54, IDIV_SEL=3, ODIV_SEL=2)
create_clock -name clk_5x -period 2.6936 [get_nets {clk_5x}]

# clk_pix: 74.25 MHz CLKDIV output — treat as independent clock (matches Gowin HDMI example)
create_clock -name clk_pix -period 13.468 -waveform {0 6.734} [get_pins {clkdiv_hdmi/CLKOUT}]

# clk_usb: 12 MHz from rPLL
create_clock -name clk_usb -period 83.333 [get_nets {clk_usb}]

# Treat system clock, USB clock, and HDMI clocks as asynchronous clock groups
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_pix clk_5x}] -group [get_clocks {clk_usb}]

