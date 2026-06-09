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
wire clk_108m;             // 114.75 MHz — intermediate (rpll_108m CLKOUT)
wire clk_core;             // 28.6875 MHz — Atari core (clk_108m ÷ 4; cl=16 → 1.7898 MHz exact NTSC)
wire clk_mem;              // 57.375 MHz — SDRAM controller (clk_108m ÷ 2; 2:1 synchronous w/ clk_core)
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

// clk_core = 216 ÷ 4 = 54 MHz (Atari machine speed 54/32 = 1.6875 MHz).
// (The 43.2 MHz ÷5 was only a Stage-1 reliability test; timing was never the bug —
// the deadlock was rv_rdata corruption + SDRAM contention, now fixed otherwise.)
CLKDIV #(
    .DIV_MODE ("4"),
    .GSREN    ("false")
) clkdiv_core (
    .CLKOUT (clk_core),
    .HCLKIN (clk_108m),
    .RESETN (pll_core_locked),
    .CALIB  (1'b1)
);

// clk_mem = 114.75 ÷ 2 = 57.375 MHz — SDRAM controller clock (Path B). 2:1 synchronous with
// clk_core (both divide clk_108m), so the SDRAM↔arbiter crossing is related-clock, not async.
CLKDIV #(
    .DIV_MODE ("2"),
    .GSREN    ("false")
) clkdiv_mem (
    .CLKOUT (clk_mem),
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
wire joystick_mode;   // OSD-toggled: arrow keys → Joystick 1, Left-Alt = fire, arrows suppressed from kbd

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

// ── Frame-buffer writer client (Stage 1, docs/frame_buffer_plan.md) ──────────
// Write-only SDRAM client in the clk_core domain (no CDC).  Captures the Atari
// video stream and packs it into the SDRAM double frame buffer.  Nothing reads
// the buffer yet — this stage proves the 3rd arbiter client coexists with the
// hard-real-time Atari core without disturbing it.
wire        fbw_req_raw;
wire [24:0] fbw_addr;
wire [31:0] fbw_wdata;
wire        fbw_ack;
// B0/B1: validate the decoupled SDRAM (clk_mem) + Atari handshake with the writer OFF.
// Flip FB_WRITER_EN to 1'b1 in B3 to bring the writer onto the bus as the 3rd client.
localparam FB_WRITER_EN = 1'b1;
wire        fbw_req = fbw_req_raw & FB_WRITER_EN;

// Frame-buffer reader client (B4) — read-only SDRAM client (clk_core domain).
// Gate fbr_req with core_reset_n so the reader stays OFF the bus until the ROMs are loaded
// (it outranks PicoRV32; ungated it starves the iosys ROM loader → no boot).  The reader's
// raster still free-runs on hdmi_rst_n so HDMI stays locked; only the SDRAM fetch waits.
wire        fbr_req_raw;
wire        fbr_req = fbr_req_raw & core_reset_n;
wire [24:0] fbr_addr;
wire        fbr_ack;
wire [255:0] fbr_rdata;            // 8-word burst read result for the reader
wire [255:0] sdram_burst_dout;

// 3-client SDRAM owner encoding (strict priority Atari > FBwriter > PicoRV32).
localparam [1:0] OWN_ATARI = 2'd0, OWN_RV = 2'd1, OWN_FBW = 2'd2, OWN_FBR = 2'd3;

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

// PicoRV32 SDRAM access is FROZEN while the Atari core is running, because the
// firmware executes from SDRAM and its continuous instruction fetches otherwise
// steal the Atari's SDRAM bus window (an in-flight CPU access can't be preempted
// and pushes the Atari past its cycle_length=32 budget → ANTIC corruption / no
// boot).  We gate rv_req (the access *launch*), so any access already in SA_BUSY
// still completes cleanly.  Real long-term fix: firmware off SDRAM — see memory
// project-firmware-off-sdram.  This is the interim that lets the Atari boot.
//
// CPU runs when: overlay is up (menu shown → Atari HALTed, no contention), OR a
// hardware wake is latched.  Wake is needed because the firmware itself raises the
// overlay in response to S2/F12 — but a frozen CPU can't poll those keys, so the
// wake must come from HARDWARE (outside the CPU): S2 button (btn_n[1]) or F12
// (key_f12, from the hardware keyboard decoder — both SDRAM-independent).
//   - wake set by S2/F12 → CPU unfreezes → firmware sees the key, raises overlay
//   - once overlay is up, it holds the CPU running; the wake latch is then cleared
//   - user dismisses menu → firmware lowers overlay → CPU re-freezes → Atari resumes
// Wake-latch: gives the frozen CPU a momentary window to notice an S2/F12 press
// and raise the overlay; once overlay is up it holds the CPU running.
// Key insight for the "Atari breaks on dismiss" bug:
//   - KICK only on the rising edge of S2/F12 AND only while overlay is DOWN, i.e.
//     only when ENTERING the menu from the frozen state.  When overlay is already
//     UP (the press means DISMISS), we must NOT kick — the CPU is already running
//     via overlay, and on dismiss it should simply re-freeze the instant overlay
//     drops, so the resumed Atari gets the full SDRAM bus with NO contention window.
//   - HOLD the latch until overlay actually comes up (CPU acknowledged), then clear.
//     (Edge-triggered set + brief tap still works, because the edge is captured.)
reg [2:0] overlay_sync_r = 3'b111; // sync overlay into clk_core; default running (ROM load)
reg [2:0] s2_sync_r      = 3'b000;
reg [2:0] f12_sync_r     = 3'b000;
reg       wake_latch     = 1'b0;
wire s2_rise  = s2_sync_r[2:1]  == 2'b01;   // synced rising edge
wire f12_rise = f12_sync_r[2:1] == 2'b01;
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        overlay_sync_r <= 3'b111;
        s2_sync_r      <= 3'b000;
        f12_sync_r     <= 3'b000;
        wake_latch     <= 1'b0;
    end else begin
        overlay_sync_r <= {overlay_sync_r[1:0], overlay};
        s2_sync_r      <= {s2_sync_r[1:0],      btn_n[1]};
        f12_sync_r     <= {f12_sync_r[1:0],     key_f12};
        if ((s2_rise || f12_rise) && !overlay_sync_r[2])
            wake_latch <= 1'b1;          // kick to ENTER menu from frozen state
        else if (overlay_sync_r[2])
            wake_latch <= 1'b0;          // overlay up → it now holds the CPU running
    end
end
// cpu_run_allowed = overlay only. The wake_latch entry-handshake is removed:
// it existed for when firmware ran from SDRAM (gated off until "woken"), but
// firmware now runs from BSRAM and always polls S2/F12 — so it raises the overlay
// itself, no hardware kick needed. The old latch could stick high (S2 -> halt,
// overlay never came up -> Atari frozen unrecoverably). The menu loop touches no
// SDRAM, so the firmware never stalls with the overlay down.
wire cpu_run_allowed = overlay_sync_r[2];
wire _unused_wake = wake_latch; // keep signal defined; logic below is now dead


wire rv_req = rv_valid_core && !rv_hold && cpu_run_allowed;  // gated new request

// ── Dual-Client SDRAM Arbiter & Adapter ──────────────────────────────────────
wire        sdram_complete;
reg         sdram_complete_r = 1'b0;
reg  [1:0]  sdram_owner = OWN_ATARI; // OWN_ATARI / OWN_RV / OWN_FBW

assign sdram_complete = sdram_complete_r;
assign core_sdram_req_complete = sdram_complete && (sdram_owner == OWN_ATARI);
assign rv_ready                = rv_ready_sync;

wire [31:0] sdram_rd_data_wire;
wire        sdram_ready_wire;

assign core_sdram_data_to_core = sdram_rd_data_wire >> {core_sdram_addr[1:0], 3'b000};
// rv_rdata reads from a latch captured at PicoRV32 transaction completion (see the
// SA_BUSY completion block) so Atari reads can't overwrite it before the CPU samples it.
reg [31:0] rv_rdata_hold = 32'd0;
assign rv_rdata                = rv_rdata_hold;
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
        end else if (sadap_st == SA_BUSY && sdram_owner == OWN_ATARI && sdram_complete_wire) begin
            atari_req_pending <= 1'b0;
        end
    end
end

// Arbitration policy: STRICT ATARI PRIORITY.
// The Atari core must always get the SDRAM the moment it has a pending request,
// or its access misses the cycle_length=32 bus window and ANTIC DMA corrupts /
// the machine fails to boot.  PicoRV32 uses only genuinely idle cycles.
//
// The previous design used `rv_slot` to force PicoRV32 a guaranteed slot after
// every Atari access (round-robin), to keep the UART keyboard / OSD responsive.
// That reason is now OBSOLETE:
//   - the keyboard is decoded in hardware (SDRAM-independent), and
//   - the OSD only runs while the Atari core is HALTed (overlay → .HALT), so the
//     Atari isn't requesting SDRAM then and PicoRV32 gets the bus anyway.
// Forced fairness pushed the Atari past its window and prevented boot, so it is
// removed.  See memory: project-firmware-off-sdram (the real long-term fix is
// moving firmware off SDRAM; do NOT re-add softcore priority here).
reg rv_slot = 1'b0;  // retained (assigned but unused) to minimise churn; always 0 in policy

// Strict priority: Atari first, then the frame-buffer writer (fills idle cycles
// without ever preempting the Atari), then PicoRV32.  The writer is a clk_core,
// write-only client — no CDC, the simplest of the three.
wire [1:0] next_owner = atari_req_pending             ? OWN_ATARI :
                        fbw_req                       ? OWN_FBW   :
                        fbr_req                       ? OWN_FBR   :
                        (rv_req && !sdram_complete_r) ? OWN_RV    : OWN_ATARI;

wire next_req = atari_req_pending || fbw_req || fbr_req ||
                (rv_req && !sdram_complete_r);

wire [1:0] current_owner = (sadap_st == SA_BUSY) ? sdram_owner : next_owner;
// During SA_BUSY keep the persistent request of the active owner (rv_valid_core,
// not rv_req, so an in-progress PicoRV32 transaction is not dropped mid-flight if
// rv_hold happens to be set; fbw_req is held by the writer until its ack).
// SA_WAIT forces req low for one clk_core cycle (= 2 clk_mem cycles) after each access so the
// clk_mem SDRAM wrapper sees a clean req-deassert boundary between back-to-back accesses
// (4-phase handshake across the 2:1 clk_core↔clk_mem crossing).
wire sdram_ctrl_req = (sadap_st == SA_WAIT) ? 1'b0 :
                      (sadap_st == SA_BUSY) ?
                          ((sdram_owner == OWN_RV)  ? rv_valid_core    :
                           (sdram_owner == OWN_FBW) ? fbw_req          :
                           (sdram_owner == OWN_FBR) ? fbr_req          :
                                                      atari_req_pending)
                          : next_req;
wire        sdram_ctrl_read_en  = (current_owner == OWN_RV)  ? (~|rv_wstrb) :
                                  (current_owner == OWN_FBW) ? 1'b0         :
                                  (current_owner == OWN_FBR) ? 1'b1         : core_sdram_read_en;
wire        sdram_ctrl_write_en = (current_owner == OWN_RV)  ? (|rv_wstrb)  :
                                  (current_owner == OWN_FBW) ? 1'b1         :
                                  (current_owner == OWN_FBR) ? 1'b0         : core_sdram_write_en;
wire [24:0] sdram_ctrl_addr     = (current_owner == OWN_RV)  ? rv_physical_addr :
                                  (current_owner == OWN_FBW) ? fbw_addr         :
                                  (current_owner == OWN_FBR) ? fbr_addr         : core_sdram_addr;
wire [31:0] sdram_ctrl_wdata    = (current_owner == OWN_RV)  ? rv_wdata  :
                                  (current_owner == OWN_FBW) ? fbw_wdata : {4{core_sdram_data_from_core[7:0]}};
wire [3:0]  sdram_ctrl_wmask    = (current_owner == OWN_RV)  ? rv_wstrb :
                                  (current_owner == OWN_FBW) ? 4'b1111  :
                                  (current_owner == OWN_FBR) ? 4'b0000  : core_sdram_wmask;
wire        sdram_ctrl_refresh  = core_sdram_refresh;

// fb_writer FIFO pop / fb_reader word strobe: 1-cycle pulses at their access completion.
assign fbw_ack  = (sadap_st == SA_BUSY) && (sdram_owner == OWN_FBW) && sdram_complete_wire;
assign fbr_ack  = (sadap_st == SA_BUSY) && (sdram_owner == OWN_FBR) && sdram_complete_wire;
assign fbr_rdata = sdram_burst_dout;
// Reader accesses are always BL8 burst reads.
wire   sdram_ctrl_burst = (current_owner == OWN_FBR);

wire        sdram_complete_wire;

typedef enum logic [1:0] { SA_IDLE, SA_BUSY, SA_WAIT } sadap_t;
sadap_t sadap_st = SA_IDLE;

always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        sdram_complete_r <= 1'b0;
        sadap_st         <= SA_IDLE;
        sdram_owner      <= OWN_ATARI;
        rv_slot          <= 1'b0;
        rv_done_toggle_r <= 1'b0;
        rv_hold          <= 1'b0;
    end else begin
        sdram_complete_r <= 1'b0;

        // rv_hold: set when a PicoRV32 transaction completes; cleared when
        // rv_valid_core deasserts.  Prevents phantom re-launches while waiting
        // for the rv_ready toggle-sync pulse to reach iosys (≈8 clk_core cycles).
        if (sdram_complete_r && sdram_owner == OWN_RV) rv_hold <= 1'b1;
        if (!rv_valid_core)                            rv_hold <= 1'b0;

        case (sadap_st)
            SA_IDLE: begin
                if (sdram_ready_wire) begin
                    // Strict priority Atari > FBwriter > PicoRV32.  The Atari wins
                    // whenever it has a pending request; the frame-buffer writer
                    // takes the next idle cycle; PicoRV32 is served only when both
                    // the Atari and the writer are idle.
                    if (atari_req_pending) begin
                        sdram_owner <= OWN_ATARI;
                        sadap_st    <= SA_BUSY;
                    end else if (fbw_req) begin
                        sdram_owner <= OWN_FBW;
                        sadap_st    <= SA_BUSY;
                    end else if (fbr_req) begin
                        sdram_owner <= OWN_FBR;
                        sadap_st    <= SA_BUSY;
                    end else if (rv_req && !sdram_complete_r) begin
                        sdram_owner <= OWN_RV;
                        sadap_st    <= SA_BUSY;
                    end
                end
            end
            SA_BUSY: begin
                if (sdram_complete_wire) begin
                    sdram_complete_r <= 1'b1;
                    sadap_st         <= SA_WAIT;   // one req-low cycle before the next access
                    // (rv_slot forced-fairness removed — strict Atari priority now.)
                    rv_slot <= 1'b0;
                    // Pulse the toggle-sync for iosys rv_ready, and CAPTURE the
                    // read data NOW.  sdram_rd_data_wire is the controller's single
                    // shared rdata register; if we left rv_rdata combinational, an
                    // Atari read in the ~3-cycle window before PicoRV32 captures it
                    // (completion toggle crossing clk_core→sys_clk) would overwrite
                    // it → PicoRV32 latches Atari data → corrupted firmware word →
                    // wild jump → undecoded-address hang.  Latching here prevents it.
                    if (sdram_owner == OWN_RV) begin
                        rv_done_toggle_r <= ~rv_done_toggle_r;
                        rv_rdata_hold    <= sdram_rd_data_wire;
                    end
                end
            end
            SA_WAIT: sadap_st <= SA_IDLE;   // req held low here; wrapper sees the boundary
            default: sadap_st <= SA_IDLE;
        endcase
    end
end

// Synchronise rv_done_toggle_r (clk_core) into sys_clk for iosys rv_ready
always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) rv_done_sys_r <= 3'b000;
    else             rv_done_sys_r <= {rv_done_sys_r[1:0], rv_done_toggle_r};
end

// ── DEADLOCK DISCRIMINATOR (sys_clk domain — what the CPU actually sees) ──────
// Distinguishes the two candidate deadlock mechanisms:
//   diag_req_no_grant : rv_valid held high a long time with NO rv_ready returning
//                       → request never served end-to-end (arbiter starves it)
//   diag_grant_no_ack : the clk_core arbiter toggled rv_done_toggle_r (work
//                       completed) but no rv_ready edge was produced for the CPU
//                       → completion lost crossing clk_core→sys_clk
// Both are sticky (latched until reset) so a momentary deadlock is captured.
reg        diag_req_no_grant = 1'b0;
reg [19:0] diag_stall_cnt    = 20'd0;   // ~38 ms at 27 MHz before declaring stall
reg        rv_done_sys_prev  = 1'b0;    // last value of synced toggle stage [2]
always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        diag_req_no_grant <= 1'b0;
        diag_stall_cnt    <= 20'd0;
        rv_done_sys_prev  <= 1'b0;
    end else begin
        // Track the synced completion toggle: a change at stage [2] means the
        // arbiter completed an rv access (a "grant" reached the CPU domain).
        rv_done_sys_prev <= rv_done_sys_r[2];

        // Stall timer: counts while CPU is requesting (rv_valid) but no completion
        // toggle change has arrived. Reset whenever a completion crosses over.
        if (rv_done_sys_r[2] != rv_done_sys_prev) begin
            diag_stall_cnt <= 20'd0;                 // a grant/ack crossed — healthy
        end else if (rv_valid) begin
            if (diag_stall_cnt == 20'hFFFFF) begin
                // CPU has been waiting a long time with no completion crossing.
                diag_req_no_grant <= 1'b1;
            end else begin
                diag_stall_cnt <= diag_stall_cnt + 20'd1;
            end
        end
    end
end

// rv-completion activity window (clk_core): lit while the arbiter has completed
// an rv access recently (~0.2 s).  Read TOGETHER with diag_req_no_grant:
//   LED2(req_no_grant)=ON, LED3(rv_act)=ON  → arbiter still completing but CPU
//                                              never gets rv_ready  ⇒ ACK LOST in CDC
//   LED2=ON, LED3=OFF                        → arbiter stopped completing rv
//                                              accesses entirely    ⇒ NEVER GRANTED
localparam RVACT_WINDOW = 27_000_000/5;   // ~0.2 s at clk_core (≤54 MHz, fits 23b margin)
reg        rv_done_toggle_prev = 1'b0;
reg [23:0] rv_act_cnt = 24'd0;
wire       rv_act_recent = (rv_act_cnt != 0);
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        rv_done_toggle_prev <= 1'b0;
        rv_act_cnt          <= 24'd0;
    end else begin
        rv_done_toggle_prev <= rv_done_toggle_r;
        if (rv_done_toggle_r != rv_done_toggle_prev) rv_act_cnt <= RVACT_WINDOW[23:0];
        else if (rv_act_cnt != 0)                    rv_act_cnt <= rv_act_cnt - 24'd1;
    end
end

gw2ar_sdram sdram_ip (
    .clk          (clk_core),
    .clk_mem      (clk_mem),
    .reset_n      (hw_reset_n),

    // User interface
    .req          (sdram_ctrl_req),
    .req_complete (sdram_complete_wire),
    .read_en      (sdram_ctrl_read_en),
    .write_en     (sdram_ctrl_write_en),
    .burst        (sdram_ctrl_burst),
    .addr         (sdram_ctrl_addr),
    .rdata        (sdram_rd_data_wire),
    .burst_rdata  (sdram_burst_dout),
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

// ── Frame-buffer writer (Stage 1) ────────────────────────────────────────────
// Captures the Atari video stream and packs RGB332 words into the SDRAM double
// frame buffer at FB_BASE = 0x780000 (the core's documented "Free 512K below 8MB",
// address_decoder.vhdl:915 — clear of RAM/ROM/cartridge).  Reset with core_reset_n
// so it stays idle until the ROMs are loaded (iosys keeps SDRAM priority during
// load).  Nothing reads the buffer yet — Stage 2 adds the reader.
fb_writer #(
    .FB_BASE        (25'h0078_0000),
    .WORDS_PER_LINE (88),
    .LINES          (240),
    .FB_SIZE        (25'd84480)
) fb_writer_inst (
    .clk_core (clk_core),
    .rst_n    (core_reset_n),
    .r_in     (video_r),
    .g_in     (video_g),
    .b_in     (video_b),
    .de_in    (~video_blank),
    .vs_in    (video_vs),
    .pixce    (video_pixce),
    .fbw_req  (fbw_req_raw),
    .fbw_addr (fbw_addr),
    .fbw_wdata(fbw_wdata),
    .fbw_ack  (fbw_ack)
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

// ── Hardware CH9350 keyboard decoder (SDRAM-decoupled Stage 1) ────────────────
// Taps the same UART RX (pin 51 / usb_dp) as the firmware, decodes CH9350 frames
// in hardware, and drives the key matrix without the PicoRV32/SDRAM path.
// See docs/hw_keyboard_decouple.md.
wire [7:0] hk_mod, hk_key1, hk_key2, hk_key3, hk_key4;

uart_kbd_ch9350 #(
    .CLK_HZ(27_000_000), .BAUD(115200), .TIMEOUT_MS(1000)
) uart_kbd (
    .clk(sys_clk), .reset_n(hw_reset_n), .uart_rx(usb_dp),
    .kbd_mod(hk_mod), .kbd_key1(hk_key1), .kbd_key2(hk_key2),
    .kbd_key3(hk_key3), .kbd_key4(hk_key4)
);

// CDC: held bytes (sys_clk) → clk_core (the core matrix domain). 2-FF per bit;
// bytes are quasi-static between updates so no handshake is needed.
reg [7:0] hk_mod_m,  hk_mod_s;
reg [7:0] hk_k1_m,   hk_k1_s;
reg [7:0] hk_k2_m,   hk_k2_s;
reg [7:0] hk_k3_m,   hk_k3_s;
reg [7:0] hk_k4_m,   hk_k4_s;
always_ff @(posedge clk_core) begin
    {hk_mod_s, hk_mod_m} <= {hk_mod_m, hk_mod};
    {hk_k1_s,  hk_k1_m}  <= {hk_k1_m,  hk_key1};
    {hk_k2_s,  hk_k2_m}  <= {hk_k2_m,  hk_key2};
    {hk_k3_s,  hk_k3_m}  <= {hk_k3_m,  hk_key3};
    {hk_k4_s,  hk_k4_m}  <= {hk_k4_m,  hk_key4};
end

// Combine USB keyboard keys and PicoRV32 virtual serial keyboard keys
wire [7:0] effective_usb_key_mod = usb_host_enable ? usb_key_mod : 8'h00;
wire [7:0] effective_usb_key1    = usb_host_enable ? usb_key1    : 8'h00;
wire [7:0] effective_usb_key2    = usb_host_enable ? usb_key2    : 8'h00;
wire [7:0] effective_usb_key3    = usb_host_enable ? usb_key3    : 8'h00;
wire [7:0] effective_usb_key4    = usb_host_enable ? usb_key4    : 8'h00;

// Priority: hardware CH9350 decoder > firmware virt_kbd (OPTION-hold injection,
// boot keys) > USB-HID fallback.  Per-slot "non-zero wins" (0x00 = empty HID slot).
wire [7:0] hv_key1 = (hk_k1_s != 8'h00) ? hk_k1_s : virt_kbd_key1;
wire [7:0] hv_key2 = (hk_k2_s != 8'h00) ? hk_k2_s : virt_kbd_key2;
wire [7:0] hv_key3 = (hk_k3_s != 8'h00) ? hk_k3_s : virt_kbd_key3;
wire [7:0] hv_key4 = (hk_k4_s != 8'h00) ? hk_k4_s : virt_kbd_key4;

wire [7:0] combined_key_mod = hk_mod_s | virt_kbd_mod | effective_usb_key_mod;
wire [7:0] combined_key1    = (hv_key1 != 8'h00) ? hv_key1 : effective_usb_key1;
wire [7:0] combined_key2    = (hv_key2 != 8'h00) ? hv_key2 : effective_usb_key2;
wire [7:0] combined_key3    = (hv_key3 != 8'h00) ? hv_key3 : effective_usb_key3;
wire [7:0] combined_key4    = (hv_key4 != 8'h00) ? hv_key4 : effective_usb_key4;

// OSD navigation: driven by BOTH real USB keyboard and virtual UART keyboard.
wire key_up    = (combined_key1 == 8'h52) || (combined_key2 == 8'h52) || (combined_key3 == 8'h52) || (combined_key4 == 8'h52); // Up Arrow
wire key_down  = (combined_key1 == 8'h51) || (combined_key2 == 8'h51) || (combined_key3 == 8'h51) || (combined_key4 == 8'h51); // Down Arrow
wire key_left  = (combined_key1 == 8'h50) || (combined_key2 == 8'h50) || (combined_key3 == 8'h50) || (combined_key4 == 8'h50); // Left Arrow
wire key_right = (combined_key1 == 8'h4F) || (combined_key2 == 8'h4F) || (combined_key3 == 8'h4F) || (combined_key4 == 8'h4F); // Right Arrow
wire key_enter = (combined_key1 == 8'h28) || (combined_key2 == 8'h28) || (combined_key3 == 8'h28) || (combined_key4 == 8'h28); // Enter
wire key_esc   = (combined_key1 == 8'h29) || (combined_key2 == 8'h29) || (combined_key3 == 8'h29) || (combined_key4 == 8'h29); // Escape
wire key_f12   = (combined_key1 == 8'h45) || (combined_key2 == 8'h45) || (combined_key3 == 8'h45) || (combined_key4 == 8'h45); // F12

// ── Arrow-keys-as-Joystick mode (OSD-toggled via joystick_mode) ──────────────
// Left-Alt = fire. When on, the arrow keys + Left-Alt drive Joystick 1 (OR'd
// with the physical DB9 stick) and are suppressed from the Atari keyboard matrix
// so they don't also type. JOY1_n is active-low: bit0=up,1=down,2=left,3=right,4=fire.
wire key_lalt = combined_key_mod[2];   // HID Left-Alt modifier
wire [4:0] joy1_kbd_n = joystick_mode ? ~{key_lalt, key_right, key_left, key_down, key_up}
                                      : 5'b11111;
wire [4:0] joy1_to_core = joy1_n & joy1_kbd_n;   // key OR physical stick pulls a bit low

// Keyboard-matrix keys with the joystick keys (arrows 0x4F-0x52, Left-Alt) removed
// while joystick_mode is on, so they only move the stick and don't type.
wire [7:0] mtx_key1 = (joystick_mode && combined_key1 >= 8'h4F && combined_key1 <= 8'h52) ? 8'h00 : combined_key1;
wire [7:0] mtx_key2 = (joystick_mode && combined_key2 >= 8'h4F && combined_key2 <= 8'h52) ? 8'h00 : combined_key2;
wire [7:0] mtx_key3 = (joystick_mode && combined_key3 >= 8'h4F && combined_key3 <= 8'h52) ? 8'h00 : combined_key3;
wire [7:0] mtx_key4 = (joystick_mode && combined_key4 >= 8'h4F && combined_key4 <= 8'h52) ? 8'h00 : combined_key4;
wire [7:0] mtx_mod  = joystick_mode ? (combined_key_mod & ~8'h04) : combined_key_mod; // drop Left-Alt

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

assign dbg_sd_ready = roms_loaded;

// ── Frame-rate / lines-per-frame diagnostic ─────────────────────────────────
// Count the Atari core's own video sync (clk_core domain): vs rising edge = one
// frame, hs rising edges = scanlines. Lets the firmware compute the REAL frame
// rate and lines/frame to localize the "runs ~1/3 fast" issue (vertical line
// count vs horizontal line length). Reliable: pure counters, no SDRAM, latched
// values change slowly so a plain 2-FF sync to sys_clk is safe.
reg        video_vs_d = 1'b0, video_hs_d = 1'b0;
reg [15:0] vs_frame_count = 16'd0;   // free-running: +1 per frame
reg [15:0] line_count     = 16'd0;   // scanlines in the current frame
reg [15:0] lines_per_frame = 16'd0;  // latched at end of each frame
always_ff @(posedge clk_core) begin
    video_vs_d <= video_vs;
    video_hs_d <= video_hs;
    if (~video_hs_d & video_hs) line_count <= line_count + 16'd1;   // hsync rising
    if (~video_vs_d & video_vs) begin                               // vsync rising
        vs_frame_count  <= vs_frame_count + 16'd1;
        lines_per_frame <= line_count;
        line_count      <= 16'd0;
    end
end
reg [15:0] vs_cnt_s1, vs_cnt_sys, lpf_s1, lpf_sys;
always_ff @(posedge sys_clk) begin
    vs_cnt_s1 <= vs_frame_count;  vs_cnt_sys <= vs_cnt_s1;
    lpf_s1    <= lines_per_frame; lpf_sys    <= lpf_s1;
end
wire [31:0] video_diag = {lpf_sys, vs_cnt_sys};  // [31:16]=lines/frame, [15:0]=frame counter

// SIO response-line meter results (packed as 4x 32-bit words; see the meter below).
// word0=min_low word1=min_high word2=ack_lat word3=edges, all in sys_clk cycles.
// sio_cap_meta[7:0] = count of response windows measured (0 => none seen).
// Driven below (after the SIO sync signals are defined).
reg [127:0] sio_cap_buf  = 128'd0;
reg [31:0]  sio_cap_meta = 32'd0;

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

    // Frame-rate / lines-per-frame diagnostic
    .video_diag(video_diag),
    .sio_cap_buf({sio_cap_meta, sio_cap_buf}),  // word4 = meta (trig count), words0-3 = samples

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
    .joystick_mode_out(joystick_mode),
    .joy_poll_dbg(joy_poll_dbg),
    .cpu_progress_dbg(cpu_progress_dbg),
    .dbg_stall_undec_out(dbg_stall_undec),
    .dbg_stall_peri_out(dbg_stall_peri),
    .dbg_stall_ram_out(dbg_stall_ram),

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

// Clock Domain Crossing (CDC) Synchronization for SIO Handler
// POKEY_ENABLE toggle synchronizer (from 54 MHz clk_core to 27 MHz sys_clk)
// Use hw_reset_n to avoid CDC reset timing issues.
reg enable_179_early_toggle = 1'b0;
always_ff @(posedge clk_core or negedge hw_reset_n) begin
    if (!hw_reset_n)
        enable_179_early_toggle <= 1'b0;
    else if (enable_179_early)
        enable_179_early_toggle <= ~enable_179_early_toggle;
end

reg [2:0] enable_179_early_sync = 3'b0;
always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n)
        enable_179_early_sync <= 3'b0;
    else
        enable_179_early_sync <= {enable_179_early_sync[1:0], enable_179_early_toggle};
end
wire enable_179_early_sys = enable_179_early_sync[2] ^ enable_179_early_sync[1];

// Double synchronizers for asynchronous SIO input lines (Atari outputs to sys_clk)
reg [1:0] SIO_COMMAND_sync = 2'b11;
reg [1:0] SIO_TXD_sync     = 2'b11;
reg [1:0] SIO_CLOCK_sync   = 2'b11;

always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        SIO_COMMAND_sync <= 2'b11;
        SIO_TXD_sync     <= 2'b11;
        SIO_CLOCK_sync   <= 2'b11;
    end else begin
        SIO_COMMAND_sync <= {SIO_COMMAND_sync[0], sio_command};
        SIO_TXD_sync     <= {SIO_TXD_sync[0], sio_txd};
        SIO_CLOCK_sync   <= {SIO_CLOCK_sync[0], sio_clk_out};
    end
end

wire sio_command_sys = SIO_COMMAND_sync[1];
wire sio_txd_sys     = SIO_TXD_sync[1];
wire sio_clk_out_sys = SIO_CLOCK_sync[1];

// ── SIO RESPONSE-line meter (diagnostic) ─────────────────────────────────────
// Taps the handler->Atari line (sio_rx_data_in, already in sys_clk) directly,
// independent of the handler's own (broken) txdiag register. On COMMAND rising
// (the Atari has finished its command and is now waiting for the ACK) it opens a
// ~16 ms window and measures the response, in sys_clk (27 MHz) cycles:
//   word0 = min_low   : shortest LOW run on the response line (~1 ACK bit ~1488)
//   word1 = min_high  : shortest HIGH run after the first low (~1 bit)
//   word2 = ack_lat   : cycles from COMMAND-high to the FIRST start bit of the
//                       response. 0xFFFFFF (16777215) => the handler NEVER drove
//                       the line low => no ACK was transmitted at all.
//   word3 = bytes     : first 4 decoded response bytes {byte0,byte1,byte2,byte3}
//                       (byte0 = first byte sent; a clean STATUS reply = 41 43 ..)
//   word4 = sio_cap_meta[7:0] : count of response windows measured
localparam [23:0] RESP_WINDOW = 24'd432000;  // ~16 ms at 27 MHz
localparam [11:0] BIT1_5 = 12'd2256;         // 1.5 bit periods (centre of data bit 0)
localparam [11:0] BIT1_0 = 12'd1504;         // 1 bit period (measured)
reg        rxd_d     = 1'b1;
reg        rcmd_d    = 1'b1;
reg        rmeas     = 1'b0;
reg        rseen_low = 1'b0;
reg [15:0] rrun      = 16'd0;
reg [15:0] rmin_low  = 16'hFFFF;
reg [15:0] rmin_high = 16'hFFFF;
reg [23:0] rwin      = 24'd0;
reg [23:0] rack_lat  = 24'hFFFFFF;
// async byte decoder (samples the response line at the measured bit period)
reg        bd_active  = 1'b0;
reg [11:0] bd_timer   = 12'd0;
reg [3:0]  bd_bitcnt  = 4'd0;
reg [7:0]  bd_shift   = 8'd0;
reg [2:0]  bd_bytecnt = 3'd0;
reg [31:0] bd_bytes   = 32'd0;   // {byte0,byte1,byte2,byte3}, byte0 first
always_ff @(posedge sys_clk or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        rxd_d <= 1'b1; rcmd_d <= 1'b1; rmeas <= 1'b0; rseen_low <= 1'b0; rrun <= 16'd0;
        rmin_low <= 16'hFFFF; rmin_high <= 16'hFFFF; rwin <= 24'd0; rack_lat <= 24'hFFFFFF;
        bd_active <= 1'b0; bd_timer <= 12'd0; bd_bitcnt <= 4'd0; bd_bytecnt <= 3'd0; bd_bytes <= 32'd0;
        sio_cap_buf <= 128'd0; sio_cap_meta <= 32'd0;
    end else begin
        rxd_d  <= sio_rx_data_in;
        rcmd_d <= sio_command_sys;
        if (!rcmd_d && sio_command_sys) begin
            // COMMAND rising: open the response window and reset the decoder
            rmeas <= 1'b1; rseen_low <= 1'b0; rrun <= 16'd0; rwin <= 24'd0;
            rmin_low <= 16'hFFFF; rmin_high <= 16'hFFFF; rack_lat <= 24'hFFFFFF;
            bd_active <= 1'b0; bd_bitcnt <= 4'd0; bd_bytecnt <= 3'd0; bd_bytes <= 32'd0; bd_timer <= 12'd0;
        end else if (rmeas) begin
            rwin <= rwin + 24'd1;
            // ---- pulse statistics ----
            if (rxd_d ^ sio_rx_data_in) begin
                if (rxd_d == 1'b0) begin
                    if (rrun < rmin_low) rmin_low <= rrun;
                end else if (rseen_low) begin
                    if (rrun < rmin_high) rmin_high <= rrun;
                end
                if (rxd_d && !sio_rx_data_in && !rseen_low) rack_lat <= rwin;
                if (rxd_d && !sio_rx_data_in) rseen_low <= 1'b1;
                rrun <= 16'd1;
            end else begin
                rrun <= rrun + 16'd1;
            end
            // ---- async byte decoder: capture first 4 response bytes ----
            if (!bd_active) begin
                if (bd_bytecnt < 3'd4 && rxd_d && !sio_rx_data_in) begin // start bit
                    bd_active <= 1'b1; bd_timer <= 12'd0; bd_bitcnt <= 4'd0;
                end
            end else begin
                bd_timer <= bd_timer + 12'd1;
                if (bd_timer == ((bd_bitcnt == 4'd0) ? BIT1_5 : BIT1_0)) begin
                    bd_shift <= {sio_rx_data_in, bd_shift[7:1]};   // LSB first
                    bd_timer <= 12'd0;
                    if (bd_bitcnt == 4'd7) begin
                        bd_bytes   <= {bd_bytes[23:0], sio_rx_data_in, bd_shift[7:1]};
                        bd_bytecnt <= bd_bytecnt + 3'd1;
                        bd_active  <= 1'b0;
                    end else begin
                        bd_bitcnt <= bd_bitcnt + 4'd1;
                    end
                end
            end
            if (rwin == RESP_WINDOW - 1) begin
                rmeas        <= 1'b0;
                sio_cap_buf  <= { bd_bytes, 8'd0, rack_lat, 16'd0, rmin_high, 16'd0, rmin_low };
                sio_cap_meta <= sio_cap_meta + 32'd1;
            end
        end
    end
end

// VHDL SIO Disk Handler
sio_handler sio_inst (
    .CLK(sys_clk),
    .ADDR(sio_reg_addr),
    .CPU_DATA_IN(sio_reg_wdata),
    .EN(sio_reg_en),
    .WR_EN(sio_reg_wr),
    .RESET_N(hw_reset_n),
    .POKEY_ENABLE(enable_179_early_sys),
    .SIO_DATA_IN(sio_rx_data_in),
    .SIO_COMMAND(sio_command_sys),
    .SIO_DATA_OUT(sio_txd_sys),
    .SIO_CLK_OUT(sio_clk_out_sys),
    .DATA_OUT(sio_reg_rdata)
);

// ─────────────────────────────────────────────────────────────────────────────
// Atari 800 core
// ─────────────────────────────────────────────────────────────────────────────
atari800core_simple_sdram #(
    .cycle_length               (16),
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
    .JOY1_n                     (joy1_to_core),
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
    // HALT the Atari whenever the PicoRV32 is permitted SDRAM access, NOT just when
    // the overlay is up.  cpu_run_allowed = overlay || wake_latch, so the instant
    // S2/F12 wakes the CPU (wake_latch) the Atari is halted FIRST — guaranteeing the
    // two are mutually exclusive on SDRAM (exactly one runs at a time).  Tying HALT
    // only to overlay left a window where wake_latch ran the CPU while the Atari was
    // still live → both hammered SDRAM → emulation broke on menu entry.
    .HALT                       (cpu_run_allowed),
    // 0 = true 1x 6502 speed (CPU runs only on enable_179, locked to ANTIC/POKEY).
    // The speed-shift logic ADDS a CPU enable per set throttle bit, so 6'd31 was
    // 6 enables/machine-cycle => ~6x too fast (boot/loop 6x, SIO windows 6x narrow).
    // The core's "standard speed is cycle_length-1" comment is misleading here.
    .THROTTLE_COUNT_6502        (6'd0),
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
    .key_modifiers    (mtx_mod),
    .key1             (mtx_key1),
    .key2             (mtx_key2),
    .key3             (mtx_key3),
    .key4             (mtx_key4),
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

// B4: free-running standard 720p60 reader, reading the SDRAM frame buffer (written by
// fb_writer) via its own read-only arbiter client.  No genlock — Atari video taps unused here.
fb_reader #(
    .FB_BASE        (25'h0078_0000),
    .WORDS_PER_LINE (88),
    .LINES          (240)
) scaler (
    .clk_core  (clk_core),
    .rst_n     (hdmi_rst_n),
    .fbr_req   (fbr_req_raw),
    .fbr_addr  (fbr_addr),
    .fbr_ack   (fbr_ack),
    .fbr_rdata (fbr_rdata),
    .clk_pixel (clk_pix),
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
// LEDs (active low) — DIAGNOSTIC MAPPING for OSD-stuck investigation.
// leds_n[4:1] → pins 17,18,19,20 → physical LED2,LED3,LED4,LED5 (see CLAUDE.md).
//   leds_n[1] pin17 LED2 = cpu_progress_hb : PicoRV32 executing memory txns
//   leds_n[2] pin18 LED3 = joy_poll_hb     : firmware loop reaching joy_get()
//   leds_n[3] pin19 LED4 = dbg_sd_ready    : ROMs loaded / past init
//   leds_n[4] pin20 LED5 = blink_cnt[22]   : ~6 Hz FPGA-alive free-run heartbeat
// Interpretation (with no Pico, no ATR):
//   LED2 dark              → CPU hung (e.g. SDRAM access never completes) ROOT = arbiter/CDC
//   LED2 blink, LED3 dark  → CPU runs but stuck in a firmware loop before joy_get()
//   LED2 blink, LED3 blink → loop alive; S2/F12 read or compare is the issue
// ─────────────────────────────────────────────────────────────────────────────
wire joy_poll_dbg;
wire cpu_progress_dbg;
wire dbg_stall_undec, dbg_stall_peri, dbg_stall_ram;

// Pulse-stretch SIO line activity to ~78 ms so the eye can see it.
// A serial bit is ~55 us (invisible); stretch any LOW (start/0 bit) to a long blink.
// sio_rx_data_in = our DRIVE's transmit line (sys_clk domain, handler output)
// sio_txd_sys    = Atari's transmit line, synchronized to sys_clk
localparam [21:0] SIO_STRETCH = 22'h3FFFFF; // 2^22-1 @ 27 MHz ≈ 155 ms
reg [21:0] sio_tx_stretch = 22'd0; // our drive -> Atari activity
reg [21:0] sio_rx_stretch = 22'd0; // Atari -> drive activity
always_ff @(posedge sys_clk) begin
    if (!sio_rx_data_in)    sio_tx_stretch <= SIO_STRETCH;
    else if (sio_tx_stretch) sio_tx_stretch <= sio_tx_stretch - 1'b1;

    if (!sio_txd_sys)       sio_rx_stretch <= SIO_STRETCH;
    else if (sio_rx_stretch) sio_rx_stretch <= sio_rx_stretch - 1'b1;
end

// SIO DIAGNOSTIC LED map (pins via leds_n[4:1] = pins17,18,19,20 = LED2,3,4,5):
//   LED2 pin17 (leds_n[1]) = sio_command         : ON when SIO Command line is active (low)
//   LED3 pin18 (leds_n[2]) = |sio_tx_stretch     : BLINKS when OUR DRIVE transmits to the Atari
//   LED4 pin19 (leds_n[3]) = |sio_rx_stretch     : BLINKS when the Atari transmits to the drive
//   LED5 pin20 (leds_n[4]) = ~blink_cnt[22]      : ~6 Hz FPGA-alive heartbeat
// ── STAGE 0 DIAGNOSTIC: SDRAM bandwidth meter (frame-buffer feasibility) ─────────
// Peak-hold thermometer of arbiter SA_BUSY occupancy (= SDRAM access load) at exact
// speed. The frame buffer needs ~46% free (write ~22% + read ~22% + refresh ~2%), so
// the go/no-go is "does peak occupancy stay below ~54%?". Window = 2^20 clk_core
// cycles (~37 ms). Peak-held since power-on (power-cycle to reset). Run a demanding
// program (heavy-ANTIC game) and read the LEDs. See docs/frame_buffer_plan.md Stage 0.
// (PASS 2 — zoomed into the 39-54% band found in pass 1)
//   LED2 (pin17) on if peak > 42%
//   LED3 (pin18) on if peak > 46%
//   LED4 (pin19) on if peak > 50%
//   LED5 (pin20) on if peak > 54%
// Reading: fewer LEDs = more headroom. ≤LED2 (≤46%) ⇒ FB fits with margin; LED4/LED5
// lit (>50-54%) ⇒ FB needs burst reads / faster SDRAM clock first.
reg  [19:0] u0_win  = 20'd0;
reg  [19:0] u0_busy = 20'd0;
reg  [3:0]  u0_peak = 4'd0;
wire        u0_busy_now = (sadap_st == SA_BUSY);
always_ff @(posedge clk_core) begin
    if (!roms_loaded) begin
        // ignore the boot ROM-load burst; only measure steady-state (Atari running)
        u0_win  <= 20'd0;
        u0_busy <= 20'd0;
        u0_peak <= 4'd0;
    end else if (u0_win == 20'hFFFFF) begin
        u0_win  <= 20'd0;
        u0_busy <= 20'd0;
        // zoomed into the 39-54% band found in the first pass (window = 2^20 = 1048576)
        u0_peak[0] <= u0_peak[0] | (u0_busy > 20'd440401);  // >42%
        u0_peak[1] <= u0_peak[1] | (u0_busy > 20'd482345);  // >46%
        u0_peak[2] <= u0_peak[2] | (u0_busy > 20'd524288);  // >50%
        u0_peak[3] <= u0_peak[3] | (u0_busy > 20'd566231);  // >54%
    end else begin
        u0_win <= u0_win + 20'd1;
        if (u0_busy_now) u0_busy <= u0_busy + 20'd1;
    end
end
// ── DIAGNOSTIC LEDs (no monitor needed) ──────────────────────────────────────
//   LED2 (leds_n[1]) = vshb     : ~1 Hz blink iff fb_reader raster emits VSYNC (raster ALIVE)
//   LED3 (leds_n[2]) = roms_loaded : ON once the Atari has booted
//   LED4 (leds_n[3]) = fbr active  : ON if the reader is fetching from SDRAM
//   LED5 (leds_n[4]) = sysblink    : ~0.8 Hz free-run heartbeat (FPGA alive baseline)
reg [24:0] sysblink = 25'd0;
always_ff @(posedge sys_clk) sysblink <= sysblink + 25'd1;
reg        vs_d2 = 1'b0, vshb = 1'b0;
reg [5:0]  vscnt = 6'd0;
always_ff @(posedge clk_pix) begin
    vs_d2 <= hdmi_vs;
    if (hdmi_vs & ~vs_d2) begin
        if (vscnt == 6'd29) begin vscnt <= 6'd0; vshb <= ~vshb; end
        else                      vscnt <= vscnt + 6'd1;
    end
end
reg [23:0] fbrcnt = 24'd0;
always_ff @(posedge clk_core) begin
    if (fbr_req)          fbrcnt <= 24'hFFFFFF;
    else if (fbrcnt != 0) fbrcnt <= fbrcnt - 24'd1;
end
assign leds_n = ~{ sysblink[24], (fbrcnt != 0), roms_loaded, vshb };


endmodule
