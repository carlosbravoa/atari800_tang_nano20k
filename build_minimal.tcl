# Minimal build script — tang_top only, no VHDL, no SDRAM IP.
# Used to bisect whether full build.tcl causes FF stall.

set tang_dir [file normalize [file dirname [info script]]]
set src_dir  "$tang_dir/src"

create_project -name {atari800_tn20k} -dir "$tang_dir/impl" \
    -pn GW2AR-LV18QN88C8/I7 -device_version C -force

add_file "$src_dir/rpll_135m.v"
add_file "$src_dir/tang_top.sv"
add_file "$tang_dir/constraints/tang_nano_20k.cst"
add_file "$tang_dir/constraints/tang_nano_20k.sdc"

set_option -top_module      tang_top
set_option -verilog_std     sysv2017
set_option -synthesis_tool  gowinsynthesis

run all
