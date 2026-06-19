# Tang Nano 20K timing constraints
# sys_clk: 27 MHz onboard oscillator (pin 4, LPLL1_T_in, Bank 7)
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]

# clk_5x: Phase A freq-lock — 143.4375 MHz from rpll_143m (cascaded off clk_108m). HDMI 5x.
create_clock -name clk_5x -period 6.9717 [get_nets {clk_5x}]

# clk_pix: Phase A freq-lock — 28.6875 MHz CLKDIV output (143.4375 ÷ 5 = clk_core). 480p custom
# 912x524 locked to the Atari frame.
create_clock -name clk_pix -period 34.858 -waveform {0 17.429} [get_pins {clkdiv_hdmi/CLKOUT}]
# Require 1 ns of setup margin on clk_pix (P&R only optimizes until constraints barely
# pass; without this, unrelated source changes can land the TMDS path at ~0 ns slack).
set_clock_uncertainty -setup -from [get_clocks {clk_pix}] -to [get_clocks {clk_pix}] 1.0

# clk_usb: 12 MHz from rPLL
create_clock -name clk_usb -period 83.333 [get_nets {clk_usb}]

# clk_core: 54 MHz CLKDIV output (216 MHz ÷ 4) — Atari core + SDRAM arbiter + iosys CDC.
# Previously UNCONSTRAINED, so P&R never closed timing on this domain (achievable Fmax
# was only ~43 MHz vs the 54 MHz it is actually clocked at). Constrain it so the tool
# optimizes these paths and reports the true critical path.
# clk_108m: 114.75 MHz PLL output, common source of clk_core and clk_mem. Defining
# clk_core/clk_mem as generated clocks from it lets STA analyse the 2:1 synchronous
# clk_core<->clk_mem crossing (otherwise TA1117: relationship cannot be calculated and
# the whole SDRAM datapath crossing is unanalysed).
create_clock -name clk_108m -period 8.7146 [get_pins {pll_core_inst/rpll_inst/CLKOUT}]
create_generated_clock -name clk_core -source [get_pins {pll_core_inst/rpll_inst/CLKOUT}] -divide_by 4 [get_pins {clkdiv_core/CLKOUT}]

# clk_mem: 57.375 MHz (114.75 ÷ 2) — SDRAM controller. 2:1 synchronous with clk_core (same
# clk_108m source) — kept in the SAME clock group so the tool analyses the crossing.
create_generated_clock -name clk_mem -source [get_pins {pll_core_inst/rpll_inst/CLKOUT}] -divide_by 2 [get_pins {clkdiv_mem/CLKOUT}]

# Treat system clock, USB clock, core+mem clocks, and HDMI clocks as asynchronous clock groups
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_pix clk_5x}] -group [get_clocks {clk_usb}] -group [get_clocks {clk_108m clk_core clk_mem}]

# Extra visibility in the P&R timing report: the TMDS/pixel domain (history of landing at
# ~0 ns slack) and the clk_core<->clk_mem SDRAM crossing (history of being unanalysed).
# Check these after every build — NEVER flash a bitstream whose report shows negative slack.
report_timing -setup -from_clock [get_clocks {clk_pix}] -to_clock [get_clocks {clk_pix}] -max_paths 50
report_timing -setup -from_clock [get_clocks {clk_core}] -to_clock [get_clocks {clk_mem}] -max_paths 30
report_timing -setup -from_clock [get_clocks {clk_mem}] -to_clock [get_clocks {clk_core}] -max_paths 30
