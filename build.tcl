# Gowin build script — Atari 800 Tang Nano 20K port
# Stage 4: USB HID keyboard (nand2mario/usb_hid_host)

# Resolve absolute paths before create_project changes the working directory
set tang_dir [file normalize [file dirname [info script]]]
set rtl_dir  [file normalize "$tang_dir/rtl"]
set src_dir  "$tang_dir/src"

create_project -name {atari800_tn20k} -dir "$tang_dir/impl" \
    -pn GW2AR-LV18QN88PC8/I7 -device_version C -force

# ── Core chipset (VHDL) ───────────────────────────────────────────────────────
add_file "$rtl_dir/common/a8core/atari800core.vhd"
add_file "$rtl_dir/common/a8core/atari800core_simple_sdram.vhd"
add_file "$rtl_dir/common/a8core/internalromram.vhd"
add_file "$rtl_dir/common/a8core/cart_logic.vhd"
add_file "$rtl_dir/common/a8core/covox.vhd"
add_file "$rtl_dir/common/a8core/cpu.vhd"
add_file "$rtl_dir/common/a8core/cpu_65xx.vhd"
add_file "$rtl_dir/common/a8core/freezer_logic.vhd"
add_file "$src_dir/address_decoder.vhdl"
add_file "$rtl_dir/common/a8core/antic.vhdl"
add_file "$rtl_dir/common/a8core/antic_counter.vhdl"
add_file "$rtl_dir/common/a8core/antic_dma_clock.vhdl"
add_file "$rtl_dir/common/a8core/enable_divider.vhdl"
add_file "$rtl_dir/common/a8core/gtia.vhdl"
add_file "$rtl_dir/common/a8core/gtia_palette.vhdl"
add_file "$rtl_dir/common/a8core/gtia_player.vhdl"
add_file "$rtl_dir/common/a8core/gtia_priority.vhdl"
add_file "$rtl_dir/common/a8core/irq_glue.vhdl"
add_file "$rtl_dir/common/a8core/pbi_rom.vhdl"
add_file "$rtl_dir/common/a8core/pia.vhdl"
add_file "$rtl_dir/common/a8core/pokey.vhdl"
add_file "$rtl_dir/common/a8core/pokey_countdown_timer.vhdl"
add_file "$rtl_dir/common/a8core/pokey_keyboard_scanner.vhdl"
add_file "$rtl_dir/common/a8core/pokey_mixer.vhdl"
add_file "$rtl_dir/common/a8core/pokey_mixer_mux.vhdl"
add_file "$rtl_dir/common/a8core/pokey_noise_filter.vhdl"
add_file "$rtl_dir/common/a8core/pokey_poly_17_9.vhdl"
add_file "$rtl_dir/common/a8core/pokey_poly_4.vhdl"
add_file "$rtl_dir/common/a8core/pokey_poly_5.vhdl"
add_file "$rtl_dir/common/a8core/pot_from_signed.vhdl"
add_file "$rtl_dir/common/a8core/reg_file.vhdl"
add_file "$rtl_dir/common/a8core/shared_enable.vhdl"
add_file "$rtl_dir/common/a8core/simple_counter.vhdl"
add_file "$rtl_dir/common/a8core/ultime.vhdl"
add_file "$src_dir/vbxe_stub.vhdl"
add_file "$rtl_dir/common/a8core/vbxe_blitter.vhdl"
add_file "$rtl_dir/common/a8core/wide_delay_line.vhdl"

# ── Shared components (VHDL) ──────────────────────────────────────────────────
add_file "$rtl_dir/common/components/syncreset_enable_divider.vhd"
add_file "$rtl_dir/common/components/complete_address_decoder.vhdl"
add_file "$rtl_dir/common/components/delay_line.vhdl"
add_file "$rtl_dir/common/components/generic_ram_infer.vhdl"
add_file "$rtl_dir/common/components/latch_delay_line.vhdl"
add_file "$rtl_dir/common/components/mult_infer.vhdl"
add_file "$rtl_dir/common/components/simple_low_pass_filter.vhdl"
add_file "$rtl_dir/common/components/synchronizer.vhdl"

# ── SIO / disk / tape emulation (VHDL) ───────────────────────────────────────
add_file "$rtl_dir/common/sioemu/sio_handler.vhdl"
add_file "$rtl_dir/common/sioemu/fifo_transmit.vhd"
add_file "$rtl_dir/common/sioemu/fifo_receive.vhd"
add_file "$rtl_dir/common/sioemu/tape_handler.vhdl"
add_file "$rtl_dir/common/sioemu/fifo_tape.vhd"

# ── Portable BRAM (replaces Altera-specific rtl/bram.vhd) ────────────────────
add_file "$src_dir/bram.vhd"

# ── SDRAM stub replaced by real controller ────────────────────────────────────
add_file "$src_dir/sdram_statemachine.vhdl"

# ── Stage 2: HDMI ─────────────────────────────────────────────────────────────
add_file "$src_dir/rpll_135m.v"
add_file "$src_dir/tmds_encoder.sv"
add_file "$src_dir/hdmi_out.sv"

# ── Stage 3: SD card FAT reader ───────────────────────────────────────────────
add_file "$src_dir/spi_master.sv"
add_file "$src_dir/sd_card.sv"
add_file "$src_dir/fat_reader.sv"
add_file "$src_dir/sd_rom_loader.sv"

# ── Stage 4: USB HID keyboard ─────────────────────────────────────────────────
# usb_hid_host_rom uses $readmemh — copy hex to impl dir so synthesis finds it
file mkdir "$tang_dir/impl/atari800_tn20k"
file copy -force "$src_dir/usb_hid_host_rom.hex" "$tang_dir/impl/atari800_tn20k/"
add_file "$src_dir/rpll_12m.v"
add_file "$src_dir/usb_hid_host_rom.v"
add_file "$src_dir/usb_hid_host.v"
add_file "$src_dir/usb_to_atari800.sv"

# ── Stage 5: POKEY audio — sigma-delta DAC ────────────────────────────────────
add_file "$src_dir/sigma_delta_dac.sv"

# ── Gowin SDRC_HS embedded SDRAM IP ──────────────────────────────────────────
# SDRAM_Controller_HS_Top.v and sdrc_hs_top.vp both `include "sdrc_hs_defines.v"
# and "sdrc_hs_name.v".  Gowin synthesis resolves includes relative to the
# including file, so the config files must live in the SDRC_HS data directory.
# We copy them there before adding the IP files.
set sdrc_dir "/home/carlos/Documents/gowin/IDE/ipcore/SDRC_HS/data"
file copy -force "$src_dir/sdrc_hs_defines.v" "$sdrc_dir/"
file copy -force "$src_dir/sdrc_hs_name.v"    "$sdrc_dir/"
add_file "$sdrc_dir/sdrc_hs_defines.v"
add_file "$sdrc_dir/sdrc_hs_name.v"
add_file "$sdrc_dir/SDRAM_Controller_HS_Top.v"
add_file "$sdrc_dir/sdrc_hs_top.vp"

# ── Tang Nano top-level ───────────────────────────────────────────────────────
add_file "$src_dir/tang_top.sv"

# ── Physical constraints (required for P&R) ───────────────────────────────────
add_file "$tang_dir/constraints/tang_nano_20k.cst"

# ── Synthesis options ─────────────────────────────────────────────────────────
set_option -top_module       tang_top
set_option -vhdl_std         vhd2008
set_option -verilog_std      sysv2017
set_option -synthesis_tool   gowinsynthesis

# Full build: synthesis + place & route + bitstream
run all
