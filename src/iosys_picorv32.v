// IOSys_picorv32 - PicoRV32-based IO subsystem
//
// IOSys_picorv32 provides the following functionality,
// - Menu system
// - ROM file loading
// - Configuration options
//
// This is similar to the IO controller of MIST, or HPS of MiSTer.
//
// The softcore runs RV32I at 21.6Mhz and uses SDRAM as main memory. Firmware is 
// loaded from SPI flash on the board. Firmware source is in /snestang/firmware.
// 
// Author: nand2mario, 1/2024

`define MCU_PICORV32

`ifndef PICORV32_REGS
`define PICORV32_REGS picosoc_regs
`endif

`ifndef PICOSOC_MEM
`define PICOSOC_MEM picosoc_mem
`endif

// this macro can be used to check if the verilog files in your
// design are read in the correct order.
`define PICOSOC_V

module iosys_picorv32 #(
    parameter FREQ=21_477_000,
    parameter [14:0] COLOR_LOGO=15'b00000_10101_00000,
    parameter [15:0] CORE_ID=1      // 1: nestang, 2: snestang
)
(
    input clk,                      // SNES mclk
    input hclk,                     // hdmi clock
    // input clkref,                   // 1/2 of clk 
    input resetn,

    // OSD display interface
    output overlay,
    input [7:0] overlay_x,         // 720p
    input [7:0] overlay_y,
    output [15:0] overlay_color,    // BGR5, [15] is opacity
    input [11:0] joy1,              // joystick 1: (R L X A RT LT DN UP START SELECT Y B)
    input [11:0] joy2,              // joystick 2
    input [31:0] video_diag,        // [31:16]=lines/frame, [15:0]=frame counter (for frame-rate diag)
    input [159:0] sio_cap_buf,      // SIO capture: words0-3 = 128 samples, word4 = meta (trig count)

    // ROM loading interface
    output reg rom_loading,         // 0-to-1 loading starts, 1-to-0 loading is finished
    output [7:0] rom_do,            // first 64 bytes are snes header + 32 bytes after snes header 
    output reg rom_do_valid,        // strobe for rom_do
    
    // 32-bit wide memory interface for risc-v softcore
    // 0x_xxxx~6x_xxxx is RV RAM, 7x_xxxx is BSRAM
    output rv_valid,                // 1: active memory access
    input rv_ready,                 // pulse when access is done
    output [22:0] rv_addr,          // 8MB memory space
    output [31:0] rv_wdata,         // 32-bit write data
    output [3:0] rv_wstrb,          // 4 byte write strobe
    input [31:0] rv_rdata,          // 32-bit read data

    input ram_busy,                 // iosys starts after SDRAM initialization

    // SPI flash
    output flash_spi_cs_n,          // chip select
    input  flash_spi_miso,          // master in slave out
    output flash_spi_mosi,          // mster out slave in
    output flash_spi_clk,           // spi clock
    output flash_spi_wp_n,          // write protect
    output flash_spi_hold_n,        // hold operations

    // UART
    input uart_rx,
    output uart_tx,

    // SD card
    output sd_clk,
    inout  sd_cmd,                  // MOSI
    input  sd_dat0,                 // MISO
    output sd_dat1,                 // 1
    output sd_dat2,                 // 1
    output sd_dat3,                 // 0 for SPI mode

    // SIO register interface
    output wire        sio_reg_sel,
    output wire [4:0]  sio_reg_addr,
    output wire [7:0]  sio_reg_wdata,
    output wire        sio_reg_wr,
    input  wire [15:0] sio_reg_rdata,
    output wire        sio_reg_en,

    // Virtual Keyboard outputs
    output wire [7:0]  virt_kbd_mod_out,
    output wire [7:0]  virt_kbd_key1_out,
    output wire [7:0]  virt_kbd_key2_out,
    output wire [7:0]  virt_kbd_key3_out,
    output wire [7:0]  virt_kbd_key4_out,
    output wire        usb_host_enable_out,

    // DIAGNOSTIC: heartbeat that toggles every time firmware reads reg_joystick
    // (i.e. every joy_get() call in the background loop). If this toggles, the
    // firmware loop is reaching the S2/F12 check.
    output reg         joy_poll_dbg,

    // DIAGNOSTIC: toggles on every completed CPU memory transaction. If this is
    // blinking, the PicoRV32 is executing (so a dark joy_poll_dbg means it is
    // stuck in a firmware loop). If this is dark, the CPU is hung (e.g. SDRAM
    // access never completing).
    output reg         cpu_progress_dbg,

    // DIAGNOSTIC: classification of a persistent CPU bus stall (sticky).
    output wire        dbg_stall_undec_out, // stuck on undecoded address
    output wire        dbg_stall_peri_out,  // stuck on a peripheral wait handshake
    output wire        dbg_stall_ram_out    // stuck on a RAM access
);

/* verilator lint_off PINMISSING */
/* verilator lint_off WIDTHTRUNC */

localparam FIRMWARE_SIZE = 256*1024;

// Firmware now lives in BSRAM (loaded at FPGA config time via $readmemh), so the
// old "copy 256 KB from SPI flash into SDRAM at boot" state machine is GONE. The
// spiflash module is retained only for its optional MMIO register interface
// (reg_spiflash_*); the auto-load (flash_start/flash_loading) is tied off.
// flash_loaded reports 1 / flash_loading 0 so any status read looks "done".
wire [7:0] flash_dout;          // unused (no auto-load)
wire flash_out_strb;            // unused
wire flash_start = 1'b0;        // never trigger a flash read
assign flash_spi_hold_n = 1;
assign flash_spi_wp_n = 1;      // disable write protection
wire [31:0] spiflash_reg_do;
wire spiflash_reg_wait;
wire flash_loaded  = 1'b1;      // firmware already in BSRAM
wire flash_loading = 1'b0;

// picorv32 softcore
wire mem_valid /* synthesis syn_keep=1 */;
wire mem_ready;
wire [31:0] mem_addr /* synthesis syn_keep=1 */, mem_wdata /* synthesis syn_keep=1 */;
wire [3:0] mem_wstrb /* synthesis syn_keep=1 */;
wire [31:0] mem_rdata /* synthesis syn_keep=1 */;

reg ram_ready /* synthesis syn_keep=1 */;
reg [31:0] ram_rdata;

// Low 8 MB region (addr[31:23]==0) is split:
//   addr < 64 KB (0x0000_0000..0x0000_FFFF) → on-chip BSRAM = firmware code/data/stack
//   addr >= 64 KB                            → SDRAM (Atari memory: ROM load 0x700000/
//                                              0x704000, COLDST 0x200244, etc.)
// Firmware EXECUTES from BSRAM so its instruction fetches never touch SDRAM —
// this is the whole point (ends CPU↔ANTIC SDRAM contention).
wire        lowregion_sel = mem_valid && mem_addr[31:23] == 0;
wire        bram_sel = lowregion_sel && (mem_addr[22:16] == 7'd0);  // < 64 KB
wire        ram_sel  = lowregion_sel && (mem_addr[22:16] != 7'd0);  // SDRAM (Atari mem)

// ── Firmware BSRAM boot RAM (64 KB, byte-laned, $readmemh-initialised) ────────
wire [31:0] bram_rdata;
wire        bram_ready;
fw_bram fw_bram_inst (
    .clk   (clk),
    .sel   (bram_sel),
    .waddr (mem_addr[15:2]),     // 14-bit word address within 64 KB
    .wdata (mem_wdata),
    .wstrb (bram_sel ? mem_wstrb : 4'b0000),
    .rdata (bram_rdata),
    .ready (bram_ready)
);

wire        textdisp_reg_char_sel /* synthesis syn_keep=1 */= mem_valid && (mem_addr == 32'h 0200_0000);

wire        simpleuart_reg_div_sel = mem_valid && (mem_addr == 32'h 0200_0010);
wire [31:0] simpleuart_reg_div_do;

wire        simpleuart_reg_dat_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h 0200_0014);
wire [31:0] simpleuart_reg_dat_do;
wire        simpleuart_reg_dat_wait;

wire        simplespimaster_reg_byte_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h0200_0020);
wire        simplespimaster_reg_word_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h0200_0024);
wire        simplespimaster_reg_cs_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h0200_0028);
wire        simplespimaster_reg_clkdiv_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h0200_002c);
wire [31:0] simplespimaster_reg_do;
wire        simplespimaster_reg_wait /* synthesis syn_keep=1 */;

wire        romload_reg_ctrl_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h 0200_0030);       // write 1 to start loading, 0 to finish loading
wire        romload_reg_data_sel /* synthesis syn_keep=1 */ = mem_valid && (mem_addr == 32'h 0200_0034);       // write once to load 4 bytes

wire        joystick_reg_sel = mem_valid && (mem_addr == 32'h 0200_0040);

wire        time_reg_sel = mem_valid && (mem_addr == 32'h0200_0050);        // milli-seconds since start-up (overflows in 49 days)
wire        cycle_reg_sel = mem_valid && (mem_addr == 32'h0200_0054);       // cycles counter (overflows every 200 seconds)

wire        id_reg_sel = mem_valid && (mem_addr == 32'h0200_0060);
wire        video_diag_sel = mem_valid && (mem_addr == 32'h0200_0064);   // [31:16]=lines/frame [15:0]=frame counter
wire        sio_cap_idx_sel  = mem_valid && (mem_addr == 32'h0200_0068);  // write: select capture word 0..4
wire        sio_cap_data_sel = mem_valid && (mem_addr == 32'h0200_006c);  // read: selected capture word

reg [2:0]   sio_cap_rdidx = 3'd0;   // 0-3 = sample words, 4 = meta
always @(posedge clk) begin
    if (sio_cap_idx_sel && |mem_wstrb) sio_cap_rdidx <= mem_wdata[2:0];
end
wire [31:0] sio_cap_word = sio_cap_buf[sio_cap_rdidx*32 +: 32];

wire        spiflash_reg_byte_sel = mem_valid && (mem_addr == 32'h0200_0070);
wire        spiflash_reg_word_sel = mem_valid && (mem_addr == 32'h0200_0074);
wire        spiflash_reg_ctrl_sel = mem_valid && (mem_addr == 32'h0200_0078);

wire        virt_kbd_reg0_sel = mem_valid && (mem_addr == 32'h0200_00a0);
wire        virt_kbd_reg1_sel = mem_valid && (mem_addr == 32'h0200_00a4);

assign sio_reg_sel = mem_valid && (mem_addr[31:5] == 27'h0100_004);
assign sio_reg_addr = mem_addr[6:2];
assign sio_reg_wdata = mem_wdata[7:0];
assign sio_reg_wr = (|mem_wstrb) && sio_reg_en;
assign sio_reg_en = sio_reg_sel && !sio_ready;

reg sio_ready;
always @(posedge clk) begin
    if (~resetn)
        sio_ready <= 1'b0;
    else
        sio_ready <= sio_reg_sel && !sio_ready;
end

assign mem_ready = bram_ready || ram_ready || textdisp_reg_char_sel || simpleuart_reg_div_sel ||
            romload_reg_ctrl_sel || romload_reg_data_sel || joystick_reg_sel || time_reg_sel || cycle_reg_sel || id_reg_sel || video_diag_sel ||
            (simpleuart_reg_dat_sel && !simpleuart_reg_dat_wait) ||
            ((simplespimaster_reg_byte_sel || simplespimaster_reg_word_sel) && !simplespimaster_reg_wait) ||
            simplespimaster_reg_cs_sel || simplespimaster_reg_clkdiv_sel ||
            (spiflash_reg_byte_sel || spiflash_reg_word_sel) && !spiflash_reg_wait ||
            spiflash_reg_ctrl_sel || sio_ready || virt_kbd_reg0_sel || virt_kbd_reg1_sel ||
            sio_cap_idx_sel || sio_cap_data_sel;

// ── BUS-STALL DETECTOR (diagnostic) ──────────────────────────────────────────
// The CPU hangs if mem_valid stays high but mem_ready never asserts. Classify a
// persistent stall three ways so we know WHICH kind of access wedged the CPU:
//   dbg_stall_undec : mem_valid high, NO select matched (undecoded address)
//   dbg_stall_peri  : a peripheral select matched but mem_ready still low
//                     (a *_wait / *_ready handshake that never completes)
//   dbg_stall_ram   : stalled on a RAM access (ram_sel high, ram_ready low)
// Sticky once latched. ~0.5 ms threshold (huge vs any legit access).
wire any_sel_dbg = bram_sel || ram_sel || textdisp_reg_char_sel || simpleuart_reg_div_sel ||
            simpleuart_reg_dat_sel || simplespimaster_reg_byte_sel || simplespimaster_reg_word_sel ||
            simplespimaster_reg_cs_sel || simplespimaster_reg_clkdiv_sel ||
            romload_reg_ctrl_sel || romload_reg_data_sel || joystick_reg_sel ||
            time_reg_sel || cycle_reg_sel || id_reg_sel ||
            spiflash_reg_byte_sel || spiflash_reg_word_sel || spiflash_reg_ctrl_sel ||
            sio_reg_sel || virt_kbd_reg0_sel || virt_kbd_reg1_sel;
reg        dbg_stall_undec = 1'b0;
reg        dbg_stall_peri  = 1'b0;
reg        dbg_stall_ram   = 1'b0;
reg [15:0] dbg_stall_cnt   = 16'd0;
always @(posedge clk) begin
    if (~resetn) begin
        dbg_stall_undec <= 1'b0; dbg_stall_peri <= 1'b0; dbg_stall_ram <= 1'b0;
        dbg_stall_cnt   <= 16'd0;
    end else if (mem_valid && !mem_ready) begin
        if (dbg_stall_cnt == 16'hFFFF) begin
            if      (!any_sel_dbg) dbg_stall_undec <= 1'b1;   // no decoder matched
            else if (ram_sel)      dbg_stall_ram   <= 1'b1;   // RAM access not completing
            else                   dbg_stall_peri  <= 1'b1;   // peripheral wait stuck
        end else begin
            dbg_stall_cnt <= dbg_stall_cnt + 16'd1;
        end
    end else begin
        dbg_stall_cnt <= 16'd0;   // access completed; reset timer (flags stay sticky)
    end
end

assign mem_rdata = bram_ready ? bram_rdata :
        ram_ready ? ram_rdata :
        joystick_reg_sel ? {4'b0, joy2, 4'b0, joy1} :
        simpleuart_reg_div_sel ? simpleuart_reg_div_do :
        simpleuart_reg_dat_sel ? simpleuart_reg_dat_do : 
        time_reg_sel ? time_reg :
        cycle_reg_sel ? cycle_reg :
        id_reg_sel ? {16'b0, CORE_ID} :
        video_diag_sel ? video_diag :
        sio_cap_data_sel ? sio_cap_word :
        simplespimaster_reg_cs_sel ? {31'b0, sd_cs_reg} :
        simplespimaster_reg_clkdiv_sel ? {24'b0, sd_clkdiv_reg} :
        (simplespimaster_reg_byte_sel | simplespimaster_reg_word_sel) ? simplespimaster_reg_do : 
        spiflash_reg_byte_sel || spiflash_reg_word_sel ? spiflash_reg_do : 
        spiflash_reg_ctrl_sel ? {30'h0000_0000, flash_loaded, flash_loading} :
        sio_reg_sel ? {16'h0000, sio_reg_rdata} :
        virt_kbd_reg0_sel ? {virt_kbd_key3, virt_kbd_key2, virt_kbd_key1, virt_kbd_mod} :
        virt_kbd_reg1_sel ? {23'b0, usb_host_enable, virt_kbd_key4} :
        32'h 0000_0000;

picorv32 #(
    // .ENABLE_MUL(1),
    // .ENABLE_DIV(1),
    // .COMPRESSED_ISA(1)
    .CATCH_ILLINSN(0),
    .ENABLE_COUNTERS (0),
    .ENABLE_COUNTERS64 (0),
    .CATCH_MISALIGN (0),
    .TWO_STAGE_SHIFT(0)
) rv32 (
    // Boot directly from BSRAM at reset — firmware is loaded into BSRAM at FPGA
    // config time ($readmemh), so no flash_loaded gate is needed. Removing that
    // gate is also what prevents Gowin from constant-folding the BSRAM read path
    // dead and pruning it (the prior feature/picorv32-bram-firmware failure).
    .clk(clk), .resetn(resetn),
    .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_addr(mem_addr),
    .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata)
);

// text display @ 0x0200_0000
textdisp #(.COLOR_LOGO(COLOR_LOGO)) disp (
    .clk(clk), .hclk(hclk), .resetn(resetn),
    .x(overlay_x), .y(overlay_y), .color(overlay_color),
    .reg_char_we(textdisp_reg_char_sel ? mem_wstrb : 4'b0),
    .reg_char_di(mem_wdata) 
);

// toggle overlay display on/off
reg overlay_buf = 1;
assign overlay = overlay_buf;
always @(posedge clk) begin
    if (~resetn) begin
        overlay_buf <= 1;
    end else begin
        if (textdisp_reg_char_sel && mem_wstrb[0]) begin
            case (mem_wdata[25:24])
            2'd1: overlay_buf <= 1;
            2'd2: overlay_buf <= 0;
            default: ;
            endcase
        end 
    end
end

// uart @ 0x0200_0010
simpleuart simpleuart (
    .clk         (clk         ),
    .resetn      (resetn       ),

    .ser_tx      (uart_tx      ),
    .ser_rx      (uart_rx      ),

    .reg_div_we  (simpleuart_reg_div_sel ? mem_wstrb : 4'b0),
    .reg_div_di  (mem_wdata),
    .reg_div_do  (simpleuart_reg_div_do),

    .reg_dat_we  (simpleuart_reg_dat_sel ? mem_wstrb[0] : 1'b0),
    .reg_dat_re  (simpleuart_reg_dat_sel && !mem_wstrb),
    .reg_dat_di  (mem_wdata),
    .reg_dat_do  (simpleuart_reg_dat_do),
    .reg_dat_wait(simpleuart_reg_dat_wait)
);

// spi sd card @ 0x0200_0020
reg sd_cs_reg = 1'b0;
reg [7:0] sd_clkdiv_reg = 8'd8; // Default to 8 (1.68 MHz)

always @(posedge clk) begin
    if (~resetn) begin
        sd_cs_reg <= 1'b0;
        sd_clkdiv_reg <= 8'd8;
    end else begin
        if (simplespimaster_reg_cs_sel && mem_wstrb[0])
            sd_cs_reg <= mem_wdata[0];
        if (simplespimaster_reg_clkdiv_sel && mem_wstrb[0])
            sd_clkdiv_reg <= mem_wdata[7:0];
    end
end

assign sd_dat1 = 1;
assign sd_dat2 = 1;
assign sd_dat3 = sd_cs_reg;
simplespimaster simplespi (
    .clk(clk), .resetn(resetn),
    .sck(sd_clk), .mosi(sd_cmd), .miso(sd_dat0),
    .clkdiv(sd_clkdiv_reg),
    .reg_byte_we(simplespimaster_reg_byte_sel ? mem_wstrb[0] : 1'b0),
    .reg_word_we(simplespimaster_reg_word_sel ? mem_wstrb[0] : 1'b0),
    .reg_di(mem_wdata),
    .reg_do(simplespimaster_reg_do),
    .reg_wait(simplespimaster_reg_wait)
);

// ROM loading I/O. 2 cycles for a byte and 2 cycles idles.
reg [3:0] rom_cnt;
reg [31:0] rom_do_buf;
assign rom_do = rom_do_buf[7:0];
always @(posedge clk) begin
    if (rom_cnt != 0)
        rom_cnt <= rom_cnt - 2'd1;
    // data register
    if (romload_reg_data_sel && mem_wstrb) begin
        rom_do_buf <= mem_wdata;
        rom_cnt <= 4'd15;
        rom_do_valid <= 1;
    end
    if (rom_cnt[1:0] == 2'd3)
        rom_do_valid <= 0;
    if (rom_cnt[1:0] == 2'd0 && rom_cnt[3:2] != 0) begin
        rom_do_buf[23:0] <= rom_do_buf[31:8];
        rom_do_valid <= 1;
    end
end
always @(posedge clk) begin
    if (romload_reg_ctrl_sel && mem_wstrb) begin
        // control register
        if (mem_wdata[7:0] == 8'd1)
            rom_loading <= 1;
        if (mem_wdata[7:0] == 8'd0)
            rom_loading <= 0;
    end    
end

// SPI flash @ 0x02000_0070
// Load 256KB of ROM from flash address 0x500000 into SDRAM at address 0x0
spiflash #(.ADDR(24'h500000), .LEN(FIRMWARE_SIZE)) flash (
    .clk(clk), .resetn(resetn),
    .ncs(flash_spi_cs_n), .miso(flash_spi_miso), .mosi(flash_spi_mosi),
    .sck(flash_spi_clk), 

    .start(flash_start), .dout(flash_dout), .dout_strb(flash_out_strb), .busy(),

    .reg_byte_we(spiflash_reg_byte_sel ? mem_wstrb[0] : 1'b0),
    .reg_word_we(spiflash_reg_word_sel ? mem_wstrb[0] : 1'b0),
    .reg_ctrl_we(spiflash_reg_ctrl_sel ? mem_wstrb[0] : 1'b0),
    .reg_di(mem_wdata), .reg_do(spiflash_reg_do), .reg_wait(spiflash_reg_wait)
);

// RV memory access — SDRAM now serves ONLY the high part of the low region
// (ram_sel = addr>=64KB: Atari memory / ROM load). Firmware code/data is in
// BSRAM. The flash-load-into-SDRAM machinery is gone (firmware is in BSRAM at
// config time), so these are plain pass-throughs.
assign rv_addr  = mem_addr;
assign rv_wdata = mem_wdata;
assign rv_wstrb = mem_wstrb;
assign ram_rdata = rv_rdata;
assign rv_valid = mem_valid & ram_sel;
assign ram_ready = rv_ready;

// Time counter register
reg [31:0] time_reg, cycle_reg;
reg [$clog2(FREQ/1000)-1:0] time_cnt;
always @(posedge clk) begin
    if (~resetn) begin
        time_reg <= 0;
        time_cnt <= 0;
    end else begin
        cycle_reg <= cycle_reg + 1;
        time_cnt <= time_cnt + 1;
        if (time_cnt == FREQ/1000-1) begin
            time_cnt <= 0;
            time_reg <= time_reg + 1;
        end
    end
end

// Virtual Keyboard register storage and port wiring
reg [7:0] virt_kbd_mod  = 8'h00;
reg [7:0] virt_kbd_key1 = 8'h00;
reg [7:0] virt_kbd_key2 = 8'h00;
reg [7:0] virt_kbd_key3 = 8'h00;
reg [7:0] virt_kbd_key4 = 8'h00;
reg       usb_host_enable = 1'b1;

always @(posedge clk) begin
    if (~resetn) begin
        virt_kbd_mod  <= 8'h00;
        virt_kbd_key1 <= 8'h00;
        virt_kbd_key2 <= 8'h00;
        virt_kbd_key3 <= 8'h00;
        virt_kbd_key4 <= 8'h00;
        usb_host_enable <= 1'b1;
    end else begin
        if (virt_kbd_reg0_sel && |mem_wstrb) begin
            if (mem_wstrb[0]) virt_kbd_mod  <= mem_wdata[7:0];
            if (mem_wstrb[1]) virt_kbd_key1 <= mem_wdata[15:8];
            if (mem_wstrb[2]) virt_kbd_key2 <= mem_wdata[23:16];
            if (mem_wstrb[3]) virt_kbd_key3 <= mem_wdata[31:24];
        end
        if (virt_kbd_reg1_sel && |mem_wstrb) begin
            if (mem_wstrb[0]) virt_kbd_key4 <= mem_wdata[7:0];
            if (mem_wstrb[1]) usb_host_enable <= mem_wdata[8];
        end
    end
end

// DIAGNOSTIC: toggle joy_poll_dbg on each reg_joystick read so a slow human-
// visible heartbeat can be derived in tang_top from the firmware poll rate.
always @(posedge clk) begin
    if (~resetn) joy_poll_dbg <= 1'b0;
    else if (joystick_reg_sel) joy_poll_dbg <= ~joy_poll_dbg;
end

// DIAGNOSTIC: CPU memory-transaction progress
always @(posedge clk) begin
    if (~resetn) cpu_progress_dbg <= 1'b0;
    else if (mem_valid && mem_ready) cpu_progress_dbg <= ~cpu_progress_dbg;
end

assign virt_kbd_mod_out  = virt_kbd_mod;
assign virt_kbd_key1_out = virt_kbd_key1;
assign virt_kbd_key2_out = virt_kbd_key2;
assign virt_kbd_key3_out = virt_kbd_key3;
assign virt_kbd_key4_out = virt_kbd_key4;
assign usb_host_enable_out = usb_host_enable;

assign dbg_stall_undec_out = dbg_stall_undec;
assign dbg_stall_peri_out  = dbg_stall_peri;
assign dbg_stall_ram_out   = dbg_stall_ram;

endmodule

module picosoc_regs (
	input clk, wen,
	input [5:0] waddr,
	input [5:0] raddr1,
	input [5:0] raddr2,
	input [31:0] wdata,
	output [31:0] rdata1,
	output [31:0] rdata2
);
	reg [31:0] regs [0:31];

	always @(posedge clk)
		if (wen) regs[waddr[4:0]] <= wdata;

	assign rdata1 = regs[raddr1[4:0]];
	assign rdata2 = regs[raddr2[4:0]];
endmodule

