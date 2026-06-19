# Tang Nano 20K timing constraints
# sys_clk: 27 MHz onboard oscillator (pin 4, LPLL1_T_in, Bank 7)
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]

# clk_5x: Phase A — 135 MHz from rpll_135m (was 371.25 MHz rpll_371m). HDMI OSER10 5x.
create_clock -name clk_5x -period 7.4074 [get_nets {clk_5x}]

# clk_pix: Phase A — 27 MHz CLKDIV output (135 ÷ 5; was 74.25). Standard 480p59.94 pixel clk.
create_clock -name clk_pix -period 37.037 -waveform {0 18.5185} [get_pins {clkdiv_hdmi/CLKOUT}]
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
