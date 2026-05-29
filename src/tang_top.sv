// Atari 800 — Tang Nano 20K top-level
// HDMI: Open-source unencrypted hdmi_audio_out transmitter.
// Clocks: 54 MHz core (rpll_54m); 371.25 MHz HDMI 5x; 74.25 MHz HDMI pixel; 12 MHz USB.
// cycle_length=32 at 54 MHz → 32 SDRAM cycles per Atari bus cycle (budget fix for video garble).
// Atari CPU speed stays 54/32 = 1.6875 MHz (same as 27/16). SDRC state machine runs 2× faster
// in wall time so transactions complete within the 32-cycle window (shared_enable.vhdl only works
// with power-of-2 cycle_lengths; 30 triggers an index-out-of-range error).

module tang_top (
    input  wire        sys_clk,       // 27 MHz onboard oscillator

    // Buttons (active HIGH, PULL_MODE=DOWN): S1 = reset, S2 = OSD menu toggle
    // btn_n[x] = 0 when unpressed (pulled low), 1 when pressed (drives VCC)
    input  wire [1:0]  btn_n,

    // HDMI TMDS — driven by ELVDS_OBUF inside hdmi_out
    output wire [2:0]  tmds_p,
    output wire [2:0]  tmds_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,

    // SD card (SPI mode)
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs,

    // USB HID host (low-speed USB keyboard/mouse/gamepad)
    inout  wire        usb_dm,        // D- — pin 49 (IOR49A); 15 kΩ to GND
    inout  wire        usb_dp,        // D+ — pin 51 (IOR45A); 15 kΩ to GND

    // Joystick ports (Atari DB9 pinout, active low)
    input  wire [4:0]  joy1_n,
    input  wire [4:0]  joy2_n,

    // Audio — sigma-delta PDM (add RC filter: 1 kΩ + 10 nF to 3.5 mm jack)
    output wire        audio_l,        // pin 25 (IOB6A) — GPIO header
    output wire        audio_r,        // pin 26 (IOB6B) — GPIO header

    // Status LEDs (active low on Tang Nano 20K) — pins 17-20 only.
    // Pins 15/16 (leds_n[5]/[0] on schematic) are LPLL2 feedback pads; never drive them.
    output wire [4:1]  leds_n,

    // Onboard SPI Flash (as user GPIO for PicoRV32)
    output wire        flash_spi_cs_n,
    input  wire        flash_spi_miso,
    output wire        flash_spi_mosi,
    output wire        flash_spi_clk,
    output wire        flash_spi_wp_n,
    output wire        flash_spi_hold_n,

    // Embedded SDRAM (GW2AR-18 on-chip)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [1:0]  O_sdram_ba,
    output wire [10:0] O_sdram_addr,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);

// Explicitly disable the Global Set/Reset (GSR) network to prevent auto-inference
// and avoid routing/reset loops on the custom startup delay circuit.
GSR GSR_INST (.GSRI(1'b1));

// ── Clocks & reset ─────────────────────────────────────────────────────────
wire clk_5x;               // 371.25 MHz — HDMI OSER10 5x clock
wire clk_pix;              // 74.25 MHz  — HDMI pixel clock (371.25 ÷ 5)
wire clk_usb;              // 12 MHz     — USB HID host (rpll_108m CLKOUTD ÷18)
wire clk_108m;             // 216 MHz    — intermediate (rpll_108m CLKOUT)
wire clk_core;             // 54 MHz     — Atari core + SDRAM (clk_108m ÷ 4 via CLKDIV)
wire pll_locked, pll_core_locked;

rpll_371m pll (
    .clk_in  (sys_clk),
    .clk_371m(clk_5x),
    .locked  (pll_locked)
);

// rpll_108m replaces both rpll_12m and rpll_54m within the 2-PLL device limit:
// CLKOUT=216 MHz feeds CLKDIV÷4 → clk_core=54 MHz; CLKOUTD(÷18)=12 MHz → clk_usb.
rpll_108m pll_core_inst (
    .clk_in  (sys_clk),
    .clk_108m(clk_108m),
    .clk_12m (clk_usb),
    .locked  (pll_core_locked)
);

CLKDIV #(
    .DIV_MODE ("4"),
    .GSREN    ("false")
) clkdiv_core (
    .CLKOUT (clk_core),
    .HCLKIN (clk_108m),
    .RESETN (pll_core_locked),
    .CALIB  (1'b1)
);

// Power-on reset timer: guaranteed to release after 1.2 ms (32768 / 27 MHz)
// S1 (btn_n[0]) is active-HIGH: pressing it drives pin HIGH, which restarts the timer.
// hw_reset_n stays low while the timer hasn't expired (power-on) OR while S1 is pressed.
reg [15:0] rst_timer = 16'd0;
wire       timer_done = rst_timer[15];
always_ff @(posedge sys_clk) begin
    if (btn_n[0]) begin          // S1 pressed → hold reset (timer held at 0)
        rst_timer <= 16'd0;
    end else if (!timer_done) begin
        rst_timer <= rst_timer + 16'd1;
    end
end

// hw_reset_n: released after power-on delay, PLLs locked, and S1 not pressed.
wire hw_reset_n  = timer_done && !btn_n[0] && pll_core_locked;
wire usb_host_enable;
wire usb_reset_n = hw_reset_n && usb_host_enable;

// hdmi_rst_n: gate HDMI logic on PLL lock so OSER10 RESET is held until clk_pix is stable.
wire hdmi_rst_n = hw_reset_n && pll_locked;

// 371.25 MHz ÷ 5 = 74.25 MHz HDMI pixel clock.
// Hold CLKDIV in reset until PLL locks and system reset is released so clk_pix starts cleanly with stable FCLK in sync with OSER10.
CLKDIV #(
    .DIV_MODE ("5"),
    .GSREN    ("false")
) clkdiv_hdmi (
    .CLKOUT (clk_pix),
    .HCLKIN (clk_5x),
    .RESETN (hdmi_rst_n),
    .CALIB  (1'b1)
);

// Core reset held until ROMs are loaded by PicoRV32.
reg roms_loaded = 1'b0;
reg rom_loading_r = 1'b0;
wire rom_loading;

always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        roms_loaded   <= 1'b0;
        rom_loading_r <= 1'b0;
    end else begin
        rom_loading_r <= rom_loading;
        if (rom_loading) begin
            roms_loaded <= 1'b0;
        end else if (rom_loading_r && !rom_loading) begin
            roms_loaded <= 1'b1;
        end
    end
end

wire core_reset_n = hw_reset_n && roms_loaded;
wire dbg_sd_ready;

// ── Keyboard ───────────────────────────────────────────────────────────────
wire [5:0]  keyboard_scan;
wire [1:0]  keyboard_response;
wire        consol_start;
wire        consol_select;
wire        consol_option;
wire [7:0]  usb_key_mod, usb_key1, usb_key2, usb_key3, usb_key4;

// ── Video ──────────────────────────────────────────────────────────────────
wire        video_vs, video_hs;
wire [7:0]  video_r, video_g, video_b;
wire        video_blank;
wire        video_pixce;


// ── Audio ──────────────────────────────────────────────────────────────────
wire [15:0] audio_l_pcm, audio_r_pcm;

// 1 kHz test tone: hold S2 (btn_n[1]) to inject into both HDMI and GPIO audio.
// 27 MHz / (1000 Hz × 2) = 13500 cycles per half-period.
reg [13:0] tone_cnt = 14'd0;
reg        tone_sq = 1'b0;
always_ff @(posedge sys_clk)
    if (tone_cnt == 14'd13499) begin tone_cnt <= 14'd0; tone_sq <= ~tone_sq; end
    else                            tone_cnt <= tone_cnt + 14'd1;

wire [15:0] tone_sample = tone_sq ? 16'h4000 : 16'hC000;  // ±25 % FS square wave
wire [15:0] audio_l_out = audio_l_pcm;
wire [15:0] audio_r_out = audio_r_pcm;

sigma_delta_dac dac_l (.clk(sys_clk), .audio_in(audio_l_out), .dac_out(audio_l));
sigma_delta_dac dac_r (.clk(sys_clk), .audio_in(audio_r_out), .dac_out(audio_r));

// ── SIO — stubbed until Stage 6 ───────────────────────────────────────────
wire sio_command, sio_txd, sio_motor;

// ── SDRAM logical bus from Atari core ─────────────────────────────────────
wire        core_sdram_req;
wire        core_sdram_req_complete;
wire        core_sdram_read_en;
wire        core_sdram_write_en;
wire [24:0] core_sdram_addr;
wire [31:0] core_sdram_data_to_core;
wire [31:0] core_sdram_data_from_core;
wire        core_sdram_32bit_we;
wire        core_sdram_16bit_we;
wire        core_sdram_8bit_we;
wire        core_sdram_refresh;

// PicoRV32 client wires
wire        rv_valid;
wire        rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata;
wire [3:0]  rv_wstrb;
wire [31:0] rv_rdata;
wire        sdram_ready;

// ── PicoRV32 ↔ SDRAM arbiter CDC ─────────────────────────────────────────────
// iosys_picorv32 stays on sys_clk (27 MHz) so its firmware-compiled SPI timing
// (SD card init ≤400 kHz) is preserved.  The SDRAM arbiter runs at clk_core
// (54 MHz) alongside the Atari core and SDRAM IP.
//
// rv_valid (27 MHz → 54 MHz): level, held until acked — 2-FF synchronizer.
reg [1:0] rv_valid_sync_r = 2'b00;
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) rv_valid_sync_r <= 2'b00;
    else             rv_valid_sync_r <= {rv_valid_sync_r[0], rv_valid};
end
wire rv_valid_core = rv_valid_sync_r[1];

// rv_ready (54 MHz → 27 MHz): 1-cycle clk_core pulse — toggle synchronizer.
// Toggle rv_done_toggle_r once per completed PicoRV32 transaction.  A 3-stage
// sync chain in sys_clk domain plus XOR edge-detect produces a reliable
// 1-cycle sys_clk rv_ready pulse.
reg       rv_done_toggle_r  = 1'b0;
reg [2:0] rv_done_sys_r     = 3'b000;
wire      rv_ready_sync     = rv_done_sys_r[2] ^ rv_done_sys_r[1];

// rv_hold: prevents phantom transactions.  After a PicoRV32 transaction
// completes, the arbiter must not launch another one until rv_valid_core
// deasserts (i.e. until PicoRV32 has acknowledged rv_ready and the
// deassert has propagated through the 2-FF sync).  Without this, the arbiter
// re-launches in the very next clk_core cycle, producing extra toggles that
// corrupt the toggle-sync and leave PicoRV32 with 0 or 2 rv_ready pulses.
reg rv_hold = 1'b0;
wire rv_req = rv_valid_core && !rv_hold;  // PicoRV32 has a real new request

// ── Dual-Client SDRAM Arbiter & Adapter ──────────────────────────────────────
wire        sdram_complete;
reg         sdram_complete_r = 1'b0;
reg         sdram_owner = 1'b0; // 0 = Atari core, 1 = PicoRV32

assign sdram_complete = sdram_complete_r;
assign core_sdram_req_complete = sdram_complete && (sdram_owner == 1'b0);
assign rv_ready                = rv_ready_sync;

wire [31:0] sdram_rd_data_wire;
wire        sdram_ready_wire;

assign core_sdram_data_to_core = sdram_rd_data_wire >> {core_sdram_addr[1:0], 3'b000};
assign rv_rdata                = sdram_rd_data_wire;
assign sdram_ready             = sdram_ready_wire;

// Address translation for PicoRV32: Virtual-to-Physical Bank mapping
// Virtual Bank 0 (0x000000-0x1FFFFF) -> Physical Bank 1
// Virtual Bank 1 (0x200000-0x3FFFFF) -> Physical Bank 0
// Virtual Bank 2 (0x400000-0x5FFFFF) -> Physical Bank 2
// Virtual Bank 3 (0x600000-0x7FFFFF) -> Physical Bank 3
wire [24:0] rv_physical_addr = { 2'b00, (rv_addr[22:21] == 2'b00) ? 2'b01 : ((rv_addr[22:21] == 2'b01) ? 2'b00 : rv_addr[22:21]), rv_addr[20:0] };

// ── Custom Dual-Client SDRAM Arbiter ─────────────────────────────────────────
// Reconstruct the 4-bit write mask for the Atari core from its we signals and address:
wire [3:0] core_sdram_wmask = core_sdram_32bit_we ? 4'b1111 :
                              core_sdram_16bit_we ? (core_sdram_addr[1] ? 4'b1100 : 4'b0011) :
                              core_sdram_8bit_we  ? (
                                  (core_sdram_addr[1:0] == 2'b00) ? 4'b0001 :
                                  (core_sdram_addr[1:0] == 2'b01) ? 4'b0010 :
                                  (core_sdram_addr[1:0] == 2'b10) ? 4'b0100 : 4'b1000
                              ) : 4'b0000;

wire actual_core_sdram_req = core_sdram_req && core_reset_n;

// The address_decoder asserts SDRAM_REQUEST for exactly ONE clock cycle (only in state_idle).
// If the SDRAM is busy (PicoRV32 transaction) or in tRP/tWR wait when that pulse arrives,
// the request is silently lost, deadlocking the 6502.  Latch the pulse until the SDRAM
// controller can accept it.
reg actual_core_sdram_req_r = 1'b0;
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        actual_core_sdram_req_r <= 1'b0;
    end else begin
        actual_core_sdram_req_r <= actual_core_sdram_req;
    end
end

wire atari_req_rise = actual_core_sdram_req && !actual_core_sdram_req_r;

reg atari_req_pending = 1'b0;
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        atari_req_pending <= 1'b0;
    end else begin
        if (atari_req_rise) begin
            atari_req_pending <= 1'b1;
        end else if (sadap_st == SA_BUSY && sdram_owner == 1'b0 && sdram_complete_wire) begin
            atari_req_pending <= 1'b0;
        end
    end
end

// After each Atari SDRAM access, reserve one slot for PicoRV32 if it is waiting.
// Without this, Atari's continuous requests starve PicoRV32 instruction fetches
// and the UART keyboard / menu becomes unresponsive.
reg rv_slot = 1'b0;

// rv_slot path drops !sdram_complete_r so PicoRV32 can claim its reserved slot
// in the very SA_IDLE cycle after an Atari completion (sdram_complete_r=1).
// rv_hold already blocks phantom relaunches when PicoRV32 itself just finished.
// The unsolicited rv_req path (no slot) keeps !sdram_complete_r as a safety guard.
wire next_owner = (rv_slot && rv_req)                    ? 1'b1 :
                  atari_req_pending                       ? 1'b0 :
                  (rv_req && !sdram_complete_r)           ? 1'b1 : 1'b1;

wire next_req = (rv_slot && rv_req)          ||
                atari_req_pending             ||
                (rv_req && !sdram_complete_r);

wire current_owner = (sadap_st == SA_BUSY) ? sdram_owner : next_owner;
// During SA_BUSY keep rv_valid_core (not rv_req) so an in-progress PicoRV32
// transaction is not dropped mid-flight if rv_hold happens to be set.
wire sdram_ctrl_req = (sadap_st == SA_BUSY) ? (sdram_owner ? rv_valid_core : atari_req_pending) : next_req;
wire        sdram_ctrl_read_en  = current_owner ? (~|rv_wstrb) : core_sdram_read_en;
wire        sdram_ctrl_write_en = current_owner ? (|rv_wstrb)  : core_sdram_write_en;
wire [24:0] sdram_ctrl_addr     = current_owner ? rv_physical_addr : core_sdram_addr;
wire [31:0] sdram_ctrl_wdata    = current_owner ? rv_wdata : {4{core_sdram_data_from_core[7:0]}};
wire [3:0]  sdram_ctrl_wmask    = current_owner ? rv_wstrb : core_sdram_wmask;
wire        sdram_ctrl_refresh  = core_sdram_refresh;

wire        sdram_complete_wire;

typedef enum logic { SA_IDLE, SA_BUSY } sadap_t;
sadap_t sadap_st = SA_IDLE;

always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        sdram_complete_r <= 1'b0;
        sadap_st         <= SA_IDLE;
        sdram_owner      <= 1'b0;
        rv_slot          <= 1'b0;
        rv_done_toggle_r <= 1'b0;
        rv_hold          <= 1'b0;
    end else begin
        sdram_complete_r <= 1'b0;

        // rv_hold: set when a PicoRV32 transaction completes; cleared when
        // rv_valid_core deasserts.  Prevents phantom re-launches while waiting
        // for the rv_ready toggle-sync pulse to reach iosys (≈8 clk_core cycles).
        if (sdram_complete_r && sdram_owner == 1'b1) rv_hold <= 1'b1;
        if (!rv_valid_core)                          rv_hold <= 1'b0;

        case (sadap_st)
            SA_IDLE: begin
                if (sdram_ready_wire) begin
                    if (rv_slot && rv_req) begin
                        sdram_owner <= 1'b1;
                        rv_slot     <= 1'b0;
                        sadap_st    <= SA_BUSY;
                    end else if (atari_req_pending) begin
                        sdram_owner <= 1'b0;
                        sadap_st    <= SA_BUSY;
                    end else if (rv_req && !sdram_complete_r) begin
                        sdram_owner <= 1'b1;
                        sadap_st    <= SA_BUSY;
                    end
                end
            end
            SA_BUSY: begin
                if (sdram_complete_wire) begin
                    sdram_complete_r <= 1'b1;
                    sadap_st         <= SA_IDLE;
                    // Reserve a slot for iosys if it has a new request waiting
                    if (sdram_owner == 1'b0 && rv_req)
                        rv_slot <= 1'b1;
                    // Pulse the toggle-sync for iosys rv_ready
                    if (sdram_owner == 1'b1)
                        rv_done_toggle_r <= ~rv_done_toggle_r;
                end
            end
            default: sadap_st <= SA_IDLE;
        endcase
    end
end

// Synchronise rv_done_toggle_r (clk_core) into sys_clk for iosys rv_ready
always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) rv_done_sys_r <= 3'b000;
    else             rv_done_sys_r <= {rv_done_sys_r[1:0], rv_done_toggle_r};
end

gw2ar_sdram sdram_ip (
    .clk          (clk_core),
    .reset_n      (hw_reset_n),

    // User interface
    .req          (sdram_ctrl_req),
    .req_complete (sdram_complete_wire),
    .read_en      (sdram_ctrl_read_en),
    .write_en     (sdram_ctrl_write_en),
    .addr         (sdram_ctrl_addr),
    .rdata        (sdram_rd_data_wire),
    .wdata        (sdram_ctrl_wdata),
    .wmask        (sdram_ctrl_wmask),
    .refresh      (sdram_ctrl_refresh),

    // Physical embedded SDRAM connections
    .O_sdram_clk  (O_sdram_clk),
    .O_sdram_cke  (O_sdram_cke),
    .O_sdram_cs_n (O_sdram_cs_n),
    .O_sdram_ras_n(O_sdram_ras_n),
    .O_sdram_cas_n(O_sdram_cas_n),
    .O_sdram_wen_n(O_sdram_wen_n),
    .O_sdram_ba   (O_sdram_ba),
    .O_sdram_addr (O_sdram_addr),
    .O_sdram_dqm  (O_sdram_dqm),
    .IO_sdram_dq  (IO_sdram_dq),

    .sdram_ready  (sdram_ready_wire)
);

// ─────────────────────────────────────────────────────────────────────────────
// PicoRV32 Softcore MCU & SIO Disk Handler
// ─────────────────────────────────────────────────────────────────────────────

// Virtual Keyboard wires from PicoRV32 softcore
wire [7:0] virt_kbd_mod;
wire [7:0] virt_kbd_key1;
wire [7:0] virt_kbd_key2;
wire [7:0] virt_kbd_key3;
wire [7:0] virt_kbd_key4;

// Combine USB keyboard keys and PicoRV32 virtual serial keyboard keys
wire [7:0] effective_usb_key_mod = usb_host_enable ? usb_key_mod : 8'h00;
wire [7:0] effective_usb_key1    = usb_host_enable ? usb_key1    : 8'h00;
wire [7:0] effective_usb_key2    = usb_host_enable ? usb_key2    : 8'h00;
wire [7:0] effective_usb_key3    = usb_host_enable ? usb_key3    : 8'h00;
wire [7:0] effective_usb_key4    = usb_host_enable ? usb_key4    : 8'h00;

wire [7:0] combined_key_mod = virt_kbd_mod  | effective_usb_key_mod;
wire [7:0] combined_key1    = (virt_kbd_key1 != 8'h00) ? virt_kbd_key1 : effective_usb_key1;
wire [7:0] combined_key2    = (virt_kbd_key2 != 8'h00) ? virt_kbd_key2 : effective_usb_key2;
wire [7:0] combined_key3    = (virt_kbd_key3 != 8'h00) ? virt_kbd_key3 : effective_usb_key3;
wire [7:0] combined_key4    = (virt_kbd_key4 != 8'h00) ? virt_kbd_key4 : effective_usb_key4;

// OSD navigation: driven by BOTH real USB keyboard and virtual UART keyboard.
wire key_up    = (combined_key1 == 8'h52) || (combined_key2 == 8'h52) || (combined_key3 == 8'h52) || (combined_key4 == 8'h52); // Up Arrow
wire key_down  = (combined_key1 == 8'h51) || (combined_key2 == 8'h51) || (combined_key3 == 8'h51) || (combined_key4 == 8'h51); // Down Arrow
wire key_left  = (combined_key1 == 8'h50) || (combined_key2 == 8'h50) || (combined_key3 == 8'h50) || (combined_key4 == 8'h50); // Left Arrow
wire key_right = (combined_key1 == 8'h4F) || (combined_key2 == 8'h4F) || (combined_key3 == 8'h4F) || (combined_key4 == 8'h4F); // Right Arrow
wire key_enter = (combined_key1 == 8'h28) || (combined_key2 == 8'h28) || (combined_key3 == 8'h28) || (combined_key4 == 8'h28); // Enter
wire key_esc   = (combined_key1 == 8'h29) || (combined_key2 == 8'h29) || (combined_key3 == 8'h29) || (combined_key4 == 8'h29); // Escape
wire key_f12   = (combined_key1 == 8'h45) || (combined_key2 == 8'h45) || (combined_key3 == 8'h45) || (combined_key4 == 8'h45); // F12

// Combine USB keyboard keys and physical DB9 Joystick 1 (active low, so ~joy1_n)
wire joy_up    = key_up    || ~joy1_n[0];
wire joy_down  = key_down  || ~joy1_n[1];
wire joy_left  = key_left  || ~joy1_n[2];
wire joy_right = key_right || ~joy1_n[3];
wire joy_fire  = key_enter || ~joy1_n[4];

// S2 (btn_n[1]) is active-HIGH: 0 when unpressed (PULL_MODE=DOWN), 1 when pressed.
// Map directly (no inversion) to bit 9 (X) in rv_joy1 so firmware sees 1 only when pressed.
wire osd_toggle = btn_n[1];

wire [11:0] rv_joy1 = {
    joy_right,                         // 11: R
    joy_left,                          // 10: L
    osd_toggle,                        //  9: X (S2 button)
    1'b0,                              //  8: A
    1'b0,                              //  7: RT
    1'b0,                              //  6: LT
    joy_down,                          //  5: DN
    joy_up,                            //  4: UP
    key_f12,                           //  3: START
    1'b0,                              //  2: SELECT
    key_esc,                           //  1: Y
    joy_fire                           //  0: B
};
wire [11:0] rv_joy2 = 12'b0;


// OSD overlay signals
wire        overlay;
wire [15:0] overlay_color;
wire [7:0]  osd_x;
wire [7:0]  osd_y;

// SIO register interface wires
wire        sio_reg_sel;
wire [4:0]  sio_reg_addr;
wire [7:0]  sio_reg_wdata;
wire        sio_reg_wr;
wire [15:0] sio_reg_rdata;
wire        sio_reg_en;

wire        sio_rx_data_in;
wire        sio_clk_out;
wire        enable_179_early;

// ── CDC: overlay (sys_clk=27 MHz) → HALT (clk_core=54 MHz) ──────────────────
// overlay_buf in iosys starts at 1 so initialize both FFs to 1 (Atari halted
// during ROM loading) to avoid a spurious HALT=0 glitch at the first clk_core
// edge.
// overlay already declared above (line ~485) as iosys output in sys_clk domain
reg  [1:0]  overlay_core_r = 2'b11;
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) overlay_core_r <= 2'b11;
    else             overlay_core_r <= {overlay_core_r[0], overlay};
end
wire overlay_core = overlay_core_r[1];  // clk_core-domain HALT signal

// ── CDC: enable_179_early (clk_core, 1-cycle 18.5 ns pulse) → sys_clk ───────
// sio_handler POKEY_ENABLE must be visible at sys_clk=27 MHz (37 ns period).
// A 1-cycle clk_core pulse is only 18.5 ns — ~50 % chance of being missed.
// Toggle-synchronizer: toggle a bit on each pulse in clk_core, sync 3 stages
// into sys_clk, XOR edge-detect → reliable 1-cycle sys_clk POKEY_ENABLE pulse.
reg       e179_toggle_r  = 1'b0;
reg [2:0] e179_sys_r     = 3'b000;
wire      enable_179_sys = e179_sys_r[2] ^ e179_sys_r[1];

always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) e179_toggle_r <= 1'b0;
    else if (enable_179_early) e179_toggle_r <= ~e179_toggle_r;
end
always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) e179_sys_r <= 3'b000;
    else             e179_sys_r <= {e179_sys_r[1:0], e179_toggle_r};
end

assign dbg_sd_ready = roms_loaded;

// PicoRV32 IO subsystem module
// iosys_picorv32 stays on sys_clk (27 MHz): firmware compiled for that frequency.
// Its SPI/SD timing is correct only at 27 MHz; CDC to the 54 MHz arbiter is
// handled by rv_valid_core (2-FF sync) + rv_ready toggle-sync + rv_hold gate.
iosys_picorv32 #(
    .FREQ(27_000_000),
    .COLOR_LOGO(15'b00000_10101_00000),
    .CORE_ID(16'd3) // 3 for Atari
) mcu (
    .clk(sys_clk),
    .hclk(clk_pix),
    .resetn(hw_reset_n),

    // OSD display interface
    .overlay(overlay),
    .overlay_x(osd_x),
    .overlay_y(osd_y),
    .overlay_color(overlay_color),
    .joy1(rv_joy1),
    .joy2(rv_joy2),

    // ROM loading interface
    .rom_loading(rom_loading),
    .rom_do(),
    .rom_do_valid(),

    // 32-bit wide memory interface for RISC-V softcore
    .rv_valid(rv_valid),
    .rv_ready(rv_ready),
    .rv_addr(rv_addr),
    .rv_wdata(rv_wdata),
    .rv_wstrb(rv_wstrb),
    .rv_rdata(rv_rdata),

    .ram_busy(~sdram_ready),

    // SPI Flash
    .flash_spi_cs_n(flash_spi_cs_n),
    .flash_spi_miso(flash_spi_miso),
    .flash_spi_mosi(flash_spi_mosi),
    .flash_spi_clk(flash_spi_clk),
    .flash_spi_wp_n(flash_spi_wp_n),
    .flash_spi_hold_n(flash_spi_hold_n),

    // UART RX is mapped to pin 53 (usb_dp)
    .uart_rx(usb_dp),
    .uart_tx(),

    // Virtual Keyboard outputs
    .virt_kbd_mod_out(virt_kbd_mod),
    .virt_kbd_key1_out(virt_kbd_key1),
    .virt_kbd_key2_out(virt_kbd_key2),
    .virt_kbd_key3_out(virt_kbd_key3),
    .virt_kbd_key4_out(virt_kbd_key4),
    .usb_host_enable_out(usb_host_enable),

    // SD Card (SPI mode)
    .sd_clk(sd_clk),
    .sd_cmd(sd_mosi),
    .sd_dat0(sd_miso),
    .sd_dat1(),
    .sd_dat2(),
    .sd_dat3(sd_cs),

    // SIO register interface
    .sio_reg_sel(sio_reg_sel),
    .sio_reg_addr(sio_reg_addr),
    .sio_reg_wdata(sio_reg_wdata),
    .sio_reg_wr(sio_reg_wr),
    .sio_reg_rdata(sio_reg_rdata),
    .sio_reg_en(sio_reg_en)
);

// VHDL SIO Disk Handler
sio_handler sio_inst (
    .CLK(sys_clk),
    .ADDR(sio_reg_addr),
    .CPU_DATA_IN(sio_reg_wdata),
    .EN(sio_reg_en),
    .WR_EN(sio_reg_wr),
    .RESET_N(hw_reset_n),
    .POKEY_ENABLE(enable_179_sys),
    .SIO_DATA_IN(sio_rx_data_in),
    .SIO_COMMAND(sio_command),
    .SIO_DATA_OUT(sio_txd),
    .SIO_CLK_OUT(sio_clk_out),
    .DATA_OUT(sio_reg_rdata)
);

// ─────────────────────────────────────────────────────────────────────────────
// Atari 800 core
// ─────────────────────────────────────────────────────────────────────────────
atari800core_simple_sdram #(
    .cycle_length               (32),
    .video_bits                 (8),
    .palette                    (1),    // Altirra palette
    .internal_rom               (0),    // ROMs in SDRAM
    .internal_ram               (0),
    .low_memory                 (0),
    .covox                      (1)
) core (
    .CLK                        (clk_core),
    .RESET_N                    (core_reset_n),

    // Video
    .VIDEO_VS                   (video_vs),
    .VIDEO_HS                   (video_hs),
    .VIDEO_B                    (video_b),
    .VIDEO_G                    (video_g),
    .VIDEO_R                    (video_r),
    .VIDEO_BLANK                (video_blank),
    .VIDEO_PIXCE                (video_pixce),
    .VIDEO_BURST                (),
    .VIDEO_START_OF_FIELD       (),
    .VIDEO_ODD_LINE             (),
    .interlace_field            (),
    .interlace                  (),
    .interlace_enable           (1'b0),
    .HBLANK                     (),
    .VBLANK                     (),

    // Audio
    .STEREO                     (1'b0),
    .AUDIO_L                    (audio_l_pcm),
    .AUDIO_R                    (audio_r_pcm),

    // Joysticks
    .JOY1_n                     (joy1_n),
    .JOY2_n                     (joy2_n),
    .JOY3_n                     (5'b11111),
    .JOY4_n                     (5'b11111),

    // Keyboard matrix
    .KEYBOARD_RESPONSE          (keyboard_response),
    .KEYBOARD_SCAN              (keyboard_scan),

    // SIO
    .SIO_COMMAND                (sio_command),
    .SIO_RXD                    (sio_rx_data_in),
    .SIO_TXD                    (sio_txd),
    .SIO_CLOCK                  (sio_clk_out),
    .SIO_CLOCK_IN               (1'b1),
    .SIO_PROC                   (1'b1),
    .SIO_IRQ                    (1'b1),
    .SIO_MOTOR                  (sio_motor),
    .TAPE_AUDIO                 (8'h00),
    .ENABLE_179_EARLY           (enable_179_early),
    .PORTA_OUT_EXP              (),

    // Console keys
    .CONSOL_START               (consol_start),
    .CONSOL_SELECT              (consol_select),
    .CONSOL_OPTION              (consol_option),

    // SDRAM bus
    .SDRAM_REQUEST              (core_sdram_req),
    .SDRAM_REQUEST_COMPLETE     (core_sdram_req_complete),
    .SDRAM_READ_ENABLE          (core_sdram_read_en),
    .SDRAM_WRITE_ENABLE         (core_sdram_write_en),
    .SDRAM_ADDR                 (core_sdram_addr),
    .SDRAM_DO                   (core_sdram_data_to_core),
    .SDRAM_DI                   (core_sdram_data_from_core),
    .SDRAM_32BIT_WRITE_ENABLE   (core_sdram_32bit_we),
    .SDRAM_16BIT_WRITE_ENABLE   (core_sdram_16bit_we),
    .SDRAM_8BIT_WRITE_ENABLE    (core_sdram_8bit_we),
    .SDRAM_REFRESH              (core_sdram_refresh),

    // DMA port — tied off (ROMs loaded via direct SDRAM write)
    .DMA_FETCH                  (1'b0),
    .DMA_READ_ENABLE            (1'b0),
    .DMA_32BIT_WRITE_ENABLE     (1'b0),
    .DMA_16BIT_WRITE_ENABLE     (1'b0),
    .DMA_8BIT_WRITE_ENABLE      (1'b0),
    .DMA_ADDR                   (26'd0),
    .DMA_WRITE_DATA             (32'd0),
    .MEMORY_READY_DMA           (),
    .DMA_MEMORY_DATA            (),

    // Config
    .RAM_SELECT                 (3'b001),   // 128 KB
    .PAL                        (1'b0),     // NTSC
    .CLIP_SIDES                 (1'b0),
    .RESET_RNMI                 (1'b0),
    .ATARI800MODE               (1'b0),     // XL/XE mode
    .PBI_ROM_MODE               (1'b0),
    .XEX_LOADER_MODE            (1'b0),
    .RTC                        (65'd0),
    .VBXE_SWITCH                (1'b0),
    .VBXE_REG_BASE              (1'b0),
    .VBXE_NTSC_FIX              (1'b0),
    .VBXE_PALETTE_RGB           (3'd0),
    .VBXE_PALETTE_INDEX         (8'd0),
    .VBXE_PALETTE_COLOR         (7'd0),
    .HALT                       (overlay_core),
    .THROTTLE_COUNT_6502        (6'd31),
    .emulated_cartridge_select  (8'd0),
    .emulated_cartridge2_select (8'd0),
    .EMU_FLASH_REQUEST          (),
    .EMU_FLASH_SLAVE            (),
    .freezer_enable             (1'b0),
    .freezer_activate           (1'b0)
);

// ─────────────────────────────────────────────────────────────────────────────
// USB HID keyboard
// ─────────────────────────────────────────────────────────────────────────────
usb_hid_host usb_hid (
    .usbclk       (clk_usb),
    .usbrst_n     (usb_reset_n),
    .usb_dm       (usb_dm),
    .usb_dp       (usb_dp),
    .typ          (),
    .report       (),
    .conerr       (),
    .key_modifiers(usb_key_mod),
    .key1         (usb_key1),
    .key2         (usb_key2),
    .key3         (usb_key3),
    .key4         (usb_key4),
    .mouse_btn    (),
    .mouse_dx     (),
    .mouse_dy     (),
    .game_l       (),
    .game_r       (),
    .game_u       (),
    .game_d       (),
    .game_a       (),
    .game_b       (),
    .game_x       (),
    .game_y       (),
    .game_sel     (),
    .game_sta     (),
    .dbg_hid_report()
);


usb_to_atari800 keyboard (
    .clk              (sys_clk),
    .reset_n          (core_reset_n),
    .key_modifiers    (combined_key_mod),
    .key1             (combined_key1),
    .key2             (combined_key2),
    .key3             (combined_key3),
    .key4             (combined_key4),
    .keyboard_scan    (keyboard_scan),
    .keyboard_response(keyboard_response),
    .consol_start     (consol_start),
    .consol_select    (consol_select),
    .consol_option    (consol_option)
);

// ─────────────────────────────────────────────────────────────────────────────
// HDMI video source: scale720p scales Atari core output to 720p/60Hz
// ─────────────────────────────────────────────────────────────────────────────
wire [7:0] hdmi_r, hdmi_g, hdmi_b;
wire       hdmi_hs, hdmi_vs, hdmi_de;

scale720p scaler (
    .clk_core  (clk_core),
    .rst_n     (hdmi_rst_n),
    .r_in      (video_r), .g_in(video_g), .b_in(video_b),
    .hs_in     (video_hs), .vs_in(video_vs), .de_in(~video_blank),
    .pixce     (video_pixce), .clk_pixel(clk_pix),
    .r_out(hdmi_r), .g_out(hdmi_g), .b_out(hdmi_b),
    .hs_out(hdmi_hs), .vs_out(hdmi_vs), .de_out(hdmi_de),
    .osd_x(osd_x), .osd_y(osd_y)
);

// OSD RGB colors conversion from BGR5:
// overlay_color[4:0]   -> Red
// overlay_color[9:5]   -> Green
// overlay_color[14:10] -> Blue
wire [7:0] osd_r = {overlay_color[4:0],   overlay_color[4:2]};
wire [7:0] osd_g = {overlay_color[9:5],   overlay_color[9:7]};
wire [7:0] osd_b = {overlay_color[14:10], overlay_color[14:12]};

// Draw OSD character/logo pixel if overlay is enabled, active, and color is not transparent (black)
wire       osd_active = overlay && (overlay_color[14:0] != 15'd0) && hdmi_de;

wire [7:0] mixed_r = osd_active ? osd_r : hdmi_r;
wire [7:0] mixed_g = osd_active ? osd_g : hdmi_g;
wire [7:0] mixed_b = osd_active ? osd_b : hdmi_b;

// Pipeline register to eliminate the setup violation from the OSD RAM
// all the way to the HDMI TMDS encoders.
reg [7:0] mixed_r_reg = 8'd0;
reg [7:0] mixed_g_reg = 8'd0;
reg [7:0] mixed_b_reg = 8'd0;
reg       hdmi_hs_reg = 1'b0;
reg       hdmi_vs_reg = 1'b0;
reg       hdmi_de_reg = 1'b0;

always_ff @(posedge clk_pix) begin
    mixed_r_reg <= mixed_r;
    mixed_g_reg <= mixed_g;
    mixed_b_reg <= mixed_b;
    hdmi_hs_reg <= hdmi_hs;
    hdmi_vs_reg <= hdmi_vs;
    hdmi_de_reg <= hdmi_de;
end

// `define USE_TEST_PATTERN

`ifdef USE_TEST_PATTERN
wire [7:0] tp_r, tp_g, tp_b;
wire       tp_hs, tp_vs, tp_de;
test_pattern_720p tp (
    .clk_pixel(clk_pix),
    .rst_n    (hdmi_rst_n),
    .r_out    (tp_r),
    .g_out    (tp_g),
    .b_out    (tp_b),
    .hs_out   (tp_hs),
    .vs_out   (tp_vs),
    .de_out   (tp_de)
);
`endif

// ─────────────────────────────────────────────────────────────────────────────
// HDMI output (video + audio data islands)
// ─────────────────────────────────────────────────────────────────────────────
hdmi_audio_out #(
    .DVI_OUTPUT(1'b0),
    .NO_DATA_ISLANDS(1'b0)
) hdmi (
    .clk_pix    (clk_pix),
    .clk_5x     (clk_5x),
    .rst_n      (hdmi_rst_n),
`ifdef USE_TEST_PATTERN
    .r          (tp_r),
    .g          (tp_g),
    .b          (tp_b),
    .hs         (tp_hs),
    .vs         (tp_vs),
    .de         (tp_de),
`else
    .r          (mixed_r_reg),
    .g          (mixed_g_reg),
    .b          (mixed_b_reg),
    .hs         (hdmi_hs_reg),
    .vs         (hdmi_vs_reg),
    .de         (hdmi_de_reg),
`endif
    .audio_l    (audio_l_out),
    .audio_r    (audio_r_out),
    .tmds_p     (tmds_p),
    .tmds_n     (tmds_n),
    .tmds_clk_p (tmds_clk_p),
    .tmds_clk_n (tmds_clk_n)
);

/*
DVI_TX_Top hdmi (
    .I_rst_n       (hdmi_rst_n),
    .I_serial_clk  (clk_5x),
    .I_rgb_clk     (clk_pix),
`ifdef USE_TEST_PATTERN
    .I_rgb_vs      (tp_vs), 
    .I_rgb_hs      (tp_hs),    
    .I_rgb_de      (tp_de), 
    .I_rgb_r       (tp_r),  
    .I_rgb_g       (tp_g),  
    .I_rgb_b       (tp_b),  
`else
    .I_rgb_vs      (hdmi_vs_reg), 
    .I_rgb_hs      (hdmi_hs_reg),    
    .I_rgb_de      (hdmi_de_reg), 
    .I_rgb_r       (mixed_r_reg),  
    .I_rgb_g       (mixed_g_reg),  
    .I_rgb_b       (mixed_b_reg),  
`endif
    .O_tmds_clk_p  (tmds_clk_p),
    .O_tmds_clk_n  (tmds_clk_n),
    .O_tmds_data_p (tmds_p),
    .O_tmds_data_n (tmds_n)
);
*/

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic free-running blinker — no reset, no external inputs.
// If sys_clk reaches flip-flops, these blink.  blink[26]=0.2 Hz, [25]=0.4 Hz.
// ─────────────────────────────────────────────────────────────────────────────
reg [26:0] blink_cnt = 27'd0;
always_ff @(posedge sys_clk) blink_cnt <= blink_cnt + 1'b1;

// ─────────────────────────────────────────────────────────────────────────────
// LEDs (active low, pins 17-20):
//   [4]=blink_cnt[22] ~6 Hz   [3]=dbg_sd_ready (roms_loaded)
//   [2]=overlay (OSD visible / Atari halted — diagnostic)   [1]=sdram_ready
// overlay replaces pll_locked: if S2 press toggles LED 3 (pin 18), iosys is
// alive.  If the LED never changes, the firmware is stuck.
// ─────────────────────────────────────────────────────────────────────────────
assign leds_n = ~{blink_cnt[22], dbg_sd_ready, overlay, sdram_ready};

endmodule
