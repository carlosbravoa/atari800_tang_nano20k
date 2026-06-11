# Gowin build script — Atari 800 Tang Nano 20K port
# Stage 4: USB HID keyboard (nand2mario/usb_hid_host)

# Set license file environment variable for Gowin Place & Route decryption
set env(LM_LICENSE_FILE) "/home/carlos/Documents/gowin/license/gowin_E_98460A8E46A6.lic"

# Resolve absolute paths before create_project changes the working directory
set tang_dir [file normalize [file dirname [info script]]]
set rtl_dir  [file normalize "$tang_dir/rtl"]
set src_dir  "$tang_dir/src"

create_project -name {atari800_tn20k} -dir "$tang_dir/impl" \
    -pn GW2AR-LV18QN88C8/I7 -device_version C -force

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
add_file "$src_dir/fifo_transmit.vhd"
add_file "$src_dir/fifo_receive.vhd"
add_file "$rtl_dir/common/sioemu/tape_handler.vhdl"
add_file "$src_dir/fifo_tape.vhd"

# ── Portable BRAM (replaces Altera-specific rtl/bram.vhd) ────────────────────
add_file "$src_dir/bram.vhd"

# ── SDRAM stub replaced by real controller ────────────────────────────────────
add_file "$src_dir/sdram_statemachine.vhdl"

# ── Stage 2: HDMI ─────────────────────────────────────────────────────────────
add_file "$src_dir/rpll_371m.v"
add_file "$src_dir/rpll_108m.v"
add_file "$src_dir/scale720p.sv"
add_file "$src_dir/fb_writer.sv"
add_file "$src_dir/fb_reader.sv"
add_file "$src_dir/test_pattern_720p.sv"
add_file "$src_dir/hdmi_audio_out.sv"
add_file "$src_dir/hdmi2/audio_clock_regeneration_packet.sv"
add_file "$src_dir/hdmi2/audio_info_frame.sv"
add_file "$src_dir/hdmi2/audio_sample_packet.sv"
add_file "$src_dir/hdmi2/auxiliary_video_information_info_frame.sv"
add_file "$src_dir/hdmi2/hdmi.sv"
add_file "$src_dir/hdmi2/packet_assembler.sv"
add_file "$src_dir/hdmi2/packet_picker.sv"
add_file "$src_dir/hdmi2/serializer.sv"
add_file "$src_dir/hdmi2/source_product_description_info_frame.sv"
add_file "$src_dir/hdmi2/tmds_channel.sv"

# ── Stage 3: PicoRV32 Softcore & OSD ─────────────────────────────────────────
add_file "$src_dir/picorv32.v"
add_file "$src_dir/iosys_picorv32.v"
add_file "$src_dir/simplespimaster.v"
add_file "$src_dir/spi_master.v"
add_file "$src_dir/spiflash.v"
add_file "$src_dir/textdisp.v"
add_file "$src_dir/gowin_dpb_menu.v"
add_file "$src_dir/simpleuart.v"

# ── Stage 4: USB HID keyboard ─────────────────────────────────────────────────
# usb_hid_host_rom uses $readmemh — copy hex to impl dir so synthesis finds it
file mkdir "$tang_dir/impl/atari800_tn20k"
file copy -force "$src_dir/usb_hid_host_rom.hex" "$tang_dir/impl/atari800_tn20k/"
file copy -force "$src_dir/fw_lane0.hex" "$tang_dir/impl/atari800_tn20k/"
file copy -force "$src_dir/fw_lane1.hex" "$tang_dir/impl/atari800_tn20k/"
file copy -force "$src_dir/fw_lane2.hex" "$tang_dir/impl/atari800_tn20k/"
file copy -force "$src_dir/fw_lane3.hex" "$tang_dir/impl/atari800_tn20k/"
# rpll_12m replaced by rpll_108m (dual-output: 108 MHz + 12 MHz from a single PLL)
add_file "$src_dir/usb_hid_host_rom.v"
add_file "$src_dir/usb_hid_host.v"
add_file "$src_dir/usb_to_atari800.sv"
add_file "$src_dir/uart_kbd_ch9350.sv"
add_file "$src_dir/fw_bram.v"

# ── Stage 5: POKEY audio — sigma-delta DAC ────────────────────────────────────
add_file "$src_dir/sigma_delta_dac.sv"

# ── Custom 27 MHz SDRAM Controller ────────────────────────────────────────────
add_file "$src_dir/gw2ar_sdram.sv"
add_file "$src_dir/sdram_nestang.v"

# ── Tang Nano top-level ───────────────────────────────────────────────────────
add_file "$src_dir/tang_top.sv"

# ── Physical constraints (required for P&R) ───────────────────────────────────
add_file "$tang_dir/constraints/tang_nano_20k.cst"
add_file "$tang_dir/constraints/tang_nano_20k.sdc"

# ── Synthesis options ─────────────────────────────────────────────────────────
set_option -top_module       tang_top
set_option -vhdl_std         vhd2008
set_option -verilog_std      sysv2017
set_option -synthesis_tool   gowinsynthesis

set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -multi_boot 1

# Placement re-roll knob: P&R is deterministic, so if a build lands a bad placement
# (negative clk_pix setup slack in the timing report), bump this 0→1→2 for a different
# deterministic placement. NEVER flash a build whose report shows negative slack.
set_option -place_option 1

# Full build: synthesis + place & route + bitstream
run all
