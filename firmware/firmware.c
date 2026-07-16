// Simple firmware for Tang Atari 800
// Adapted from SNESTang firmware for Atari 800 core
// Nand2mario & Google DeepMind team, 2026

#include <stdbool.h>
#include "picorv32.h"
#include "fatfs/ff.h"
#include "firmware.h"
#include "xex_loader.h"   // 6502 binary-load boot loader image (virtual D1: disk)

uint32_t CORE_ID;

void uart_keyboard_poll(void);

#define OPTION_FILE "/atari.ini"
#define OPTION_INVALID 2

#define OPTION_OSD_KEY_SELECT_START 1
#define OPTION_OSD_KEY_SELECT_RIGHT 2

int option_osd_key = OPTION_OSD_KEY_SELECT_RIGHT;
int option_arrow_joystick = 0;              // 1 = arrow keys drive Joystick 1 (Left-Alt = fire)
int option_scanline_level = 0;              // 0=off,1=25%,2=50%,3=75% scanline brightness
int option_h_offset = 0;                    // horizontal pan: capture-skip pixels (0..48)
int option_stereo = 0;                      // 1 = dual-POKEY stereo (POKEY2 @ $D210 -> right); default mono

// Atari RAM size choices offered in OSD Options. code = core RAM_SELECT (RAMBO
// variants); kb = label/persisted value. Index 0 (128 KB) is the default.
static const struct { unsigned char code; int kb; } ram_opts[] = {
    {1, 128}, {3, 320}, {5, 576}, {6, 1088}
};
#define N_RAM_OPTS 4
int option_ram_idx = 0;                      // index into ram_opts; 0 = 128 KB (default)
#define OSD_KEY_CODE (option_osd_key == OPTION_OSD_KEY_SELECT_START ? 0xC : 0x84)

// Push the input-related options into the hardware config register (0xA4):
// bit 8 = USB-host-keyboard enable (permanently 0: keyboard is UART/CH9350 only),
// bit 9 = arrow-keys-as-joystick mode.
static inline void apply_input_options(void) {
    reg_virt_kbd_1 = (option_arrow_joystick ? 0x200 : 0x000);
}

// Push video options into the hardware config registers.
static inline void apply_video_options(void) {
    reg_video_opts = (option_scanline_level & 0x3)  // 0x B4 [1:0] scanline level
                   | ((option_stereo & 1) << 2);    //      [2]   dual-POKEY stereo enable
    reg_h_offset   = option_h_offset & 0xFF;        // 0x B8 [7:0] horizontal position
}

// RAM size only takes effect when the core boots, so this is written before the
// core is released at boot and again inside cold_boot_atari() (RAM changes in the
// OSD cold-boot the machine). 0x BC [2:0] = core RAM_SELECT.
static inline void apply_machine_options(void) {
    reg_ram_select = ram_opts[option_ram_idx].code;
}

char load_fname[512];

FATFS fs;

#define PAGESIZE 24
#define TOPLINE 2
#define PWD_SIZE 256

char pwd[PWD_SIZE];		// total path length 255
// one page of file names to display
#define FNAME_W 28   // displayable name width (OSD row minus margins), incl. NUL
char file_names[PAGESIZE][FNAME_W];  // display name (long name, truncated to fit)
char file_alt[PAGESIZE][13];         // 8.3 short name — ALWAYS use this to open/navigate
                                     // (the display name may be truncated → not openable)
char file_dir[PAGESIZE];
int file_sizes[PAGESIZE];
int file_len;		// number of files on this page

// ATR Disk Emulator state
#define ATR_DRIVES 2            // D1: (0x31) and D2: (0x32)
FIL atr_file[ATR_DRIVES];
bool atr_mounted[ATR_DRIVES] = {false, false};
bool atr_readonly[ATR_DRIVES] = {false, false};  // write-open failed even after AM_RDO strip
uint16_t atr_sector_size[ATR_DRIVES] = {128, 128};
// Byte offset of sector 1 in the image: 16 for .atr (header), 0 for raw .xfd.
uint16_t atr_hdr_off[ATR_DRIVES] = {16, 16};

// XEX (Atari binary executable) state — served as a virtual bootable disk on D1:
// only. When xex_active, D1: STATUS/READ are answered from the baked-in 6502 boot
// loader (sectors 1..XEX_BLDCNT) + the raw .xex file bytes (XEX_FIRSTSEC..).
bool     xex_active = false;
FIL      xex_file;
uint32_t xex_len = 0;

static uint8_t sio_sector_buf[256];
static uint8_t sio_cmd_buf[5];
static int     sio_cmd_idx = 0;
static uint32_t sio_cmd_timeout = 0;   // millis timestamp of first byte in current frame

// SIO Diagnostics variables
uint8_t dbg_last_sio_cmd = 0;
uint16_t dbg_last_sio_sector = 0;
int dbg_last_sio_status = 0;
uint32_t dbg_sio_read_count = 0;
uint32_t dbg_sio_write_count = 0;
uint32_t dbg_sio_status_count = 0;
uint32_t dbg_sio_err_count = 0;
uint32_t dbg_sio_rx_byte_count = 0;
uint32_t dbg_sio_timeout_count = 0;
uint8_t dbg_rx_buf[12] = {0};
uint8_t dbg_rx_cmd_line_buf[12] = {0};
uint8_t dbg_rx_buf_idx = 0;

typedef struct {
    uint8_t device;
    uint8_t cmd;
    uint8_t aux1;
    uint8_t aux2;
    uint8_t checksum;
    uint8_t processed;
} dbg_cmd_frame_t;

dbg_cmd_frame_t dbg_cmd_history[4];
uint8_t dbg_cmd_history_idx = 0;

uint32_t dbg_sio_cmd_low_ticks = 0;
uint32_t dbg_sio_txd_low_ticks = 0;
uint32_t dbg_sio_tx_count = 0;   // bytes pushed to the TX FIFO (reg_sio_tx)
// TX-line diagnostics, latched while the core is running (sampled in main loop):
uint8_t  dbg_tx_pe_prev   = 0;   // last pokey tick-counter value seen
uint8_t  dbg_tx_pe_moved  = 0;   // POKEY_ENABLE counter ever advanced (TX clock alive)
uint8_t  dbg_tx_line_hi   = 0;   // transmit line (p2s) ever observed HIGH (idle)
uint8_t  dbg_tx_fifo_empty= 0;   // TX FIFO ever observed empty
uint8_t  dbg_tx_state_or  = 0;   // OR of all p2s_state values seen

void sio_txdiag_sample(void) {
    uint32_t d = reg_sio_txdiag;
    uint8_t pe = (d >> 8) & 0xFF;
    if (pe != dbg_tx_pe_prev) { dbg_tx_pe_moved = 1; dbg_tx_pe_prev = pe; }
    if ((d >> 1) & 1) dbg_tx_line_hi = 1;     // p2s transmit line high (idle)
    if ((d >> 2) & 1) dbg_tx_fifo_empty = 1;  // fifo_tx_empty
    dbg_tx_state_or |= (d >> 4) & 0xF;        // p2s_state
}

// --- Frame-rate / lines-per-frame measurement (reads hardware reg_video_diag,
//     NOT SDRAM -> reliable, no arbiter starvation, no hang) ---
uint32_t dbg_frame_rate = 0;          // measured Atari frames/sec (~60 = correct NTSC)
uint32_t dbg_lines_per_frame = 0;     // scanlines per frame (~262 = correct NTSC)
uint32_t dbg_resp_time_us = 0;        // duration of the last sio_process_command (us)
static uint32_t fr_last_cycle = 0;
static uint16_t fr_last_vs = 0;

void frame_rate_sample(void) {
    uint32_t now = reg_cycle;
    if ((uint32_t)(now - fr_last_cycle) >= 27000000u) { // ~1 second at 27 MHz
        uint32_t vd = reg_video_diag;
        uint16_t vs = (uint16_t)(vd & 0xFFFF);          // free-running frame counter
        dbg_lines_per_frame = (vd >> 16) & 0xFFFF;      // latched lines/frame
        if (fr_last_cycle != 0) {
            uint32_t dc  = now - fr_last_cycle;
            uint16_t dvs = vs - fr_last_vs;             // frames elapsed
            dbg_frame_rate = (dvs * 2700000u) / (dc / 10u);
        }
        fr_last_cycle = now;
        fr_last_vs    = vs;
    }
}

// Install a self-contained 6502 stub into Atari RAM page 6 ($0600) that fills in
// the Device Control Block for a D1: STATUS command and calls SIOV. Lets the SIO
// response test be just  X=USR(1536)  in BASIC instead of ~15 POKE lines.
// Atari RAM is memory-mapped to the firmware at 0x00200000 (same base the menu
// uses for COLDST $0244), so $0600 -> 0x00200600. Page 6 is free RAM that the OS
// and BASIC do not clear after boot, so the stub persists once written.
void install_sio_test_stub(void) {
    static const uint8_t stub[] = {
        0x68,                        // PLA            ; discard USR arg-count byte
        0xA9,0x31, 0x8D,0x00,0x03,   // LDA #$31 : STA $0300  DDEVIC = D1:
        0xA9,0x01, 0x8D,0x01,0x03,   // LDA #$01 : STA $0301  DUNIT  = 1
        0xA9,0x53, 0x8D,0x02,0x03,   // LDA #$53 : STA $0302  DCOMND = Status
        0xA9,0x40, 0x8D,0x03,0x03,   // LDA #$40 : STA $0303  DSTATS = read
        0xA9,0x00, 0x8D,0x04,0x03,   // LDA #$00 : STA $0304  DBUFLO = 0
        0xA9,0x07, 0x8D,0x05,0x03,   // LDA #$07 : STA $0305  DBUFHI = 7  -> $0700
        0xA9,0x0F, 0x8D,0x06,0x03,   // LDA #$0F : STA $0306  DTIMLO = 15
        0xA9,0x04, 0x8D,0x08,0x03,   // LDA #$04 : STA $0308  DBYTLO = 4
        0xA9,0x00, 0x8D,0x09,0x03,   // LDA #$00 : STA $0309  DBYTHI = 0
        0xA9,0x00, 0x8D,0x0A,0x03,   // LDA #$00 : STA $030A  DAUX1  = 0
        0x8D,0x0B,0x03,              //            STA $030B  DAUX2  = 0 (A still 0)
        0x20,0x59,0xE4,              // JSR $E459  SIOV
        0x60                         // RTS
    };
    volatile uint8_t *ram = (volatile uint8_t *)(0x00200000u + 0x0600u);
    for (unsigned i = 0; i < sizeof(stub); i++) ram[i] = stub[i];
}

void status(char *msg) {
    cursor(0, 27);
    for (int i = 0; i < 32; i++)
        putchar(' ');
    cursor(2, 27);
    print(msg);
}

// show a pop-up message, press any key to discard (caller needs to redraw screen)
// msg: could be multi-line (separate with \n), max 10 lines
// center: whether to center the text
void message(char *msg, int center) {
    // count number of lines and max width
    int w[10], lines=10, maxw = 0;
    int len = strlen(msg);
    char *end = msg + len;
    char *sol = msg;
    for (int i = 0; i < 10; i++) {
        char *eol = strchr(sol, '\n');
        if (eol) { // found \n
            w[i] = min(eol - sol, 26);
            maxw = max(w[i], maxw);
            sol = eol+1;
        } else {
            w[i] = min(end - sol, 26);
            maxw = max(w[i], maxw);
            lines = i+1;
            break;
        }		
    }
    // draw a box 
    int y0 = 14 - ((lines + 2) >> 1);
    int y1 = y0 + lines + 2;
    int x0 = 16 - ((maxw + 2) >> 1);
    int x1 = x0 + maxw + 2;
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
            cursor(x, y);
            if ((x == x0 || x == x1-1) && (y == y0 || y == y1-1))
                putchar('+');
            else if (x == x0 || x == x1-1)
                putchar('|');
            else if (y == y0 || y == y1-1)
                putchar('-');
            else
                putchar(' ');
        }
    // print text
    char *s = msg;
    for (int i = 0; i < lines; i++) {
        if (center)
            cursor(16-(w[i]>>1), y0+i+1);
        else
            cursor(x0+1, y0+i+1);
        while (*s != '\n' && *s != '\0') {
            putchar(*s);
            s++;
        }
        s++;
    }
    // wait for a keypress
    delay(300);
    for (;;) {
        int joy1, joy2;
        joy_get(&joy1, &joy2);
        if ((joy1 & 0x1) || (joy1 & 0x100) || (joy2 & 0x1) || (joy2 & 0x100))
            break;
    }
    delay(300);
}

// return 0: success, 1: no option file found, 2: option file corrupt,
// -1: transient SD/FS error (card not ready / disk error) -> caller should retry.
// The distinction matters at boot: load_option() is the FIRST real SD access (f_mount
// is lazy), so a mid-state card (common after a warm S1 reset) makes f_open fail. A
// genuinely-absent file (FR_NO_FILE, first run) must NOT trigger a retry storm.
int load_option()  {
    FIL f;
    int r = 0;
    char buf[1024];
    char *line, *key, *value;
    FRESULT fr = f_open(&f, OPTION_FILE, FA_READ);
    if (fr != FR_OK)
        return (fr == FR_NO_FILE || fr == FR_NO_PATH) ? 1 : -1;
    while (f_gets(buf, 1024, &f)) {
        line = trimwhitespace(buf);
        if (line[0] == '\0' || line[0] == '[' || line[0] == ';' || line[0] == '#')
            continue;
        // find '='
        char *s = strchr(line, '=');
        if (!s) {
            r = OPTION_INVALID;
            goto load_option_close;
        }
        *s='\0';
        key = trimwhitespace(line);
        value = trimwhitespace(s+1);
        uart_printf("key=%s, value=%s\n", key, value);

        if (strcmp(key, "osd_key") == 0) {
            option_osd_key = atoi(value);
            if (option_osd_key <= 0) {
                r = OPTION_INVALID;
                goto load_option_close;
            }
        }
        if (strcmp(key, "joystick") == 0) {
            option_arrow_joystick = (atoi(value) != 0);
        }
        if (strcmp(key, "scanlines") == 0) {
            option_scanline_level = atoi(value) & 0x3;
        }
        if (strcmp(key, "hpos") == 0) {
            int v = atoi(value);
            if (v < 0) v = 0;
            if (v > 48) v = 48;
            option_h_offset = v;
        }
        if (strcmp(key, "stereo") == 0) {
            option_stereo = (atoi(value) != 0);
        }
        if (strcmp(key, "ram") == 0) {
            int kb = atoi(value);
            option_ram_idx = 0;   // default 128 KB if no match
            for (int i = 0; i < N_RAM_OPTS; i++)
                if (ram_opts[i].kb == kb) { option_ram_idx = i; break; }
        }
    }

load_option_close:
    f_close(&f);
    return r;
}

// return 0: success, 1: cannot save. EVERY f_puts is checked (a half-written file is
// worse than none — it loads back as defaults for the missing keys), and so is f_close:
// FatFs buffers the last sector, so a card write error often surfaces only on close. The
// caller reports the failure to the user; we only mark the file hidden once it is whole.
int save_option() {
    FIL f;
    int err = 0;
    if (f_open(&f, OPTION_FILE, FA_READ | FA_WRITE | FA_CREATE_ALWAYS))
        return 1;

    err |= (f_puts("osd_key=", &f) < 0);
    err |= (f_puts(option_osd_key == OPTION_OSD_KEY_SELECT_START ? "1\n" : "2\n", &f) < 0);

    err |= (f_puts("joystick=", &f) < 0);
    err |= (f_puts(option_arrow_joystick ? "1\n" : "0\n", &f) < 0);

    err |= (f_puts("scanlines=", &f) < 0);
    { char s[2] = { (char)('0' + (option_scanline_level & 0x3)), 0 }; err |= (f_puts(s, &f) < 0); }
    err |= (f_puts("\n", &f) < 0);

    err |= (f_puts("hpos=", &f) < 0);
    { char s[4]; int n = option_h_offset, k = 0;
      if (n >= 10) s[k++] = '0' + (n / 10);
      s[k++] = '0' + (n % 10); s[k] = 0; err |= (f_puts(s, &f) < 0); }
    err |= (f_puts("\n", &f) < 0);

    err |= (f_puts("stereo=", &f) < 0);
    err |= (f_puts(option_stereo ? "1\n" : "0\n", &f) < 0);

    err |= (f_puts("ram=", &f) < 0);
    { char s[6]; int n = ram_opts[option_ram_idx].kb, k = 0, d = 1000;
      while (d > n && d > 1) d /= 10;
      while (d >= 1) { s[k++] = '0' + (n / d) % 10; d /= 10; }
      s[k] = 0; err |= (f_puts(s, &f) < 0); }
    err |= (f_puts("\n", &f) < 0);

    if (f_close(&f) != FR_OK)        // flushes the final sector — write errors land here
        err = 1;
    if (err)
        return 1;

    f_chmod(OPTION_FILE, AM_HID, AM_HID);
    return 0;
}

// starting from `start`, load `len` file names into file_names, file_dir. 
// *count is set to number of all valid entries and `file_len` is
// set to valid entries on this page.
// return: 0 if successful
int load_dir(char *dir, int start, int len, int *count, int carts) {
    DEBUG("load_dir: %s, start=%d, len=%d\n", dir, start, len);
    int cnt = 0;
    DIR d;
    file_len = 0;
    if (f_opendir(&d, dir) != 0) {
        extern int sd_initialized;
        sd_initialized = 0;
        if (f_opendir(&d, dir) != 0) {
            return -1;
        }
    }
    // an entry to return to parent dir or main menu 
    int is_root = dir[1] == '\0';
    if (start == 0 && len > 0) {
        if (is_root) {
            strncpy(file_names[0], "<< Back", FNAME_W);
            file_dir[0] = 0;
        } else {
            strncpy(file_names[0], "..", FNAME_W);
            file_dir[0] = 1;
        }
        file_alt[0][0] = '\0';
        file_len++;
    }
    cnt++;

    // generate all file entries
    FILINFO fno;
    while (f_readdir(&d, &fno) == FR_OK) {
        if (fno.fname[0] == 0)
            break;
        if ((fno.fattrib & AM_HID) || (fno.fattrib & AM_SYS))
             // skip hidden and system files
            continue;
        
        int is_dir = (fno.fattrib & AM_DIR) != 0;
        int is_atr = 0;   // "selectable file" for the current browser context
        if (!is_dir) {
            char *ext = strrchr(fno.fname, '.');
            if (ext) {
                if (carts)
                    is_atr = (strcasecmp(ext, ".car") == 0 || strcasecmp(ext, ".rom") == 0);
                else
                    // disk browser lists .atr, raw .xfd, and .xex (binary executables)
                    is_atr = (strcasecmp(ext, ".atr") == 0 || strcasecmp(ext, ".xfd") == 0 ||
                              strcasecmp(ext, ".xex") == 0);
            }
        }

        // Print debug information to UART
        uart_printf("Found: '%s' (is_dir=%d, is_atr=%d, size=%d)\n", fno.fname, is_dir, is_atr, (int)fno.fsize);

        if (is_dir || is_atr) {
            if (cnt >= start && file_len < len) {
                strncpy(file_names[file_len], fno.fname, FNAME_W);
                file_names[file_len][FNAME_W-1] = '\0';
                // altname is empty when the name already fits 8.3 (fname IS the SFN)
                strncpy(file_alt[file_len], fno.altname[0] ? fno.altname : fno.fname, 13);
                file_alt[file_len][12] = '\0';
                file_dir[file_len] = is_dir;
                file_sizes[file_len] = fno.fsize;
                file_len++;
            }
            cnt++;
        }
    }
    f_closedir(&d);
    *count = cnt;
    DEBUG("load_dir: count=%d\n", cnt);
    return 0;
}

// ── Cartridge loading ────────────────────────────────────────────────────────
// The Atari core's CartLogic reads cart data from SDRAM; tang_top remaps those
// accesses into the 4 MB window at physical 0x400000-0x7FFFFF (= same address in
// the firmware's view, banks 2-3 pass through the iosys swap unchanged), so we just
// f_read the image straight into SDRAM there, set the mapper code in reg_cart_mode,
// and cold-boot. BASIC/OS were relocated out of this window (to 0x1F0000/0x1F4000).
#define CART_SDRAM_BASE 0x00400000u
#define CART_MAX_SIZE   0x00400000u

// CAR header type -> core CartLogic mode (see rtl/common/a8core/cart_logic.vhd).
// Pairs of {CAR type, mode}; unknown types are rejected with an error message.
static const uint8_t car_type_map[][2] = {
    {1,0x01},  {2,0x21},  {8,0x0D},  {9,0x0B},  {10,0x0A}, {11,0x08},
    {12,0x30}, {13,0x31}, {14,0x32}, {15,0x04}, {17,0x0C}, {21,0x14},
    {22,0x0E}, {23,0x33}, {24,0x34}, {25,0x35}, {26,0x28}, {27,0x29},
    {28,0x2A}, {29,0x2B}, {30,0x2C}, {31,0x2D}, {32,0x2E},
    {33,0x38}, {34,0x39}, {35,0x3A}, {36,0x3B}, {37,0x3C}, {38,0x3D}, // switchable XEGS
    {39,0x40},                                                        // Phoenix 8K
    {40,0x23}, {41,0x02}, {42,0x03}, {43,0x09}, {44,0x05}, {45,0x06},
    {46,0x12}, {50,0x45}, {51,0x46}, {52,0x47},                       // Turbosoft, Ultracart
    {54,0x24}, {55,0x25}, {56,0x26}, {57,0x16}, {58,0x17}, {59,0x15},
    {60,0x13}, {63,0x20}, {64,0x2F},                                  // MegaCart 4MB / 2MB
    {69,0x48}, {70,0x49},                                             // aDawliah 32/64K
    {75,0x10},
};

// returns 0 on success (reg_cart_mode set, data in SDRAM), nonzero on error
int load_cartridge(char *filepath) {
    FIL f;
    unsigned int br;
    int r = f_open(&f, filepath, FA_READ);
    if (r != FR_OK) {
        uart_printf("cart: open '%s' failed %d\n", filepath, r);
        message("Cannot open cartridge", 1);
        return -1;
    }
    uint32_t fsize = f_size(&f);
    uint32_t data_size = fsize;
    uint8_t mode = 0;

    char *ext = strrchr(filepath, '.');
    if (ext && strcasecmp(ext, ".car") == 0) {
        uint8_t hdr[16];
        if (f_read(&f, hdr, 16, &br) != FR_OK || br != 16 ||
            hdr[0] != 'C' || hdr[1] != 'A' || hdr[2] != 'R' || hdr[3] != 'T') {
            f_close(&f);
            message("Not a valid .CAR file", 1);
            return -2;
        }
        uint32_t car_type = ((uint32_t)hdr[4] << 24) | ((uint32_t)hdr[5] << 16) |
                            ((uint32_t)hdr[6] << 8)  |  (uint32_t)hdr[7];
        for (unsigned i = 0; i < sizeof(car_type_map)/2; i++)
            if (car_type_map[i][0] == car_type) { mode = car_type_map[i][1]; break; }
        if (mode == 0) {
            f_close(&f);
            uart_printf("cart: unsupported CAR type %d\n", (int)car_type);
            char m[40];
            strcpy(m, "Unsupported CAR type ");
            char *e = m + strlen(m);
            if (car_type >= 100) *e++ = '0' + (car_type / 100) % 10;
            if (car_type >= 10)  *e++ = '0' + (car_type / 10) % 10;
            *e++ = '0' + car_type % 10;
            *e = '\0';
            message(m, 1);
            return -3;
        }
        data_size = fsize - 16;
    } else {
        // raw .rom dump: pick the mapper from the size
        switch (fsize) {
            case 2048:  mode = 0x16; break;
            case 4096:  mode = 0x17; break;
            case 8192:  mode = 0x01; break;
            case 16384: mode = 0x21; break;
            default:
                f_close(&f);
                message("Raw .ROM must be 2/4/8/16K\nuse a .CAR instead", 1);
                return -4;
        }
    }
    if (data_size > CART_MAX_SIZE) {
        f_close(&f);
        message("Cartridge too large (>4MB)\ndoes not fit 8MB SDRAM", 1);
        return -5;
    }

    status("Loading cartridge...");
    r = f_read(&f, (void *)CART_SDRAM_BASE, data_size, &br);
    f_close(&f);
    if (r != FR_OK || br != data_size) {
        uart_printf("cart: read failed %d (br=%u/%u)\n", r, br, (unsigned)data_size);
        message("Cartridge read error", 1);
        return -6;
    }
    reg_cart_mode = mode;
    uart_printf("cart: '%s' loaded, %u bytes, mode 0x%x\n", filepath, (unsigned)data_size, mode);
    return 0;
}

int mount_atr(char *filepath, int slot) {
    if (atr_mounted[slot]) {
        f_close(&atr_file[slot]);
        atr_mounted[slot] = false;
    }
    if (slot == 0 && xex_active) {   // an ATR takes D1: back from a mounted XEX
        f_close(&xex_file);
        xex_active = false;
    }

    atr_readonly[slot] = false;
    int r = f_open(&atr_file[slot], filepath, FA_READ | FA_WRITE);
    if (r != FR_OK) {
        // Most common cause: FAT read-only attribute inherited from a PC copy.
        // Strip it and retry before giving up on write access.
        f_chmod(filepath, 0, AM_RDO);
        r = f_open(&atr_file[slot], filepath, FA_READ | FA_WRITE);
    }
    if (r != FR_OK) {
        // Fall back to read-only, but LOUDLY: the slot is flagged, the menu shows
        // "(RO)", STATUS reports write-protect, and writes return 'E' (error 144) —
        // never a silent mount whose writes then fail as a bare error 139.
        r = f_open(&atr_file[slot], filepath, FA_READ);
        if (r != FR_OK) {
            uart_printf("atr open %s %d\n", filepath, r);
            return r;
        }
        atr_readonly[slot] = true;
        uart_printf("atr RO\n");
    }

    // VOLUME-CORRUPTION GUARD: the same file open for WRITE on both slots is
    // illegal in FatFs with FF_FS_LOCK=0 (two FILs with divergent cluster/size
    // state write inconsistent FAT/dir updates -> can destroy the whole volume,
    // HW-confirmed 2026-07: SD card FAT wiped after same-ATR-on-D1+D2 testing).
    // Detect by start cluster and demote THIS mount to read-only.
    if (!atr_readonly[slot] && atr_mounted[1 - slot] &&
        atr_file[slot].obj.sclust == atr_file[1 - slot].obj.sclust) {
        f_close(&atr_file[slot]);
        r = f_open(&atr_file[slot], filepath, FA_READ);
        if (r != FR_OK) return r;
        atr_readonly[slot] = true;
    }

    char *ext = strrchr(filepath, '.');
    if (ext && strcasecmp(ext, ".xfd") == 0) {
        // .xfd = raw sector dump, no header. Geometry inferred from file size.
        // SD = 92160 (720x128), ED = 133120 (1040x128), DD = 183936 (sectors 1-3 are
        // 128 B, 4+ are 256 B — same boot-sector quirk as ATR). Any other 128-multiple
        // is treated as a 128-B-sector image (offset math is size-independent there).
        uint32_t fsz = f_size(&atr_file[slot]);
        if (fsz == 183936) {
            atr_sector_size[slot] = 256;
        } else if (fsz >= 128 && (fsz % 128) == 0) {
            atr_sector_size[slot] = 128;
        } else {
            uart_printf("bad xfd %d\n", (int)fsz);
            message("Unsupported .xfd size", 1);
            f_close(&atr_file[slot]);
            return -3;
        }
        atr_hdr_off[slot] = 0;
        uart_printf("XFD D%d %s ss %d\n", slot+1, filepath, atr_sector_size[slot]);
        atr_mounted[slot] = true;
        if (atr_readonly[slot])
            message("Disk is read-only\nWrites will fail (144)", 1);
        return 0;
    }

    // Read ATR 16-byte header
    uint8_t header[16];
    unsigned int br;
    r = f_read(&atr_file[slot], header, 16, &br);
    if (r != FR_OK || br != 16) {
        uart_printf("atr hdr err %d\n", r);
        f_close(&atr_file[slot]);
        return -1;
    }

    // Verify magic
    uint16_t magic = header[0] | (header[1] << 8);
    if (magic != 0x0296) {
        uart_printf("atr magic %w\n", magic);
        f_close(&atr_file[slot]);
        return -2;
    }

    atr_sector_size[slot] = header[4] | (header[5] << 8);
    if (atr_sector_size[slot] != 128 && atr_sector_size[slot] != 256) {
        uart_printf("bad ss %d\n", atr_sector_size[slot]);
        f_close(&atr_file[slot]);
        return -3;
    }
    atr_hdr_off[slot] = 16;

    uart_printf("ATR D%d %s ss %d\n", slot+1, filepath, atr_sector_size[slot]);
    atr_mounted[slot] = true;
    if (atr_readonly[slot])
        message("Disk is read-only\nWrites will fail (144)", 1);
    return 0;
}

int atr_read_sector(int slot, uint32_t sector_num, uint8_t *buf, int *sector_len) {
    if (!atr_mounted[slot]) return -1;
    
    uint32_t base = atr_hdr_off[slot];   // 16 for .atr, 0 for .xfd
    uint32_t offset = 0;
    int len = 128;
    if (atr_sector_size[slot] == 128) {
        offset = base + (sector_num - 1) * 128;
        len = 128;
    } else { // 256 bytes
        if (sector_num <= 3) {
            offset = base + (sector_num - 1) * 128;
            len = 128;
        } else {
            offset = base + 384 + (sector_num - 4) * 256;
            len = 256;
        }
    }
    
    *sector_len = len;

    // Out-of-range = error like a real drive. CRITICAL: never f_lseek past
    // EOF — on a writable FIL FatFs ALLOCATES the gap (one stray sector
    // number grew an ATR 92 KB -> 8.4 MB and dirtied the volume; host-proven).
    if (sector_num == 0 || offset + len > f_size(&atr_file[slot])) return -5;

    int r = f_lseek(&atr_file[slot], offset);
    if (r != FR_OK) {
        return r;
    }
    
    unsigned int br;
    r = f_read(&atr_file[slot], buf, len, &br);
    if (r != FR_OK || br != len) {
        uart_printf("rd fail %d got %d\n", sector_num, br);
        return -2;
    }

    return 0;
}

// Mount a .xex as the virtual boot disk on D1:.  Validates the $FFFF header and
// patches the 24-bit byte length into the baked-in loader image so it knows how
// many bytes to pull over SIO.
int mount_xex(char *filepath) {
    if (xex_active) {
        f_close(&xex_file);
        xex_active = false;
    }
    int r = f_open(&xex_file, filepath, FA_READ);
    if (r != FR_OK) {
        uart_printf("xex open %s %d\n", filepath, r);
        message("Cannot open XEX file", 1);
        return r;
    }
    xex_len = f_size(&xex_file);
    // Sanity: a binary-load file must begin with the $FFFF header word.
    uint8_t h[2];
    unsigned int br;
    if (f_read(&xex_file, h, 2, &br) != FR_OK || br != 2 ||
        h[0] != 0xFF || h[1] != 0xFF) {
        f_close(&xex_file);
        message("Not a valid .XEX\n(missing $FFFF header)", 1);
        return -1;
    }
    // Patch the 24-bit remaining-byte length into the loader's init code.
    xex_loader_img[XEX_REMLO_OFF]  =  xex_len        & 0xFF;
    xex_loader_img[XEX_REMMID_OFF] = (xex_len >> 8)  & 0xFF;
    xex_loader_img[XEX_REMHI_OFF]  = (xex_len >> 16) & 0xFF;
    // Take over D1: from any mounted ATR.
    if (atr_mounted[0]) {
        f_close(&atr_file[0]);
        atr_mounted[0] = false;
    }
    atr_sector_size[0] = 128;   // virtual disk is single density
    xex_active = true;
    uart_printf("xex %s %d\n", filepath, (int)xex_len);
    return 0;
}

// Serve one 128-byte sector of the virtual XEX disk into buf.
int xex_read_sector(uint32_t sector_num, uint8_t *buf, int *sector_len) {
    *sector_len = 128;
    if (sector_num >= 1 && sector_num <= XEX_BLDCNT) {
        // Boot loader image.
        uint32_t base = (sector_num - 1) * 128;
        for (int i = 0; i < 128; i++) buf[i] = xex_loader_img[base + i];
        return 0;
    }
    if (sector_num >= XEX_FIRSTSEC) {
        // Raw .xex bytes, 128 per sector; zero-pad the final partial sector.
        uint32_t off = (sector_num - XEX_FIRSTSEC) * 128;
        for (int i = 0; i < 128; i++) buf[i] = 0;
        if (off < xex_len) {
            unsigned int br;
            uint32_t n = xex_len - off;
            if (n > 128) n = 128;
            if (f_lseek(&xex_file, off) != FR_OK) return -1;
            if (f_read(&xex_file, buf, n, &br) != FR_OK) return -2;
        }
        return 0;
    }
    return -1;   // sector 0 is invalid
}

int atr_write_sector(int slot, uint32_t sector_num, const uint8_t *buf, int len) {
    if (!atr_mounted[slot]) return -1;
    
    uint32_t base = atr_hdr_off[slot];   // 16 for .atr, 0 for .xfd
    uint32_t offset = 0;
    if (atr_sector_size[slot] == 128) {
        offset = base + (sector_num - 1) * 128;
    } else { // 256 bytes
        if (sector_num <= 3) {
            offset = base + (sector_num - 1) * 128;
        } else {
            offset = base + 384 + (sector_num - 4) * 256;
        }
    }
    
    // same out-of-range guard as atr_read_sector (see comment there)
    if (sector_num == 0 || offset + len > f_size(&atr_file[slot])) return -5;

    int r = f_lseek(&atr_file[slot], offset);
    if (r != FR_OK) {
        return r;
    }
    
    unsigned int bw;
    r = f_write(&atr_file[slot], buf, len, &bw);
    if (r != FR_OK || bw != len) {
        uart_printf("wr fail %d bw %d\n", sector_num, bw);
        return -2;
    }

    f_sync(&atr_file[slot]);
    return 0;
}

// SIO FORMAT: zero-fill the mounted image's whole data area (a freshly formatted
// disk from the drive's point of view; DOS then writes its own FS structures).
// Sequential f_write with a single f_sync — per-sector sync would take ~700x longer.
int atr_format(int slot) {
    if (!atr_mounted[slot] || atr_readonly[slot]) return -1;
    uint32_t base = atr_hdr_off[slot];
    uint32_t total = f_size(&atr_file[slot]);
    if (total < base) return -1;
    uint32_t remaining = total - base;
    if (f_lseek(&atr_file[slot], base) != FR_OK) return -2;
    uint8_t zeros[128];
    memset(zeros, 0, sizeof(zeros));
    while (remaining > 0) {
        unsigned int chunk = remaining > 128 ? 128 : remaining;
        unsigned int bw;
        if (f_write(&atr_file[slot], zeros, chunk, &bw) != FR_OK || bw != chunk) {
            return -3;
        }
        remaining -= chunk;
    }
    if (f_sync(&atr_file[slot]) != FR_OK) return -4;
    return 0;
}

// Create a fresh 90K single-density ATR in the root dir under the first free
// BLANK01.ATR..BLANK99.ATR name, zero-filled (= unformatted; DOS's format works —
// SIO FORMAT is implemented), and mount it on `slot`. Returns 0 with the bare
// filename in out_name (>= 16 bytes), -1 = no free name, -2 = failed (stage and
// FatFs code left in cba_stage/cba_err for the status line).
// Uses atr_file[slot] as the scratch FIL and sio_sector_buf as the zero buffer —
// NO large stack objects: FF_USE_LFN=2 already stacks ~530 B per path op and the
// stack region is down to ~4.1 KB. (SIO is not serviced inside this call, so
// borrowing sio_sector_buf is safe.) A disk mounted on the slot is detached first.
int cba_stage, cba_err;
int create_blank_atr(int slot, char *out_name) {
    char path[16];
    strcpy(path, "/BLANK00.ATR");
    if (atr_mounted[slot]) {          // free the slot's FIL for use as scratch
        f_close(&atr_file[slot]);
        atr_mounted[slot] = false;
    }
    FIL *f = &atr_file[slot];
    int r = FR_EXIST;
    for (int i = 1; i < 100 && r == FR_EXIST; i++) {
        path[6] = '0' + i / 10;
        path[7] = '0' + i % 10;
        r = f_open(f, path, FA_CREATE_NEW | FA_WRITE);
    }
    cba_stage = 1; cba_err = r;
    if (r == FR_EXIST) return -1;
    if (r != FR_OK) return -2;
    uint8_t *buf = sio_sector_buf;
    memset(buf, 0, 128);
    buf[0] = 0x96; buf[1] = 0x02;   // ATR magic
    buf[2] = 0x80; buf[3] = 0x16;   // 5760 paragraphs = 92160 bytes (720 x 128)
    buf[4] = 128;                   // sector size
    unsigned int bw;
    cba_stage = 2;
    r = f_write(f, buf, 16, &bw);
    if (r != FR_OK || bw != 16) { cba_err = r; f_close(f); return -2; }
    memset(buf, 0, 16);             // header bytes done — body is all zeros
    cba_stage = 3;
    for (int s = 0; s < 720; s++) {
        r = f_write(f, buf, 128, &bw);
        if (r != FR_OK || bw != 128) { cba_err = r; f_close(f); return -2; }
    }
    f_close(f);
    cba_stage = 4;
    cba_err = mount_atr(path, slot);
    if (cba_err != 0) return -2;
    strcpy(out_name, path + 1);     // bare name for the menu line
    return 0;
}

// return 0: user chose a ROM (*choice), 1: no choice made, -1: error
int menu_loadrom(int *choice, int carts, int slot) {
    int page = 0, pages, total;
    int active = 0;
    pwd[0] = '/';
    pwd[1] = '\0';
    while (1) {
        clear();
        int r = load_dir(pwd, page*PAGESIZE, PAGESIZE, &total, carts);
        if (r == 0) {
            pages = (total+PAGESIZE-1) / PAGESIZE;
            status("Page ");
            printf("%d/%d", page+1, pages);
            if (active > file_len-1)
                active = file_len-1;
            for (int i = 0; i < PAGESIZE; i++) {
                int idx = page*PAGESIZE + i;
                cursor(2, i+TOPLINE);
                if (idx < total) {
                    print(file_names[i]);
                    if (idx != 0 && file_dir[i])
                        print("/");
                }
            }
            delay(300);
            while (1) {
                uart_keyboard_poll();
                sio_poll();   // Atari runs live behind the menu — keep disk I/O alive
                int r = joy_choice(TOPLINE, file_len, &active, OSD_KEY_CODE);
                int j1, j2;
                joy_get(&j1, &j2);
                if ((j1 & 0x200) || (j1 & 0x8)) {  // S2 button or F12
                    delay(300);
                    return 1; // Return to main menu
                }
                if (r == 1) {
                    if (strcmp(pwd, "/") == 0 && page == 0 && active == 0) {
                        // return to main menu
                        return 1;
                    } else if (file_dir[active]) {
                        if (file_names[active][0] == '.' && file_names[active][1] == '.') {
                            // return to parent dir
                            char *slash = strrchr(pwd, '/');
                            if (slash)
                                *slash = '\0';
                            if (pwd[0] == '\0') {
                                pwd[0] = '/';
                                pwd[1] = '\0';
                            }
                        } else {								// enter sub dir
                            if (strcmp(pwd, "/") != 0)
                                strncat(pwd, "/", PWD_SIZE);
                            strncat(pwd, file_alt[active], PWD_SIZE);
                        }
                        active = 0;
                        page = 0;
                        // Wait for the confirm key to be released before redrawing.
                        // Otherwise a still-held Enter immediately re-confirms on the
                        // ".." entry (active 0) and climbs up level after level.
                        while (1) {
                            int jj1, jj2;
                            joy_get(&jj1, &jj2);
                            if (!((jj1 & 0x1) || (jj1 & 0x100) ||
                                  (jj2 & 0x1) || (jj2 & 0x100)))
                                break;
                        }
                        break;
                    } else {
                        *choice = active;
                        strncpy(load_fname, pwd, sizeof(load_fname));
                        if (strcmp(pwd, "/") != 0) {
                            strncat(load_fname, "/", sizeof(load_fname));
                        }
                        strncat(load_fname, file_alt[active], sizeof(load_fname));

                        if (carts) {
                            if (load_cartridge(load_fname) == 0)
                                return 2;   // cart in SDRAM + reg_cart_mode set
                            break;          // error shown; stay in the browser
                        }

                        // Disk context. A .xex on D1: becomes the virtual boot disk.
                        char *fext = strrchr(load_fname, '.');
                        if (slot == 0 && fext && strcasecmp(fext, ".xex") == 0) {
                            if (mount_xex(load_fname) == 0)
                                return 3;   // xex on D1: — caller cold-boots it
                            break;          // error shown; stay in the browser
                        }

                        // Otherwise mount as an .atr / .xfd disk image into the drive
                        int res = mount_atr(load_fname, slot);
                        if (res != 0) {
                            uart_printf("mount %s err %d\n", load_fname, res);
                            cursor(2, 24);   // row 27 hides behind the logo
                            printf("Mount failed e%d  ", res);
                            delay(1500);
                            break;
                        }
                        return 0; // Success
                    }
                }
                if ((r == 2 || r == 4) && page < pages-1) {
                    // RIGHT arrow, or DOWN past the last item → next page
                    page++;
                    active = 0;
                    break;
                } else if (r == 3 && page > 0) {
                    // LEFT arrow → previous page (top)
                    page--;
                    active = 0;
                    break;
                } else if (r == 5 && page > 0) {
                    // UP past the first item → previous page (bottom)
                    page--;
                    active = PAGESIZE - 1;  // clamped to last entry on redraw
                    break;
                }
            }
        } else {
            status("Error opening directory");
            printf(" %d", r);
            return -1;
        }
    }
}

int load_system_roms(void) {
    FIL f;
    unsigned int br;
    int r;
    
    // Hold Atari core in reset
    reg_romload_ctrl = 1;
    delay(10);
    
    // Force cold boot on next boot
    *(volatile uint8_t *)(0x00200000 + 0x0244) = 1; // COLDST = 1
    
    // Load OS.ROM
    r = f_open(&f, "/ATARIXL.ROM", FA_READ);
    if (r != FR_OK) {
        r = f_open(&f, "/atarixl.rom", FA_READ);
    }
    if (r != FR_OK) {
        uart_printf("Failed to open OS.ROM\n");
        status("Failed to open OS.ROM");
        reg_romload_ctrl = 0;
        return (1 << 8) | r;
    }
    
    // Load OS.ROM into SDRAM at the address the Atari core's address_decoder expects:
    // SDRAM_OS_ROM_ADDR (XL/XE mode, low_memory=0) = physical 0x1F4000, at the top of
    // physical bank 0 so the RAM region below can grow to 1088 KB. Firmware addr
    // 0x003F4000 -> physical 0x1F4000 via the iosys bank-0/1 swap. Keep in sync with
    // address_decoder.vhdl.
    volatile uint8_t *os_rom_ptr = (volatile uint8_t *)0x003F4000;
    r = f_read(&f, (void *)os_rom_ptr, 16384, &br);
    f_close(&f);
    if (r != FR_OK || br != 16384) {
        uart_printf("Failed to read OS.ROM\n");
        status("Failed to read OS.ROM");
        reg_romload_ctrl = 0;
        return (2 << 8) | r;
    }
    uart_printf("OS.ROM loaded successfully (%d bytes) at SDRAM 0x1F4000\n", br);
    
    // Load BASIC.ROM
    r = f_open(&f, "/BASIC.ROM", FA_READ);
    if (r != FR_OK) {
        r = f_open(&f, "/basic.rom", FA_READ);
    }
    if (r != FR_OK) {
        uart_printf("Failed to open BASIC.ROM\n");
        status("Failed to open BASIC.ROM");
        reg_romload_ctrl = 0;
        return (3 << 8) | r;
    }
    
    // Load BASIC.ROM into SDRAM at the address the Atari core's address_decoder expects:
    // SDRAM_BASIC_ROM_ADDR (low_memory=0) = physical 0x1F0000, at the top of physical
    // bank 0 (above the 1088 KB RAM region). Firmware addr 0x003F0000 -> physical
    // 0x1F0000 via the iosys bank-0/1 swap. Keep in sync with address_decoder.vhdl.
    volatile uint8_t *basic_rom_ptr = (volatile uint8_t *)0x003F0000;
    r = f_read(&f, (void *)basic_rom_ptr, 8192, &br);
    f_close(&f);
    if (r != FR_OK || br != 8192) {
        uart_printf("Failed to read BASIC.ROM\n");
        status("Failed to read BASIC.ROM");
        reg_romload_ctrl = 0;
        return (4 << 8) | r;
    }
    uart_printf("BASIC.ROM loaded successfully (%d bytes) at SDRAM 0x1F0000\n", br);
    
    // Release reset
    reg_romload_ctrl = 0;
    status("ROMs loaded successfully");
    // Give the SD card SPI bus a moment to settle before ATR file operations resume.
    sio_delay(50);
    return 0;
}

bool sio_rx_empty(void) {
    return (reg_sio_rx_stat & 0x100) != 0;
}

void sio_init(void) {
    reg_sio_divisor = 0x5D; // divisor 93 — matches the Atari's measured bit period
                            // (the WIP regressed this to 94 / 0x5E; measured rate is 93)
    
    // Flush RX FIFO (up to 1024 bytes maximum to prevent hangs if status is stuck)
    for (int i = 0; i < 1024 && !sio_rx_empty(); i++) {
        (void)reg_sio_rx;
    }
    
    sio_cmd_idx = 0;
    sio_cmd_timeout = 0;

    dbg_last_sio_cmd = 0;
    dbg_last_sio_sector = 0;
    dbg_last_sio_status = 0;
    dbg_sio_read_count = 0;
    dbg_sio_write_count = 0;
    dbg_sio_status_count = 0;
    dbg_sio_err_count = 0;
    dbg_sio_rx_byte_count = 0;
    dbg_sio_timeout_count = 0;
    for (int i = 0; i < 12; i++) {
        dbg_rx_buf[i] = 0;
        dbg_rx_cmd_line_buf[i] = 0;
    }
    dbg_rx_buf_idx = 0;
    for (int i = 0; i < 4; i++) {
        dbg_cmd_history[i].device = 0;
        dbg_cmd_history[i].cmd = 0;
        dbg_cmd_history[i].aux1 = 0;
        dbg_cmd_history[i].aux2 = 0;
        dbg_cmd_history[i].checksum = 0;
        dbg_cmd_history[i].processed = 0;
    }
    dbg_cmd_history_idx = 0;
    dbg_sio_cmd_low_ticks = 0;
    dbg_sio_txd_low_ticks = 0;
}

void delay_us(uint32_t us) {
    uint32_t start = reg_cycle;
    uint32_t cycles = us * 27; // 27 MHz clock
    while (reg_cycle - start < cycles) {
        // busy wait
    }
}

void delay_ms(uint32_t ms) {
    delay_us(ms * 1000);
}

void sio_delay(int ms) {
    uint32_t start = time_millis();
    while (time_millis() - start < ms) {
        sio_poll();
        uart_keyboard_poll();
    }
}

void sio_tx_byte(uint8_t b) {
    while (reg_sio_tx_stat & 0x200) {
        // Wait until TX FIFO is not full
    }
    reg_sio_tx = b;
    dbg_sio_tx_count++;
}

void sio_wait_tx_empty(void) {
    // Bounded: if the p2s ever stops draining (e.g. POKEY_ENABLE stalls), this must
    // NOT hang the firmware forever, or the main loop can't service the menu key.
    uint32_t start = reg_cycle;
    while (!(reg_sio_tx_stat & 0x100)) {
        if ((uint32_t)(reg_cycle - start) > 27u * 20000u) break; // 20 ms safety cap
    }
    // Wait for the last byte to finish serializing on wire (520us @ 19200)
    delay_us(600);
}

// Wait until the Atari deasserts the SIO command line (reg_sio_diag bit13 = 1),
// i.e. the command frame is over and the computer is turning around to receive.
// Lets us send the ACK as early as possible without sending it too early (while
// the Atari is still transmitting / not yet listening). Bounded so we never hang.
void sio_wait_cmd_high(void) {
    uint32_t start = reg_cycle;
    while (((reg_sio_diag >> 13) & 1) == 0) {
        if ((uint32_t)(reg_cycle - start) > 27u * 4000u) break; // 4 ms safety cap
    }
}

// Atari SIO checksum: 8-bit sum with END-AROUND CARRY (NOT plain mod-256).
// Every overflow out of bit 7 is added back into bit 0. A plain (sum & 0xFF)
// is wrong whenever the running sum carries, which makes the Atari reject our
// STATUS/READ data frames (their sums almost always carry) -> "no disk".
static uint8_t sio_checksum(const uint8_t *buf, int len) {
    uint8_t sum = 0;
    for (int i = 0; i < len; i++) {
        uint16_t t = (uint16_t)sum + buf[i];
        sum = (uint8_t)((t & 0xFF) + (t >> 8)); // fold the carry back in
    }
    return sum;
}

int sio_rx_data_frame(uint8_t *buf, int len) {
    int idx = 0;
    uint8_t checksum = 0;
    uint32_t start_time = time_millis();
    
    while (idx < len + 1) {
        if ((time_millis() - start_time) > 1000) { // 1 second timeout
            uart_printf("rx timeout idx %d\n", idx);
            return -1;
        }
        if (!sio_rx_empty()) {
            uint16_t rx_val = reg_sio_rx;
            uint8_t byte = rx_val & 0xFF;
            uint8_t cmd_count = (rx_val >> 8) & 0x7F;
            
            if (cmd_count != 0) {
                uart_printf("cmd during rx idx %d\n", cmd_count);
                return -2;
            }
            
            if (idx < len) {
                buf[idx] = byte;
                uint16_t t = (uint16_t)checksum + byte;
                checksum = (uint8_t)((t & 0xFF) + (t >> 8)); // end-around carry
            } else {
                if (checksum == byte) {
                    return 0; // Success
                } else {
                    uart_printf("data cksum %b != %b\n", checksum, byte);
                    return -3;
                }
            }
            idx++;
        }
    }
    return -4;
}

void sio_process_command(void) {
    // NOTE: auto-baud tuning removed (T2) — it read reg_sio_divisor, which is a
    // *different* (measured-receive) register than the TX divisor it writes, and
    // could silently corrupt the TX baud. TX divisor stays fixed (set in sio_init).

    uint8_t device = sio_cmd_buf[0];
    uint8_t cmd = sio_cmd_buf[1];
    uint8_t aux1 = sio_cmd_buf[2];
    uint8_t aux2 = sio_cmd_buf[3];
    uint8_t checksum = sio_cmd_buf[4];
    
    // Verify checksum of command frame (end-around carry, same as the Atari)
    uint8_t calc_sum = sio_checksum(sio_cmd_buf, 4);
    if (calc_sum != checksum) {
        uart_printf("cmd cksum %b != %b\n", checksum, calc_sum);
        dbg_sio_err_count++;
        return;
    }
    
    // Respond to D1:/D2: (Device IDs 0x31/0x32)
    if (device != 0x31 && device != 0x32) {
        return;
    }
    int slot = device - 0x31;
    
    uint16_t sector = aux1 | (aux2 << 8);
    dbg_last_sio_cmd = cmd;
    dbg_last_sio_sector = sector;
    dbg_last_sio_status = 0;

    // Send the ACK as early as the protocol allows: wait only until the Atari
    // releases the command line (it's then turning around to receive), instead
    // of a fixed multi-ms delay. On this fast machine the ACK window is narrow,
    // so minimizing response latency is what lets the ACK land inside it.
    sio_wait_cmd_high();

    switch (cmd) {
        case 0x53: { // Status command
            dbg_sio_status_count++;
            // 1. Send ACK (with command-to-ACK SIO delay)
            delay_us(250);
            sio_tx_byte(0x41); // 'A'
            sio_wait_tx_empty();
            
            // 2. Prepare status block (4 bytes)
            uint8_t status_block[4];
            status_block[0] = 0x10; // Drive active (bit 4)
            if (atr_sector_size[slot] == 256) {
                status_block[0] |= 0x20; // Double density (bit 5)
            }
            if (atr_readonly[slot]) {
                status_block[0] |= 0x08; // Write protected (bit 3)
            }
            
            status_block[1] = 0xFF; // Hardware status
            status_block[2] = 0xE0; // Timeout
            status_block[3] = 0x00;
            
            // Calculate status block checksum (Atari end-around carry)
            uint8_t sum = sio_checksum(status_block, 4);

            // 3. Delay 1ms (ACK-to-Complete delay)
            delay_us(250);

            // 4. Send Complete (must precede the data frame for reads/status)
            sio_tx_byte(0x43); // 'C'
            sio_wait_tx_empty();

            // 5. Delay 1ms (Complete-to-Data delay)
            delay_us(250);

            // 6. Send status bytes
            for (int i = 0; i < 4; i++) {
                sio_tx_byte(status_block[i]);
            }

            // 7. Send checksum
            sio_tx_byte(sum);
            sio_wait_tx_empty();
            break;
        }
        
        case 0x52: { // Read sector command
            uart_printf("SIO RD %d\n", sector);
            dbg_sio_read_count++;
            uint8_t *sector_buf = sio_sector_buf;
            int sector_len = 128;
            
            // 1. Send ACK first to satisfy the tight 16ms command-to-ACK window
            delay_us(250);
            sio_tx_byte(0x41); // 'A' (ACK)
            sio_wait_tx_empty();
            
            // 2. Perform the slow read from the SD card (takes several milliseconds)
            int r = (slot == 0 && xex_active)
                        ? xex_read_sector(sector, sector_buf, &sector_len)
                        : atr_read_sector(slot, sector, sector_buf, &sector_len);
            if (r == 0) {
                // Calculate checksum of sector data (Atari end-around carry)
                uint8_t sum = sio_checksum(sector_buf, sector_len);

                // 3. Delay 1ms (ACK-to-Complete delay)
                delay_us(250);

                // 4. Send Complete (must precede the data frame for reads)
                sio_tx_byte(0x43); // 'C' (Complete)
                sio_wait_tx_empty();

                // 5. Delay 1ms (Complete-to-Data delay)
                delay_us(250);

                // 6. Send sector data
                for (int i = 0; i < sector_len; i++) {
                    sio_tx_byte(sector_buf[i]);
                }

                // 7. Send checksum
                sio_tx_byte(sum);
                sio_wait_tx_empty();
            } else {
                uart_printf("rd %d fail\n", sector);
                dbg_last_sio_status = r;
                dbg_sio_err_count++;
                delay_us(250);
                sio_tx_byte(0x45); // 'E' (Error)
            }
            break;
        }
        
        case 0x57:   // Write sector command (with verify)
        case 0x50: { // Write sector command (without verify)
            uart_printf("SIO WR %d\n", sector);
            dbg_sio_write_count++;
            uint8_t *sector_buf = sio_sector_buf;
            int sector_len = (atr_sector_size[slot] == 128 || sector <= 3) ? 128 : 256;

            // Send ACK (with command-to-ACK SIO delay)
            delay_us(250);
            sio_tx_byte(0x41); // 'A'
            sio_wait_tx_empty();

            // Read data frame from computer
            int r = sio_rx_data_frame(sector_buf, sector_len);
            if (r == 0) {
                // Data frame verified: ACK it IMMEDIATELY — the computer's window for
                // this ACK is tight (sub-16 ms), and the SD write + f_sync below can
                // take tens of ms (FAT update, card GC). Doing the write before the
                // ACK made the OS time out and retry, leaving multi-sector operations
                // (data+VTOC+directory) half-applied = a corrupted filesystem. The
                // slow operation belongs between ACK and 'C'/'E', which is what the
                // long OS timeout is for.
                delay_us(250);
                sio_tx_byte(0x41); // 'A'
                sio_wait_tx_empty();

                int wr = atr_readonly[slot] ? -9
                          : atr_write_sector(slot, sector, sector_buf, sector_len);
                delay_us(250);
                if (wr == 0) {
                    sio_tx_byte(0x43); // 'C'
                } else {
                    // Post-ACK failures report 'E' (OS error 144), like a real drive
                    // with a write-protected/failing disk. NAK is only valid in the
                    // ACK slot.
                    uart_printf("wr %d fail %d\n", sector, wr);
                    dbg_last_sio_status = wr;
                    dbg_sio_err_count++;
                    sio_tx_byte(0x45); // 'E'
                }
            } else {
                uart_printf("rx frame sec %d err %d\n", sector, r);
                dbg_last_sio_status = r;
                dbg_sio_err_count++;
                delay_us(250);
                sio_tx_byte(0x4E); // 'N' (NAK) — asks the OS to resend the frame
            }
            break;
        }

        case 0x21:   // Format disk (image's own geometry)
        case 0x22: { // Format enhanced/medium density (1050 ED only)
            uart_printf("SIO FORMAT %b\n", cmd);
            dbg_sio_write_count++;
            uint8_t *sector_buf = sio_sector_buf;
            int sector_len = (atr_sector_size[slot] == 256) ? 256 : 128;
            uint32_t data_size = atr_mounted[slot]
                ? f_size(&atr_file[slot]) - atr_hdr_off[slot] : 0;
            // NAK what we can't do: empty/read-only drive, or 0x22 on a non-ED
            // image (DOS 2.5 probes 0x22 and falls back to 0x21 on NAK).
            if (!atr_mounted[slot] || atr_readonly[slot] ||
                (cmd == 0x22 && data_size != 1040u * 128u)) {
                dbg_last_sio_status = -9;
                dbg_sio_err_count++;
                delay_us(250);
                sio_tx_byte(0x4E); // 'N'
                break;
            }
            delay_us(250);
            sio_tx_byte(0x41); // 'A'
            sio_wait_tx_empty();

            // Zero-fill the image (may take seconds — the OS format timeout is long).
            int r = atr_format(slot);
            if (r != 0) {
                uart_printf("Format failed (%d)\n", r);
                dbg_last_sio_status = r;
                dbg_sio_err_count++;
            }
            // 'C'/'E' + data frame: the bad-sector table, all $FF = no bad sectors.
            // The frame is sent after 'E' too — the OS reads it either way.
            memset(sector_buf, 0xFF, sector_len);
            uint8_t sum = sio_checksum(sector_buf, sector_len);
            delay_us(250);
            sio_tx_byte(r == 0 ? 0x43 : 0x45); // 'C' / 'E'
            sio_wait_tx_empty();
            delay_us(250);
            for (int i = 0; i < sector_len; i++) {
                sio_tx_byte(sector_buf[i]);
            }
            sio_tx_byte(sum);
            sio_wait_tx_empty();
            break;
        }
        
        default:
            uart_printf("SIO? %b\n", cmd);
            dbg_sio_err_count++;
            delay_us(250);
            sio_tx_byte(0x4E); // 'N' (NAK)
            break;
    }
}

// sio_poll() — call as frequently as possible from the main loop.
#ifndef SIO_SW_FALLBACK
// Phase B: hardware command-frame capture path (DEFAULT; build -DSIO_SW_FALLBACK for the
// old software-assembly path).
// The 5-byte command frame is assembled in the FPGA (sio_handler snoop); we poll a
// ready flag + seq counter, read the bytes, flush the command bytes the snoop left
// in the RX FIFO, then dispatch exactly as the software path does. The real-time SIO
// timing lives in hardware so a busy firmware loop can no longer miss a command.
static uint8_t sio_hw_last_seq = 0;
static void sio_poll_hwcapture(void) {
    if (!atr_mounted[0] && !atr_mounted[1] && !xex_active) return;

    uint32_t b = reg_siocmd_b;
    uint8_t status = (b >> 8) & 0xff;        // b0=ready b1=error b2=active b3=overrun
    uint8_t seq    = (b >> 16) & 0xff;
    if (!(status & 0x01)) return;            // no command ready
    if (seq == sio_hw_last_seq) return;      // already serviced this frame
    sio_hw_last_seq = seq;

    uint32_t a = reg_siocmd_a;
    sio_cmd_buf[0] = a & 0xff;               // device
    sio_cmd_buf[1] = (a >> 8) & 0xff;        // command
    sio_cmd_buf[2] = (a >> 16) & 0xff;       // aux1
    sio_cmd_buf[3] = (a >> 24) & 0xff;       // aux2
    sio_cmd_buf[4] = b & 0xff;               // checksum
    reg_siocmd_b = 0;                        // ack / re-arm

    // The snoop left the 5 command bytes in the RX FIFO. The data frame (for write
    // commands) only arrives after we ACK, so the FIFO holds exactly those 5 now —
    // drain them so the upcoming data phase starts clean.
    while (!sio_rx_empty()) { (void)reg_sio_rx; }

    dbg_cmd_frame_t *f = &dbg_cmd_history[dbg_cmd_history_idx];
    f->device = sio_cmd_buf[0]; f->cmd = sio_cmd_buf[1];
    f->aux1 = sio_cmd_buf[2];   f->aux2 = sio_cmd_buf[3];
    f->checksum = sio_cmd_buf[4];
    uint8_t calc = sio_checksum(sio_cmd_buf, 4);
    f->processed = (calc != f->checksum) ? 2
                 : (f->device != 0x31 && f->device != 0x32) ? 0 : 1;
    dbg_cmd_history_idx = (dbg_cmd_history_idx + 1) % 4;

    uint32_t rsp_t0 = reg_cycle;
    sio_process_command();
    dbg_resp_time_us = (uint32_t)(reg_cycle - rsp_t0) / 27;
    sio_cmd_idx = 0;
    while (!sio_rx_empty()) { (void)reg_sio_rx; }
}
#endif

// Accumulates SIO command frame bytes using cmd_count from the FIFO word:
//   cmd_count == 1..5: byte is part of a command frame (1=first, 5=checksum)
//   cmd_count == 0:    data-phase byte (handled inside sio_process_command)
// We reset if too much time passes without completing a frame (line glitch recovery).
void sio_poll(void) {
#ifndef SIO_SW_FALLBACK
    sio_poll_hwcapture();
    return;
#endif
    if (!atr_mounted[0] && !atr_mounted[1] && !xex_active) return;

    uint32_t diag = reg_sio_diag;
    if (((diag >> 13) & 1) == 0) {
        dbg_sio_cmd_low_ticks++;
    }
    if (((diag >> 12) & 1) == 0) {
        dbg_sio_txd_low_ticks++;
    }

    // Timeout: if a partial frame sits for >200 ms, reset accumulator
    if (sio_cmd_idx > 0 && (time_millis() - sio_cmd_timeout) > 200) {
        uart_printf("SIO: frame timeout, resetting (had %d bytes)\n", sio_cmd_idx);
        dbg_sio_timeout_count++;
        sio_cmd_idx = 0;
    }

    for (int i = 0; i < 256 && !sio_rx_empty(); i++) {
        uint16_t rx_val  = reg_sio_rx;
        dbg_sio_rx_byte_count++;
        uint8_t  byte      = rx_val & 0xFF;
        uint8_t  cmd_active = (rx_val >> 8) & 1;
        dbg_rx_buf[dbg_rx_buf_idx] = byte;
        dbg_rx_cmd_line_buf[dbg_rx_buf_idx] = cmd_active;
        dbg_rx_buf_idx = (dbg_rx_buf_idx + 1);
        if (dbg_rx_buf_idx >= 12) dbg_rx_buf_idx = 0;

        if (!cmd_active) {
            // Data-phase byte — not expected here; ignore
            continue;
        }

        // A command frame starts if we were idle (sio_cmd_idx == 0) or if a timeout occurred (>50ms gap)
        if (sio_cmd_idx == 0 || (time_millis() - sio_cmd_timeout) > 50) {
            sio_cmd_idx     = 0;
            sio_cmd_timeout = time_millis();
        } else {
            sio_cmd_timeout = time_millis();
        }

        // Accept byte if it's the next expected one
        if (sio_cmd_idx < 5) {
            sio_cmd_buf[sio_cmd_idx++] = byte;
        }

        if (sio_cmd_idx == 5) {
            dbg_cmd_frame_t *f = &dbg_cmd_history[dbg_cmd_history_idx];
            f->device = sio_cmd_buf[0];
            f->cmd = sio_cmd_buf[1];
            f->aux1 = sio_cmd_buf[2];
            f->aux2 = sio_cmd_buf[3];
            f->checksum = sio_cmd_buf[4];
            uint8_t calc_sum = sio_checksum(sio_cmd_buf, 4);
            if (calc_sum != f->checksum) {
                f->processed = 2; // Checksum error
            } else if (f->device != 0x31 && f->device != 0x32) {
                f->processed = 0; // Ignored (not D1)
            } else {
                f->processed = 1; // Processed
            }
            dbg_cmd_history_idx = (dbg_cmd_history_idx + 1) % 4;

            uint32_t rsp_t0 = reg_cycle;
            sio_process_command();
            dbg_resp_time_us = (uint32_t)(reg_cycle - rsp_t0) / 27;
            sio_cmd_idx = 0;

            // Anti-lag resync: the response above blocks for several ms, during
            // which the Atari may fire off command retries that pile up in the RX
            // FIFO. Those are stale — answering them puts us permanently a step
            // behind the Atari (its ACK window has already closed). Discard them
            // and let the NEXT sio_poll catch the Atari's current, fresh command.
            while (!sio_rx_empty()) { (void)reg_sio_rx; }
            break;
        }
    }
}

// Cold-boot the Atari (COLDST=1 + core reset pulse). Caller flips booted/overlay.
static void cold_boot_atari(void) {
    reg_virt_kbd_0 = 0x00000000;
    apply_machine_options();                        // RAM_SELECT stable before core leaves reset
    sio_init();
    *(volatile uint8_t *)(0x00200000 + 0x0244) = 1; // COLDST = 1 (Cold start)
    reg_romload_ctrl = 1;
    delay(20);
    reg_romload_ctrl = 0;
}

// Cold-boot the virtual XEX disk on D1: with OPTION held (BASIC disabled), then
// keep servicing SIO so the boot loader's sector reads are answered during boot.
static void cold_boot_xex(void) {
    reg_virt_kbd_0 = 0x00410000;                    // hold OPTION (disable BASIC)
    sio_init();                                     // SIO ready before the core is released
    // Use the SAME reliable sequence as the "Boot OS" menu item, which boots an attached
    // .xex correctly. load_system_roms() holds the core in reset for the full ROM reload
    // (a long, clean hold) and sets COLDST=1, then releases. The previous short
    // reg_romload_ctrl pulse (delay 20) left the attach-auto-boot intermittently stuck while
    // "Boot OS" always worked (HW-observed 2026-06-30: attach->stuck, Hard->stuck, Boot OS->loads).
    load_system_roms();
    // CRITICAL: hide the OSD before servicing the boot. The overlay MASKS inputs to the core
    // while it is on, so the held OPTION (reg_virt_kbd_0) never reaches the Atari and BASIC is
    // NOT disabled -> the .xex boots to the BASIC blue screen / loads with BASIC resident in
    // $A000-$BFFF and garbles. The "Boot OS" menu item works only because it calls overlay(0)
    // before its sio_delay(). Mirror that here.
    overlay(0);
    sio_delay(600);                                 // serve boot reads while OPTION held + UNMASKED
    reg_virt_kbd_0 = 0x00000000;                    // release OPTION
}

// Per-drive object menu (entered by selecting "Dn: <name>" on the main menu).
// Returns 0 = nothing, 1 = disk attached (*sel_idx names it), 2 = detached,
// 3 = XEX attached, 4 = new blank disk created+attached (name already copied
// into cur_name — no *sel_idx).
int menu_drive(int slot, char *cur_name, int *sel_idx) {
    int choice = 0;
    while (1) {
        clear();
        cursor(2, 9);
        printf("D%d: %s%s", slot + 1, cur_name,
               (atr_mounted[slot] && atr_readonly[slot]) ? " (RO)" : "");
        cursor(2, 11);
        print("1) Attach (.atr/.xfd/.xex)...");
        cursor(2, 12);
        print("2) New blank disk (90K)");
        cursor(2, 13);
        print("3) Detach");
        cursor(2, 14);
        print("<< Back");
        delay(300);
        for (;;) {
            uart_keyboard_poll();
            sio_poll();
            if (joy_choice(11, 4, &choice, OSD_KEY_CODE) == 1) {
                if (choice == 0) {
                    delay(300);
                    int r = menu_loadrom(sel_idx, 0, slot);
                    if (r == 0) return 1;   // ATR attached
                    if (r == 3) return 3;   // XEX attached — caller cold-boots it
                    break;                  // backed out — redraw
                } else if (choice == 1) {
                    // Unformatted image: DOS's "Format disk" works on it (SIO
                    // FORMAT is implemented) — no PC needed for a writable disk.
                    // Diagnostics print at row 24: the status line (row 27) is
                    // hidden behind the logo overlay (HW-observed).
                    cursor(2, 24);
                    print("Creating disk...");
                    char newname[16];
                    int r = create_blank_atr(slot, newname);
                    if (r == 0) {
                        strncpy(cur_name, newname, 16);
                        cur_name[15] = '\0';
                        return 4;           // attached, cur_name updated in place
                    }
                    // The slot's previous disk was detached (its FIL is the
                    // scratch) — reflect that in the shown name.
                    strncpy(cur_name, "None", 16);
                    cursor(2, 24);
                    if (r == -1) {
                        print("No free name    ");
                    } else {
                        printf("Create fail st%d e%d    ", cba_stage, cba_err);
                    }
                    delay(2500);
                    break;                  // redraw
                } else if (choice == 2) {
                    if (slot == 0 && xex_active) {   // detach a mounted XEX from D1:
                        f_close(&xex_file);
                        xex_active = false;
                        return 2;
                    }
                    if (atr_mounted[slot]) {
                        f_close(&atr_file[slot]);
                        atr_mounted[slot] = false;
                        return 2;
                    }
                    status("Drive is empty");
                    delay(500);
                    break;
                } else {
                    return 0;               // << Back
                }
            }
            int j1, j2;
            joy_get(&j1, &j2);
            if ((j1 & 0x200) || (j1 & 0x8)) { delay(300); return 0; }
        }
    }
}

// Cartridge object menu (entered by selecting "Cart: <name>" on the main menu).
// Returns 0 = nothing, 2 = cart attached (*sel_idx names it, caller cold-boots),
// 3 = cart detached (caller cold-boots).
int menu_cartridge(char *cur_name, int *sel_idx) {
    int choice = 0;
    while (1) {
        clear();
        cursor(2, 9);
        printf("Cart: %s", cur_name);
        cursor(2, 11);
        print("1) Attach cartridge...");
        cursor(2, 12);
        print("2) Detach");
        cursor(2, 13);
        print("<< Back");
        delay(300);
        for (;;) {
            uart_keyboard_poll();
            sio_poll();
            if (joy_choice(11, 3, &choice, OSD_KEY_CODE) == 1) {
                if (choice == 0) {
                    delay(300);
                    int r = menu_loadrom(sel_idx, 1, 0);
                    if (r == 2) return 2;   // attached — caller cold-boots into it
                    break;                  // backed out — redraw
                } else if (choice == 1) {
                    if (reg_cart_mode != 0) {
                        reg_cart_mode = 0;
                        return 3;           // detached — caller cold-boots
                    }
                    status("No cartridge inserted");
                    delay(500);
                    break;
                } else {
                    return 0;
                }
            }
            int j1, j2;
            joy_get(&j1, &j2);
            if ((j1 & 0x200) || (j1 & 0x8)) { delay(300); return 0; }
        }
    }
}

// Draw the RAM size value + "<- ->" hint at the menu's RAM row (col 16, row 18).
// Trailing spaces clear stale characters when the digit count shrinks (1088->128).
static void draw_ram_line(void) {
    cursor(16, 18);
    int n = ram_opts[option_ram_idx].kb; char s[6]; int k = 0, d = 1000;
    while (d > n && d > 1) d /= 10;
    while (d >= 1) { s[k++] = '0' + (n / d) % 10; d /= 10; }
    s[k] = 0;
    print(s); print("K  <- ->  ");
}

void menu_options() {
    int choice = 0;
    int options_dirty = 0;   // a change was applied live but not yet written to SD
    while (1) {
        clear();
        cursor(8, 10);
        print("--- Options ---");

        cursor(2, 12);
        print("<< Return to main menu");
        cursor(2, 13);
        print("OSD hot key:");
        cursor(16, 13);
        if (option_osd_key == OPTION_OSD_KEY_SELECT_START)
            print("SELECT&START");
        else
            print("SELECT&RIGHT");

        cursor(2, 14);
        print("Arrow keys:");
        cursor(16, 14);
        print(option_arrow_joystick ? "JOYSTICK" : "NORMAL");

        cursor(2, 15);
        print("Scanlines:");
        cursor(16, 15);
        print(option_scanline_level == 1 ? "25%" :
              option_scanline_level == 2 ? "50%" :
              option_scanline_level == 3 ? "75%" : "OFF");

        cursor(2, 16);
        print("H position:");
        cursor(16, 16);
        { char hb[8]; int n = option_h_offset; int k = 0;
          if (n >= 10) hb[k++] = '0' + (n / 10);
          hb[k++] = '0' + (n % 10); hb[k] = 0; print(hb); print("  <- ->"); }

        cursor(2, 17);
        print("Stereo:");
        cursor(16, 17);
        print(option_stereo ? "ON" : "OFF");

        cursor(2, 18);
        print("RAM:");
        draw_ram_line();

        cursor(2, 19);
        print(options_dirty ? "Save changes *" : "Save changes");

        delay(300);

        for (;;) {
            uart_keyboard_poll();
            sio_poll();   // Atari runs live behind the menu — keep disk I/O alive
            { // H position: live left/right adjust on the selected item (Save to persist)
                int jj1, jj2; joy_get(&jj1, &jj2);
                // Left arrow moves the picture LEFT (bigger offset = pan source right).
                if (choice == 4 && (jj1 & 0x40) && option_h_offset < 48) {
                    option_h_offset++; apply_video_options(); options_dirty = 1; delay(60);
                } else if (choice == 4 && (jj1 & 0x80) && option_h_offset > 0) {
                    option_h_offset--; apply_video_options(); options_dirty = 1; delay(60);
                }
                // RAM size: Left = smaller, Right = bigger (clamped). NOT applied until
                // Enter (cold boot) — just update the selection and redraw it in place.
                else if (choice == 6 && (jj1 & 0x80) && option_ram_idx < N_RAM_OPTS - 1) {
                    option_ram_idx++; options_dirty = 1; draw_ram_line(); delay(180);
                } else if (choice == 6 && (jj1 & 0x40) && option_ram_idx > 0) {
                    option_ram_idx--; options_dirty = 1; draw_ram_line(); delay(180);
                }
            }
            if (joy_choice(12, 8, &choice, OSD_KEY_CODE) == 1) {
                // Every item applies its change LIVE (so you can see it) but does NOT write
                // to SD — only "Save changes" persists. Leaving without saving keeps the
                // changes for this session; they revert to the saved values on next boot.
                if (choice == 0) {
                    return;
                } else if (choice == 1) {
                    if (option_osd_key == OPTION_OSD_KEY_SELECT_START)
                        option_osd_key = OPTION_OSD_KEY_SELECT_RIGHT;
                    else
                        option_osd_key = OPTION_OSD_KEY_SELECT_START;
                    options_dirty = 1;
                    break;	// redraw UI
                } else if (choice == 2) {
                    option_arrow_joystick = !option_arrow_joystick;
                    apply_input_options();
                    options_dirty = 1;
                    break; // redraw UI
                } else if (choice == 3) {
                    option_scanline_level = (option_scanline_level + 1) & 0x3; // OFF/25/50/75
                    apply_video_options();
                    options_dirty = 1;
                    break; // redraw UI
                } else if (choice == 4) {
                    // H position is adjusted live with Left/Right; select does nothing
                    // here (use "Save changes" to persist).
                    break; // redraw UI
                } else if (choice == 5) {
                    option_stereo = !option_stereo;   // dual-POKEY stereo on/off
                    apply_video_options();            // applies live (reg_video_opts bit 2)
                    options_dirty = 1;
                    break; // redraw UI
                } else if (choice == 6) {
                    // RAM size is chosen with Left/Right; Enter applies it. A running
                    // machine can't change RAM, so cold-boot (cold_boot_atari writes
                    // RAM_SELECT before releasing the core). Save persists it.
                    status("Rebooting with new RAM size...");
                    cold_boot_atari();
                    break; // redraw UI
                } else if (choice == 7) {
                    status("Saving options...");
                    if (save_option()) {
                        message("Cannot save options to SD", 1);
                        break;
                    }
                    options_dirty = 0;
                    status("Options saved.");
                    delay(600);
                    break; // redraw UI
                }
            }
            int j1, j2;
            joy_get(&j1, &j2);
            if ((j1 & 0x200) || (j1 & 0x8)) {  // S2 button or F12
                delay(300);
                return; // Return to main menu
            }
        }
    }
}

void test_sdram(void) {
    volatile uint32_t *ptr = (volatile uint32_t *)0x001F0000;
    
    *ptr = 0x11223344;
    uint32_t val_init = *ptr;
    
    // Byte writes
    *ptr = 0x11223344;
    *(volatile uint8_t *)0x001F0000 = 0xAA;
    uint32_t val_b0 = *ptr;
    
    *ptr = 0x11223344;
    *(volatile uint8_t *)0x001F0001 = 0xBB;
    uint32_t val_b1 = *ptr;
    
    *ptr = 0x11223344;
    *(volatile uint8_t *)0x001F0002 = 0xCC;
    uint32_t val_b2 = *ptr;
    
    *ptr = 0x11223344;
    *(volatile uint8_t *)0x001F0003 = 0xDD;
    uint32_t val_b3 = *ptr;
    
    // Half-word writes
    *ptr = 0x11223344;
    *(volatile uint16_t *)0x001F0000 = 0xAABB;
    uint32_t val_h0 = *ptr;
    
    *ptr = 0x11223344;
    *(volatile uint16_t *)0x001F0002 = 0xCCDD;
    uint32_t val_h2 = *ptr;
    
    clear();
    cursor(2, 2);
    printf("=== SDRAM DIAGNOSTIC MAP ===");
    cursor(2, 4);
    printf("Init: %x", val_init);
    cursor(2, 5);
    printf("B0  : %x", val_b0);
    cursor(2, 6);
    printf("B1  : %x", val_b1);
    cursor(2, 7);
    printf("B2  : %x", val_b2);
    cursor(2, 8);
    printf("B3  : %x", val_b3);
    cursor(2, 9);
    printf("H0  : %x", val_h0);
    cursor(2, 10);
    printf("H2  : %x", val_h2);
    
    // Hold here to let the user view the results on screen
    for(;;);
}

// Stack canary at the very bottom of the stack region (= _ebss, no heap in this
// firmware). The linker guarantees >= 4 KB between _ebss and STACK_TOP; if the
// stack ever reaches the canary it has (nearly) collided with the top of bss —
// which holds the FatFs volume pointer, atr_mounted[], the OSD cursor... (=
// exactly the "everything FS goes weird after a write" corruption pattern).
// Checked on every main-menu paint: '!' appended to the SIO debug line.
extern char _ebss[];
#define STACK_CANARY_MAGIC 0x53544B21u   // "STK!"
static inline void stack_canary_arm(void)  { *(volatile uint32_t *)_ebss = STACK_CANARY_MAGIC; }
static inline int  stack_canary_dead(void) { return *(volatile uint32_t *)_ebss != STACK_CANARY_MAGIC; }

int main() {
    stack_canary_arm();
    delay(200); // Give SD card time to stabilize power on startup
    CORE_ID = reg_core_id;
    overlay(1);

    // Initialize UART
    reg_uart_clkdiv = 234; // 27000000 / 115200;

    // Initialize SD Card
    int mounted = 0;
    while(!mounted) {
        for (int attempts = 0; attempts < 255; attempts++) {
            if (f_mount(&fs, "", 0) == FR_OK) {
                mounted = 1;
                break;
            }
        }
        if (!mounted)
            message("Insert SD card and press any key", 1);
    }

    // load_option() is the first real SD access (f_mount above is lazy). On a warm
    // reset the card is mid-state and this first read can fail transiently — retry with
    // a full remount, exactly like the ROM loader below. Without this, a glitched first
    // read silently reverts ALL options to defaults while the ROM loader still recovers,
    // i.e. "settings saved fine but boot comes up with defaults". (-1 = transient.)
    int opt_r = load_option();
    for (int attempt = 0; opt_r < 0 && attempt < 5; attempt++) {
        uart_printf("load_option failed (transient), remount+retry %d\n", attempt + 1);
        delay(50);
        f_mount(0, "", 0);                       // unmount (deinit volume)
        delay(20);
        if (f_mount(&fs, "", 0) != FR_OK) { delay(80); continue; }
        opt_r = load_option();
    }
    // Initialize USB Host enable state based on loaded option (0 = UART, 1 = USB)
    apply_input_options();
    apply_video_options();
    apply_machine_options();   // set RAM_SELECT before the core is released below
    sio_init();

    // Auto-load system ROMs on boot. On a warm reset (S1) the SD card is left
    // mid-state and FatFs reads can fail transiently (e.g. FR_INT_ERR on the 2nd
    // file). Retry with a full unmount/re-mount (resets FatFs state + forces a
    // fresh SD re-init on the next access) before giving up.
    int rom_ok = load_system_roms();
    for (int attempt = 0; rom_ok != 0 && attempt < 5; attempt++) {
        uart_printf("ROM load failed (0x%x), remount+retry %d\n", rom_ok, attempt + 1);
        delay(50);
        f_mount(0, "", 0);                       // unmount (deinit volume)
        delay(20);
        if (f_mount(&fs, "", 0) != FR_OK) { delay(80); continue; }
        rom_ok = load_system_roms();
    }
    if (rom_ok != 0) {
        clear();
        cursor(2, 2);
        printf("=== Atari 800 ROM Load Error ===");
        cursor(2, 4);
        printf("OS/BASIC.ROM loading failed.");
        cursor(2, 5);
        printf("ErrCode: 0x%w", rom_ok);
        cursor(2, 6);
        printf("  Op code: %d (1=OpOS, 2=RdOS,", rom_ok >> 8);
        cursor(2, 7);
        printf("            3=OpBas, 4=RdBas)");
        cursor(2, 8);
        printf("  FS Error: %d (9=NoFile, 5=NoPath)", rom_ok & 0xFF);
        
        cursor(2, 10);
        printf("Root dir:");
        DIR dir;
        FILINFO fno;
        int r = f_opendir(&dir, "/");
        if (r == FR_OK) {
            int line = 11;
            while (line < 22) {
                r = f_readdir(&dir, &fno);
                if (r != FR_OK || fno.fname[0] == 0) break;
                cursor(2, line++);
                printf(" - %s", fno.fname);
            }
            f_closedir(&dir);
            if (line == 11) {
                cursor(2, 11);
                printf("(Directory is empty)");
            }
        } else {
            cursor(2, 11);
            printf("Failed to open root: %x", (unsigned int)r);
            cursor(2, 12);
            printf("type: %x", (unsigned int)fs.fs_type);
            cursor(2, 13);
            printf("cls: %x", (unsigned int)fs.csize);
            cursor(2, 14);
            printf("fate: %x", (unsigned int)fs.n_fatent);
            cursor(2, 15);
            printf("db: %x", (unsigned int)fs.database);
            cursor(2, 16);
            printf("dirb: %x", (unsigned int)fs.dirbase);
        }

        cursor(2, 24);
        printf("Please check your SD card files.");
        cursor(2, 26);
        printf("Press any key to retry...");
        
        delay(300);
        for (;;) {
            int joy1, joy2;
            joy_get(&joy1, &joy2);
            if (joy1 || joy2) break;
        }
    }

    bool booted = (rom_ok == 0); // auto-boot to BASIC if ROMs loaded successfully
    int f9_prev = 0;             // F9 soft-reset hotkey edge detector
    char mounted_atr_name[ATR_DRIVES][16] = {"None", "None"};
    char mounted_cart_name[16] = "None";
    if (booted) overlay(0);      // hide OSD immediately on auto-boot

    for (;;) {
        if (!booted) {
            overlay(1);
            clear();
            cursor(2, 6);
            print("=== Tang Atari 800 ===");

            cursor(2, 8);
            printf("1) D1: %s%s", mounted_atr_name[0],
                   (atr_mounted[0] && atr_readonly[0]) ? " (RO)" : "");
            cursor(2, 9);
            printf("2) D2: %s%s", mounted_atr_name[1],
                   (atr_mounted[1] && atr_readonly[1]) ? " (RO)" : "");
            cursor(2, 10);
            printf("3) Cart: %s", mounted_cart_name);
            cursor(2, 11);
            print("4) Boot to OS (No BASIC)\n");
            cursor(2, 12);
            print("5) Boot to BASIC\n");
            cursor(2, 13);
            print("6) Soft Reset\n");
            cursor(2, 14);
            print("7) Hard Reset\n");
            cursor(2, 15);
            print("8) Options\n");
            cursor(2, 16);
            print("9) Return to Atari (F12)\n");

            // SIO triage line (uart_tx is unwired on HW — this is the only way to
            // see which branch failed): last device+cmd+sector, last status, err
            // count, and each slot's mounted flag. sio_cmd_buf[0] persists after
            // dispatch = the last serviced command's device byte.
            cursor(1, 25);
            printf("d%b c%b s%d st%d e%d m%d%d", sio_cmd_buf[0],
                   dbg_last_sio_cmd, dbg_last_sio_sector, dbg_last_sio_status,
                   dbg_sio_err_count, atr_mounted[0] ? 1 : 0, atr_mounted[1] ? 1 : 0);
            if (stack_canary_dead())
                print("!");   // stack hit bottom = bss corruption likely

            cursor(2, 26);
            print("Enter:Select   V:");
            print(__DATE__);

            delay(300);

            int choice = 0;
            for (;;) {
                uart_keyboard_poll();
                sio_poll();   // Atari runs live behind the menu — keep disk I/O alive
                int r = joy_choice(8, 9, &choice, OSD_KEY_CODE);
                if (r == 1) break;
                int j1, j2;
                joy_get(&j1, &j2);
                if ((j1 & 0x200) || (j1 & 0x8)) {  // S2 button or F12
                    booted = true;
                    overlay(0);
                    delay(300);
                    choice = -1; // Ignore choices
                    break;
                }
            }

            if (choice == 0 || choice == 1) {
                int selected_idx;
                int dslot = choice;
                delay(300);
                int r = menu_drive(dslot, mounted_atr_name[dslot], &selected_idx);
                if (r == 1) {
                    strncpy(mounted_atr_name[dslot], file_names[selected_idx], 16);
                    mounted_atr_name[dslot][15] = '\0';
                } else if (r == 2) {
                    strncpy(mounted_atr_name[dslot], "None", 16);
                } else if (r == 3) {
                    // XEX mounted on D1: as a virtual boot disk — cold-boot into it
                    strncpy(mounted_atr_name[dslot], file_names[selected_idx], 16);
                    mounted_atr_name[dslot][15] = '\0';
                    cold_boot_xex();
                    booted = true;
                    overlay(0);
                }
            } else if (choice == 2) {
                int selected_idx;
                delay(300);
                int r = menu_cartridge(mounted_cart_name, &selected_idx);
                if (r == 2) {
                    // Cartridge loaded into SDRAM + reg_cart_mode set: cold-boot into it
                    strncpy(mounted_cart_name, file_names[selected_idx], sizeof(mounted_cart_name));
                    mounted_cart_name[sizeof(mounted_cart_name)-1] = '\0';
                    cold_boot_atari();
                    booted = true;
                    overlay(0);
                } else if (r == 3) {
                    strncpy(mounted_cart_name, "None", sizeof(mounted_cart_name));
                    cold_boot_atari();
                    booted = true;
                    overlay(0);
                }
            } else if (choice == 3) {
                reg_virt_kbd_0 = 0x00410000; // Hold OPTION (F8)
                // sio_init() MUST precede load_system_roms(): the latter releases the core
                // from reset internally, and with a disk attached the OS issues D1: boot
                // commands immediately. Initialising SIO *after* the release wiped the
                // firmware's SIO state mid-transaction -> the boot read was lost and the
                // disk boot stalled (only with a disk attached). Matches cold_boot_atari().
                sio_init();
                load_system_roms();
                booted = true;
                overlay(0);
                sio_delay(400);              // Wait for boot process to read OPTION
                reg_virt_kbd_0 = 0x00000000; // Release OPTION
            } else if (choice == 4) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                sio_init();                  // before load_system_roms() releases the core (see choice 3)
                load_system_roms();
                booted = true;
                overlay(0);
            } else if (choice == 5) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                *(volatile uint8_t *)(0x00200000 + 0x0244) = 0; // COLDST = 0 (Warm start)
                reg_romload_ctrl = 1;
                delay(20);
                reg_romload_ctrl = 0;
                booted = true;
                overlay(0);
            } else if (choice == 6) {
                // Hard Reset
                cold_boot_atari();
                booted = true;
                overlay(0);
            } else if (choice == 7) {
                delay(300);
                menu_options();
            } else if (choice == 8) {
                // Return to Atari: always just dismiss the OSD, disk or not.
                booted = true;
                overlay(0);
            }
        } else {
            // Check the menu toggle key FIRST, before sio_poll — otherwise a mounted
            // disk's SIO flood keeps the loop busy in sio_poll and the OSD becomes
            // unreachable. (S2 button bit9, or F12 bit3.)
            int joy1, joy2;
            joy_get(&joy1, &joy2);
            if ((joy1 & 8) || (joy1 & 0x200) || (joy2 & 0x200)) { // START / F12 or S2 button
                booted = false;
                delay(300);
                continue;   // enter the menu now; skip SIO this iteration
            }
            // F9 = soft reset hotkey (same warm start as the menu's Soft Reset)
            int f9 = (joy1 & 0x4);
            if (f9 && !f9_prev) {
                reg_virt_kbd_0 = 0x00000000;
                *(volatile uint8_t *)(0x00200000 + 0x0244) = 0; // COLDST = 0 (warm start)
                reg_romload_ctrl = 1;
                delay(20);
                reg_romload_ctrl = 0;
                delay(300);
            }
            f9_prev = f9;

            // Background polling loop — service SIO (bounded per call).
            sio_poll();
            sio_poll();
            sio_poll();
            frame_rate_sample();   // reads reg_video_diag (a register, NOT SDRAM) — safe
            uart_keyboard_poll();
        }
    }
}

#define CH9350_STATE_IDLE 0
#define CH9350_STATE_AB   1
#define CH9350_STATE_CMD  2
#define CH9350_STATE_LEN  3
#define CH9350_STATE_DATA 4

static int ch_state = CH9350_STATE_IDLE;
static uint8_t ch_cmd = 0;
static uint8_t ch_len = 0;
static uint8_t ch_buf[16];
static uint8_t ch_idx = 0;
static uint32_t last_kbd_time = 0;

void uart_keyboard_poll(void) {
    // Process pending bytes in the UART receiver, but BOUNDED: a continuous RX
    // stream (e.g. noise on a repurposed/floating UART pin) must not spin here
    // forever, or the main loop never reaches the S2/F12 menu-key check and the
    // menu becomes unreachable. 64 bytes/call drains real CH9350 packets fine;
    // the state machine (ch_state) persists across calls.
    for (int _n = 0; _n < 64; _n++) {
        uint32_t val = reg_uart_data;
        if (val == 0xFFFFFFFF) {
            break;
        }
        uint8_t b = val & 0xFF;
        
        switch (ch_state) {
            case CH9350_STATE_IDLE:
                if (b == 0x57) {
                    ch_state = CH9350_STATE_AB;
                }
                break;
            case CH9350_STATE_AB:
                if (b == 0xAB) {
                    ch_state = CH9350_STATE_CMD;
                } else if (b != 0x57) {
                    ch_state = CH9350_STATE_IDLE;
                }
                break;
            case CH9350_STATE_CMD:
                ch_cmd = b;
                ch_state = CH9350_STATE_LEN;
                break;
            case CH9350_STATE_LEN:
                ch_len = b;
                ch_idx = 0;
                if (ch_len > 0 && ch_len <= 16) {
                    ch_state = CH9350_STATE_DATA;
                } else {
                    ch_state = CH9350_STATE_IDLE;
                }
                break;
            case CH9350_STATE_DATA:
                ch_buf[ch_idx++] = b;
                if (ch_idx >= ch_len) {
                    // Packet fully received! Verify checksum.
                    uint8_t sum = 0;
                    for (int i = 0; i < ch_len - 1; i++) {
                        sum += ch_buf[i];
                    }
                    if (sum == ch_buf[ch_len - 1]) {
                        // Checksum ok. Extract keyboard reports.
                        if ((ch_cmd == 0x88 || ch_cmd == 0x83) && ch_buf[0] == 0x10) {
                            uint8_t modifier = ch_buf[1];
                            uint8_t key1 = ch_buf[3]; // ch_buf[2] is reserved
                            uint8_t key2 = ch_buf[4];
                            uint8_t key3 = ch_buf[5];
                            uint8_t key4 = ch_buf[6];
                            
                            reg_virt_kbd_0 = modifier | (key1 << 8) | (key2 << 16) | (key3 << 24);
                            reg_virt_kbd_1 = (option_arrow_joystick ? 0x200 : 0x000) | key4;
                            last_kbd_time = time_millis();
                        }
                    }
                    ch_state = CH9350_STATE_IDLE;
                }
                break;
        }
    }

    // Safety timeout: if no keyboard packet received for 1 second, clear keys
    if (last_kbd_time != 0 && (time_millis() - last_kbd_time) > 1000) {
        reg_virt_kbd_0 = 0;
        apply_input_options();
        last_kbd_time = 0;
    }
}

void backup_process(void) {
    // Stub to satisfy picorv32 dependency
}
