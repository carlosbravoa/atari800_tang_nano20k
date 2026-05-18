// Atari 800 — Tang Nano 20K top-level
// Stage 4: USB HID keyboard via nand2mario/usb_hid_host
// Clocks: 27 MHz core/pixel; 135 MHz HDMI serialiser; 12 MHz USB HID host.

module tang_top (
    input  wire        sys_clk,       // 27 MHz onboard oscillator

    // Buttons (active low): S1 = reset, S2 = spare
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
    inout  wire        usb_dm,        // D- — pin 42; 15 kΩ to GND
    inout  wire        usb_dp,        // D+ — pin 41; 15 kΩ to GND

    // Joystick ports (Atari DB9 pinout, active low)
    input  wire [4:0]  joy1_n,
    input  wire [4:0]  joy2_n,

    // Status LEDs (active low on Tang Nano 20K)
    output wire [5:0]  leds_n
);

// ── Clocks & reset ─────────────────────────────────────────────────────────
wire clk_sys = sys_clk;    // 27 MHz — direct
wire clk_5x;               // 135 MHz — HDMI serialiser
wire clk_usb;              // 12 MHz  — USB HID host
wire pll_locked, pll_usb_locked;

rpll_135m pll (
    .clk_in  (sys_clk),
    .clk_135m(clk_5x),
    .locked  (pll_locked)
);

rpll_12m pll_usb (
    .clk_in  (sys_clk),
    .clk_12m (clk_usb),
    .locked  (pll_usb_locked)
);

// Physical reset: button OR either PLL not locked
wire hw_reset_n = btn_n[0] & pll_locked & pll_usb_locked;

// Core reset: hardware reset AND ROMs loaded
wire roms_loaded;
wire core_reset_n = hw_reset_n & roms_loaded;

// ── Keyboard ───────────────────────────────────────────────────────────────
wire [5:0]  keyboard_scan;
wire [1:0]  keyboard_response;
wire        consol_start;
wire        consol_select;
wire        consol_option;

// ── Video ──────────────────────────────────────────────────────────────────
wire        video_vs, video_hs;
wire [7:0]  video_r, video_g, video_b;
wire        video_blank;

// ── Audio ──────────────────────────────────────────────────────────────────
wire [15:0] audio_l, audio_r;

// ── SIO — stubbed until Stage 5 ───────────────────────────────────────────
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

// ── ROM loader SDRAM signals ───────────────────────────────────────────────
wire        loader_req;
wire        loader_complete;
wire        loader_write_en;
wire [24:0] loader_addr;
wire [31:0] loader_wdata;
wire        sdram_ready;

// ── SDRAM mux: ROM loader has priority until roms_loaded ──────────────────
wire        sdram_req    = roms_loaded ? core_sdram_req          : loader_req;
wire        sdram_re     = roms_loaded ? core_sdram_read_en      : 1'b0;
wire        sdram_we     = roms_loaded ? core_sdram_write_en     : loader_write_en;
wire [24:0] sdram_addr   = roms_loaded ? core_sdram_addr         : loader_addr;
wire [31:0] sdram_wdata  = roms_loaded ? core_sdram_data_from_core : loader_wdata;
wire        sdram_we32   = roms_loaded ? core_sdram_32bit_we     : 1'b1;
wire        sdram_we16   = roms_loaded ? core_sdram_16bit_we     : 1'b0;
wire        sdram_we8    = roms_loaded ? core_sdram_8bit_we      : 1'b0;
wire        sdram_refresh= roms_loaded ? core_sdram_refresh      : 1'b0;

wire        sdram_complete;
assign core_sdram_req_complete = roms_loaded ? sdram_complete : 1'b0;
assign loader_complete         = roms_loaded ? 1'b0          : sdram_complete;

wire [31:0] sdram_rdata_out;
assign core_sdram_data_to_core = sdram_rdata_out;

// ── SDRC_HS: Gowin embedded SDRAM controller ──────────────────────────────
// The Gowin SDRC_HS IP owns O_sdram_*/IO_sdram_dq.  These become internal
// signals here (NOT top-level ports), keeping tang_top within the 53-IO limit.
// The P&R tool routes them to the GW2AR-18 on-chip SDRAM die.

// Command encoding: I_sdrc_cmd = {RAS_N, CAS_N, WE_N}
localparam SDRC_WRITE = 3'b100;  // READ: RAS=1 CAS=0 WE=0
localparam SDRC_READ  = 3'b101;  // READ: RAS=1 CAS=0 WE=1

wire        sdrc_init_done;
wire        sdrc_cmd_ack;
wire [31:0] sdrc_rd_data;

reg         sdrc_cmd_en;
reg  [2:0]  sdrc_cmd_r;
reg  [22:0] sdrc_addr_r;   // I_sdrc_addr: {bank[1:0], 2'b0, row[10:0], col[7:0]}
reg  [3:0]  sdrc_dqm_r;
reg  [31:0] sdrc_wdata_r;

// DQM calculation for partial writes
function automatic [3:0] calc_dqm;
    input [24:0] a;
    input        w32, w16, w8;
    if (w32)        calc_dqm = 4'b0000;
    else if (w16)   calc_dqm = a[1] ? 4'b0011 : 4'b1100;
    else if (w8)
        case (a[1:0])
            2'b00: calc_dqm = 4'b1110;
            2'b01: calc_dqm = 4'b1101;
            2'b10: calc_dqm = 4'b1011;
            default: calc_dqm = 4'b0111;
        endcase
    else            calc_dqm = 4'b1111;
endfunction

// I_sdrc_addr layout: {bank[1:0], row_msb_pad[1:0], row[10:0], col[7:0]}
// SDRAM_ADDR_ROW_WIDTH=13 → row field is 13 bits; GW2AR-18 uses only [10:0]
wire [22:0] sdrc_addr_next =
    {sdram_addr[22:21], 2'b00, sdram_addr[20:10], sdram_addr[9:2]};

// Adapter state machine: Atari req/complete handshake → SDRC_HS cmd_en/cmd_ack
typedef enum logic [1:0] { SA_IDLE, SA_BUSY } sadap_t;
sadap_t sadap_st;

reg        sdram_complete_r;
reg [31:0] sdram_rdata_r;
reg        sdram_ready_r;

assign sdram_complete  = sdram_complete_r;
assign sdram_rdata_out = sdram_rdata_r;
assign sdram_ready     = sdram_ready_r;

always_ff @(posedge clk_sys or negedge hw_reset_n) begin
    if (!hw_reset_n) begin
        sdrc_cmd_en      <= 1'b0;
        sdrc_cmd_r       <= 3'b111;  // NOP
        sdrc_addr_r      <= 23'd0;
        sdrc_dqm_r       <= 4'b1111;
        sdrc_wdata_r     <= 32'd0;
        sdram_complete_r <= 1'b0;
        sdram_rdata_r    <= 32'd0;
        sdram_ready_r    <= 1'b0;
        sadap_st         <= SA_IDLE;
    end else begin
        sdram_ready_r    <= sdrc_init_done;
        sdram_complete_r <= 1'b0;
        sdrc_cmd_en      <= 1'b0;   // default: no command this cycle

        case (sadap_st)
            SA_IDLE: begin
                if (sdrc_init_done && sdram_req) begin
                    sdrc_cmd_en  <= 1'b1;
                    sdrc_cmd_r   <= sdram_we ? SDRC_WRITE : SDRC_READ;
                    sdrc_addr_r  <= sdrc_addr_next;
                    sdrc_dqm_r   <= calc_dqm(sdram_addr, sdram_we32, sdram_we16, sdram_we8);
                    sdrc_wdata_r <= sdram_wdata;
                    sadap_st     <= SA_BUSY;
                end
            end
            SA_BUSY: begin
                if (sdrc_cmd_ack) begin
                    sdram_rdata_r    <= sdrc_rd_data;
                    sdram_complete_r <= 1'b1;
                    sadap_st         <= SA_IDLE;
                end
            end
            default: sadap_st <= SA_IDLE;
        endcase
    end
end

// Internal SDRAM bus wires (GW2AR-18 embedded, not top-level ports)
wire        emb_sdram_clk;
wire        emb_sdram_cke;
wire        emb_sdram_cs_n;
wire        emb_sdram_cas_n;
wire        emb_sdram_ras_n;
wire        emb_sdram_wen_n;
wire [3:0]  emb_sdram_dqm;
wire [12:0] emb_sdram_addr;
wire [1:0]  emb_sdram_ba;
wire [31:0] emb_sdram_dq;

Gowin_SDRAM_HS sdram_ip (
    // Physical embedded SDRAM connections (routed internally by P&R)
    .O_sdram_clk  (emb_sdram_clk),
    .O_sdram_cke  (emb_sdram_cke),
    .O_sdram_cs_n (emb_sdram_cs_n),
    .O_sdram_cas_n(emb_sdram_cas_n),
    .O_sdram_ras_n(emb_sdram_ras_n),
    .O_sdram_wen_n(emb_sdram_wen_n),
    .O_sdram_dqm  (emb_sdram_dqm),
    .O_sdram_addr (emb_sdram_addr),
    .O_sdram_ba   (emb_sdram_ba),
    .IO_sdram_dq  (emb_sdram_dq),
    // User interface
    .I_sdrc_rst_n        (hw_reset_n),
    .I_sdrc_clk          (clk_sys),
    .I_sdram_clk         (clk_sys),
    .I_sdrc_cmd_en       (sdrc_cmd_en),
    .I_sdrc_cmd          (sdrc_cmd_r),
    .I_sdrc_precharge_ctrl(1'b1),   // always auto-precharge after each access
    .I_sdram_power_down  (1'b0),
    .I_sdram_selfrefresh (1'b0),
    .I_sdrc_addr         (sdrc_addr_r),
    .I_sdrc_dqm          (sdrc_dqm_r),
    .I_sdrc_data         (sdrc_wdata_r),
    .I_sdrc_data_len     (8'd0),    // single-word burst
    .O_sdrc_data         (sdrc_rd_data),
    .O_sdrc_init_done    (sdrc_init_done),
    .O_sdrc_cmd_ack      (sdrc_cmd_ack)
);

// ─────────────────────────────────────────────────────────────────────────────
// SD card ROM loader
// ─────────────────────────────────────────────────────────────────────────────
sd_rom_loader loader (
    .clk         (clk_sys),
    .reset_n     (hw_reset_n),
    .sdram_ready (sdram_ready),
    .done        (roms_loaded),
    .req         (loader_req),
    .complete    (loader_complete),
    .write_en    (loader_write_en),
    .addr        (loader_addr),
    .wdata       (loader_wdata),
    .spi_clk     (sd_clk),
    .spi_mosi    (sd_mosi),
    .spi_miso    (sd_miso),
    .spi_cs_n    (sd_cs)
);

// ─────────────────────────────────────────────────────────────────────────────
// Atari 800 core
// ─────────────────────────────────────────────────────────────────────────────
atari800core_simple_sdram #(
    .cycle_length               (16),
    .video_bits                 (8),
    .palette                    (1),    // Altirra palette
    .internal_rom               (0),    // ROMs in SDRAM (loaded by rom_loader)
    .internal_ram               (0),
    .low_memory                 (0),
    .covox                      (1)
) core (
    .CLK                        (clk_sys),
    .RESET_N                    (core_reset_n),

    // Video
    .VIDEO_VS                   (video_vs),
    .VIDEO_HS                   (video_hs),
    .VIDEO_B                    (video_b),
    .VIDEO_G                    (video_g),
    .VIDEO_R                    (video_r),
    .VIDEO_BLANK                (video_blank),
    .VIDEO_PIXCE                (),
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
    .AUDIO_L                    (audio_l),
    .AUDIO_R                    (audio_r),

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
    .SIO_RXD                    (1'b1),
    .SIO_TXD                    (sio_txd),
    .SIO_CLOCK                  (),
    .SIO_CLOCK_IN               (1'b1),
    .SIO_PROC                   (1'b1),
    .SIO_IRQ                    (1'b1),
    .SIO_MOTOR                  (sio_motor),
    .TAPE_AUDIO                 (8'h00),
    .ENABLE_179_EARLY           (),
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
    .PAL                        (1'b1),     // PAL
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
    .HALT                       (1'b0),
    .THROTTLE_COUNT_6502        (6'd15),
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
wire [7:0] usb_key_mod, usb_key1, usb_key2, usb_key3, usb_key4;

usb_hid_host usb_hid (
    .usbclk       (clk_usb),
    .usbrst_n     (hw_reset_n),
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
    .clk              (clk_sys),
    .reset_n          (core_reset_n),
    .key_modifiers    (usb_key_mod),
    .key1             (usb_key1),
    .key2             (usb_key2),
    .key3             (usb_key3),
    .key4             (usb_key4),
    .keyboard_scan    (keyboard_scan),
    .keyboard_response(keyboard_response),
    .consol_start     (consol_start),
    .consol_select    (consol_select),
    .consol_option    (consol_option)
);

// ─────────────────────────────────────────────────────────────────────────────
// HDMI output
// ─────────────────────────────────────────────────────────────────────────────
hdmi_out hdmi (
    .clk_pix    (clk_sys),
    .clk_5x     (clk_5x),
    .rst_n      (hw_reset_n),
    .r          (video_r),
    .g          (video_g),
    .b          (video_b),
    .hs         (video_hs),
    .vs         (video_vs),
    .de         (~video_blank),
    .tmds_p     (tmds_p),
    .tmds_n     (tmds_n),
    .tmds_clk_p (tmds_clk_p),
    .tmds_clk_n (tmds_clk_n)
);

// ─────────────────────────────────────────────────────────────────────────────
// LEDs (active low): power, PLL-lock, roms-loaded, VS, HS, SDRAM-ready
// ─────────────────────────────────────────────────────────────────────────────
assign leds_n = ~{1'b1, pll_locked, roms_loaded, video_vs, video_hs, sdram_ready};

endmodule
