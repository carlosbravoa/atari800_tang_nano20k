# Tang Nano 20K timing constraints
# sys_clk: 27 MHz onboard oscillator (pin 4, LPLL1_T_in, Bank 7)
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]

# clk_5x: 371.25 MHz from rPLL (rpll_371m: FBDIV_SEL=54, IDIV_SEL=3, ODIV_SEL=2)
create_clock -name clk_5x -period 2.6936 [get_nets {clk_5x}]

# clk_pix: 74.25 MHz CLKDIV output — treat as independent clock (matches Gowin HDMI example)
create_clock -name clk_pix -period 13.468 -waveform {0 6.734} [get_pins {clkdiv_hdmi/CLKOUT}]

# clk_usb: 12 MHz from rPLL
create_clock -name clk_usb -period 83.333 [get_nets {clk_usb}]

# clk_core: 54 MHz CLKDIV output (216 MHz ÷ 4) — Atari core + SDRAM arbiter + iosys CDC.
# Previously UNCONSTRAINED, so P&R never closed timing on this domain (achievable Fmax
# was only ~43 MHz vs the 54 MHz it is actually clocked at). Constrain it so the tool
# optimizes these paths and reports the true critical path.
create_clock -name clk_core -period 34.857 [get_pins {clkdiv_core/CLKOUT}]

# clk_mem: 57.375 MHz (114.75 ÷ 2) — SDRAM controller. 2:1 synchronous with clk_core (same
# clk_108m source) — kept in the SAME clock group so the tool analyses the crossing.
create_clock -name clk_mem -period 17.429 [get_pins {clkdiv_mem/CLKOUT}]

# Treat system clock, USB clock, core+mem clocks, and HDMI clocks as asynchronous clock groups
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_pix clk_5x}] -group [get_clocks {clk_usb}] -group [get_clocks {clk_core clk_mem}]

