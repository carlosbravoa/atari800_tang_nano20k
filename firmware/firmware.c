// Simple firmware for Tang Atari 800
// Adapted from SNESTang firmware for Atari 800 core
// Nand2mario & Google DeepMind team, 2026

#include <stdbool.h>
#include "picorv32.h"
#include "fatfs/ff.h"
#include "firmware.h"

uint32_t CORE_ID;

void uart_keyboard_poll(void);

#define OPTION_FILE "/atari.ini"
#define OPTION_INVALID 2

#define OPTION_OSD_KEY_SELECT_START 1
#define OPTION_OSD_KEY_SELECT_RIGHT 2

int option_osd_key = OPTION_OSD_KEY_SELECT_RIGHT;
int option_arrow_joystick = 0;              // 1 = arrow keys drive Joystick 1 (Left-Alt = fire)
#define OSD_KEY_CODE (option_osd_key == OPTION_OSD_KEY_SELECT_START ? 0xC : 0x84)

// Push the input-related options into the hardware config register (0xA4):
// bit 8 = USB-host-keyboard enable (permanently 0: keyboard is UART/CH9350 only),
// bit 9 = arrow-keys-as-joystick mode.
static inline void apply_input_options(void) {
    reg_virt_kbd_1 = (option_arrow_joystick ? 0x200 : 0x000);
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
FIL atr_file;
bool atr_mounted = false;
uint16_t atr_sector_size = 128;

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

// return 0: success, 1: no option file found, 2: option file corrupt
int load_option()  {
    FIL f;
    int r = 0;
    char buf[1024];
    char *line, *key, *value;
    if (f_open(&f, OPTION_FILE, FA_READ))
        return 1;
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
    }

load_option_close:
    f_close(&f);
    return r;
}

// return 0: success, 1: cannot save
int save_option() {
    FIL f;
    if (f_open(&f, OPTION_FILE, FA_READ | FA_WRITE | FA_CREATE_ALWAYS)) {
        message("f_open failed",1);
        return 1;
    }
    if (f_puts("osd_key=", &f) < 0) {
        message("f_puts failed",1);
        goto save_options_close;
    }
    if (option_osd_key == OPTION_OSD_KEY_SELECT_START)
        f_puts("1\n", &f);
    else
        f_puts("2\n", &f);

    if (f_puts("joystick=", &f) < 0) {
        message("f_puts failed",1);
        goto save_options_close;
    }
    f_puts(option_arrow_joystick ? "1\n" : "0\n", &f);

save_options_close:
    f_close(&f);
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
                    is_atr = (strcasecmp(ext, ".atr") == 0);
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
// accesses into the free 1 MB window at physical 0x600000 (= same address in the
// firmware's view), so we just f_read the image straight into SDRAM there, set
// the mapper code in reg_cart_mode, and cold-boot.
#define CART_SDRAM_BASE 0x00400000u
#define CART_MAX_SIZE   0x00200000u

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
    {60,0x13}, {64,0x2F},                                             // MegaCart 2MB
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
        message("Cartridge too large (>2MB)\ndoes not fit 8MB SDRAM", 1);
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

int mount_atr(char *filepath) {
    if (atr_mounted) {
        f_close(&atr_file);
        atr_mounted = false;
    }
    
    int r = f_open(&atr_file, filepath, FA_READ | FA_WRITE);
    if (r != FR_OK) {
        // Try read-only if write access fails
        r = f_open(&atr_file, filepath, FA_READ);
        if (r != FR_OK) {
            uart_printf("Failed to open ATR file %s, error %d\n", filepath, r);
            return r;
        }
        uart_printf("ATR file opened read-only\n");
    } else {
        uart_printf("ATR file opened read-write\n");
    }
    
    // Read ATR 16-byte header
    uint8_t header[16];
    unsigned int br;
    r = f_read(&atr_file, header, 16, &br);
    if (r != FR_OK || br != 16) {
        uart_printf("Failed to read ATR header, error %d\n", r);
        f_close(&atr_file);
        return -1;
    }
    
    // Verify magic
    uint16_t magic = header[0] | (header[1] << 8);
    if (magic != 0x0296) {
        uart_printf("Invalid ATR magic: %04x\n", magic);
        f_close(&atr_file);
        return -2;
    }
    
    atr_sector_size = header[4] | (header[5] << 8);
    if (atr_sector_size != 128 && atr_sector_size != 256) {
        uart_printf("Unsupported sector size: %d\n", atr_sector_size);
        f_close(&atr_file);
        return -3;
    }
    
    uart_printf("Mounted ATR: %s, sector size: %d\n", filepath, atr_sector_size);
    atr_mounted = true;
    return 0;
}

int atr_read_sector(uint32_t sector_num, uint8_t *buf, int *sector_len) {
    if (!atr_mounted) return -1;
    
    uint32_t offset = 0;
    int len = 128;
    if (atr_sector_size == 128) {
        offset = 16 + (sector_num - 1) * 128;
        len = 128;
    } else { // 256 bytes
        if (sector_num <= 3) {
            offset = 16 + (sector_num - 1) * 128;
            len = 128;
        } else {
            offset = 400 + (sector_num - 4) * 256;
            len = 256;
        }
    }
    
    *sector_len = len;
    
    int r = f_lseek(&atr_file, offset);
    if (r != FR_OK) {
        uart_printf("Read sector seek failed for sector %d (offset %d)\n", sector_num, offset);
        return r;
    }
    
    unsigned int br;
    r = f_read(&atr_file, buf, len, &br);
    if (r != FR_OK || br != len) {
        uart_printf("Read sector read failed for sector %d, got %d bytes\n", sector_num, br);
        return -2;
    }
    
    return 0;
}

int atr_write_sector(uint32_t sector_num, const uint8_t *buf, int len) {
    if (!atr_mounted) return -1;
    
    uint32_t offset = 0;
    if (atr_sector_size == 128) {
        offset = 16 + (sector_num - 1) * 128;
    } else { // 256 bytes
        if (sector_num <= 3) {
            offset = 16 + (sector_num - 1) * 128;
        } else {
            offset = 400 + (sector_num - 4) * 256;
        }
    }
    
    int r = f_lseek(&atr_file, offset);
    if (r != FR_OK) {
        uart_printf("Write sector seek failed for sector %d (offset %d)\n", sector_num, offset);
        return r;
    }
    
    unsigned int bw;
    r = f_write(&atr_file, buf, len, &bw);
    if (r != FR_OK || bw != len) {
        uart_printf("Write sector write failed for sector %d, wrote %d bytes\n", sector_num, bw);
        return -2;
    }
    
    f_sync(&atr_file);
    return 0;
}

// return 0: user chose a ROM (*choice), 1: no choice made, -1: error
int menu_loadrom(int *choice, int carts) {
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

                        // Disk context: mount as an ATR disk image
                        int res = mount_atr(load_fname);
                        if (res != 0) {
                            char errmsg[64];
                            // Show path (up to 28 chars) and error code
                            int plen = strlen(load_fname);
                            if (plen > 28) {
                                // show tail of path
                                uart_printf("Cannot mount ATR '%s', err=%d\n", load_fname, res);
                                char tmp[32];
                                strncpy(tmp, load_fname + plen - 24, 24);
                                tmp[24] = '\0';
                                // format: "...tail err=N"
                                char msg2[48];
                                strncpy(msg2, "...", 48);
                                strncat(msg2, tmp, 48);
                                strncat(msg2, "\nerr=", 48);
                                // append number
                                int n = res < 0 ? -res : res;
                                char num[8]; int ni = 6; num[7] = '\0';
                                if (n == 0) { num[6] = '0'; ni = 6; }
                                else { while (n > 0) { num[ni--] = '0' + (n % 10); n /= 10; } ni++; }
                                strncat(msg2, num + ni, 48);
                                message(msg2, 1);
                            } else {
                                uart_printf("Cannot mount ATR '%s', err=%d\n", load_fname, res);
                                message("Cannot mount ATR\nerr check UART", 1);
                            }
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
    // SDRAM_OS_ROM_ADDR (XL/XE mode, low_memory=0) = 0x704000
    // See gw2ar_sdram.sv header and address_decoder.vhdl line 913-914.
    volatile uint8_t *os_rom_ptr = (volatile uint8_t *)0x00704000;
    r = f_read(&f, (void *)os_rom_ptr, 16384, &br);
    f_close(&f);
    if (r != FR_OK || br != 16384) {
        uart_printf("Failed to read OS.ROM\n");
        status("Failed to read OS.ROM");
        reg_romload_ctrl = 0;
        return (2 << 8) | r;
    }
    uart_printf("OS.ROM loaded successfully (%d bytes) at SDRAM 0x704000\n", br);
    
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
    // SDRAM_BASIC_ROM_ADDR (low_memory=0) = 0x700000
    // See gw2ar_sdram.sv header and address_decoder.vhdl line 912.
    volatile uint8_t *basic_rom_ptr = (volatile uint8_t *)0x00700000;
    r = f_read(&f, (void *)basic_rom_ptr, 8192, &br);
    f_close(&f);
    if (r != FR_OK || br != 8192) {
        uart_printf("Failed to read BASIC.ROM\n");
        status("Failed to read BASIC.ROM");
        reg_romload_ctrl = 0;
        return (4 << 8) | r;
    }
    uart_printf("BASIC.ROM loaded successfully (%d bytes) at SDRAM 0x700000\n", br);
    
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
            uart_printf("Timeout waiting for data frame at index %d\n", idx);
            return -1;
        }
        if (!sio_rx_empty()) {
            uint16_t rx_val = reg_sio_rx;
            uint8_t byte = rx_val & 0xFF;
            uint8_t cmd_count = (rx_val >> 8) & 0x7F;
            
            if (cmd_count != 0) {
                uart_printf("Error: got cmd_count=%d during data frame rx\n", cmd_count);
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
                    uart_printf("Checksum error: calculated %02x, got %02x\n", checksum, byte);
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
        uart_printf("SIO Command Checksum Error: got %02x, calculated %02x\n", checksum, calc_sum);
        dbg_sio_err_count++;
        return;
    }
    
    // Only respond to D1: (Device ID 0x31)
    if (device != 0x31) {
        return;
    }
    
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
            uart_printf("SIO STATUS\n");
            dbg_sio_status_count++;
            // 1. Send ACK (with command-to-ACK SIO delay)
            delay_us(250);
            sio_tx_byte(0x41); // 'A'
            sio_wait_tx_empty();
            
            // 2. Prepare status block (4 bytes)
            uint8_t status_block[4];
            status_block[0] = 0x10; // Drive active (bit 4)
            if (atr_sector_size == 256) {
                status_block[0] |= 0x20; // Double density (bit 5)
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
            uart_printf("SIO READ SECTOR %d\n", sector);
            dbg_sio_read_count++;
            uint8_t *sector_buf = sio_sector_buf;
            int sector_len = 128;
            
            // 1. Send ACK first to satisfy the tight 16ms command-to-ACK window
            delay_us(250);
            sio_tx_byte(0x41); // 'A' (ACK)
            sio_wait_tx_empty();
            
            // 2. Perform the slow read from the SD card (takes several milliseconds)
            int r = atr_read_sector(sector, sector_buf, &sector_len);
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
                uart_printf("Read sector %d failed, sending Error\n", sector);
                dbg_last_sio_status = r;
                dbg_sio_err_count++;
                delay_us(250);
                sio_tx_byte(0x45); // 'E' (Error)
            }
            break;
        }
        
        case 0x57:   // Write sector command (with verify)
        case 0x50: { // Write sector command (without verify)
            uart_printf("SIO WRITE SECTOR %d\n", sector);
            dbg_sio_write_count++;
            uint8_t *sector_buf = sio_sector_buf;
            int sector_len = (atr_sector_size == 128 || sector <= 3) ? 128 : 256;
            
            // Send ACK (with command-to-ACK SIO delay)
            delay_us(250);
            sio_tx_byte(0x41); // 'A'
            sio_wait_tx_empty();
            
            // Read data frame from computer
            int r = sio_rx_data_frame(sector_buf, sector_len);
            if (r == 0) {
                int wr = atr_write_sector(sector, sector_buf, sector_len);
                if (wr == 0) {
                    // Send ACK for data frame (with data-to-ACK SIO delay)
                    delay_us(250);
                    sio_tx_byte(0x41); // 'A'
                    sio_wait_tx_empty();
                    
                    delay_us(250);
                    // Send Complete
                    sio_tx_byte(0x43); // 'C'
                } else {
                    uart_printf("Write sector %d failed, sending NAK\n", sector);
                    dbg_last_sio_status = wr;
                    dbg_sio_err_count++;
                    delay_us(250);
                    sio_tx_byte(0x4E); // 'N' (NAK)
                }
            } else {
                uart_printf("Receiving data frame for sector %d failed (error %d), sending NAK\n", sector, r);
                dbg_last_sio_status = r;
                dbg_sio_err_count++;
                delay_us(250);
                sio_tx_byte(0x4E); // 'N' (NAK)
            }
            break;
        }
        
        default:
            uart_printf("SIO Unknown Command: %02x\n", cmd);
            dbg_sio_err_count++;
            delay_us(250);
            sio_tx_byte(0x4E); // 'N' (NAK)
            break;
    }
}

// sio_poll() — call as frequently as possible from the main loop.
// Accumulates SIO command frame bytes using cmd_count from the FIFO word:
//   cmd_count == 1..5: byte is part of a command frame (1=first, 5=checksum)
//   cmd_count == 0:    data-phase byte (handled inside sio_process_command)
// We reset if too much time passes without completing a frame (line glitch recovery).
void sio_poll(void) {
    if (!atr_mounted) return;

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
            } else if (f->device != 0x31) {
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
    sio_init();
    *(volatile uint8_t *)(0x00200000 + 0x0244) = 1; // COLDST = 1 (Cold start)
    reg_romload_ctrl = 1;
    delay(20);
    reg_romload_ctrl = 0;
}

// Disk submenu. Returns 0 = nothing, 1 = disk mounted (*sel_idx names it),
// 2 = disk unmounted.
int menu_disk(int *sel_idx) {
    int choice = 0;
    while (1) {
        clear();
        cursor(8, 10);
        print("--- Disk ---");
        cursor(2, 12);
        print("1) Mount Disk (ATR)");
        cursor(2, 13);
        print("2) Unmount Disk");
        cursor(2, 14);
        print("<< Back");
        delay(300);
        for (;;) {
            uart_keyboard_poll();
            sio_poll();
            if (joy_choice(12, 3, &choice, OSD_KEY_CODE) == 1) {
                if (choice == 0) {
                    delay(300);
                    int r = menu_loadrom(sel_idx, 0);
                    if (r == 0) return 1;   // mounted
                    break;                  // backed out — redraw submenu
                } else if (choice == 1) {
                    if (atr_mounted) {
                        f_close(&atr_file);
                        atr_mounted = false;
                        return 2;
                    }
                    status("No disk mounted");
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

// Cartridge submenu. Returns 0 = nothing, 2 = cart loaded (*sel_idx names it,
// caller cold-boots), 3 = cart removed (caller cold-boots).
int menu_cartridge(int *sel_idx) {
    int choice = 0;
    while (1) {
        clear();
        cursor(7, 10);
        print("--- Cartridge ---");
        cursor(2, 12);
        print("1) Load Cartridge (CAR/ROM)");
        cursor(2, 13);
        print("2) Remove Cartridge");
        cursor(2, 14);
        print("<< Back");
        delay(300);
        for (;;) {
            uart_keyboard_poll();
            sio_poll();
            if (joy_choice(12, 3, &choice, OSD_KEY_CODE) == 1) {
                if (choice == 0) {
                    delay(300);
                    int r = menu_loadrom(sel_idx, 1);
                    if (r == 2) return 2;   // loaded — caller cold-boots into it
                    break;                  // backed out — redraw submenu
                } else if (choice == 1) {
                    if (reg_cart_mode != 0) {
                        reg_cart_mode = 0;
                        return 3;           // removed — caller cold-boots
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

void menu_options() {
    int choice = 0;
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

        delay(300);

        for (;;) {
            uart_keyboard_poll();
            sio_poll();   // Atari runs live behind the menu — keep disk I/O alive
            if (joy_choice(12, 3, &choice, OSD_KEY_CODE) == 1) {
                if (choice == 0) {
                    return;
                } else if (choice == 1) {
                    if (option_osd_key == OPTION_OSD_KEY_SELECT_START)
                        option_osd_key = OPTION_OSD_KEY_SELECT_RIGHT;
                    else
                        option_osd_key = OPTION_OSD_KEY_SELECT_START;
                    
                    status("Saving options...");
                    if (save_option()) {
                        message("Cannot save options to SD", 1);
                        break;
                    }
                    break;	// redraw UI
                } else if (choice == 2) {
                    option_arrow_joystick = !option_arrow_joystick;
                    apply_input_options();

                    status("Saving options...");
                    if (save_option()) {
                        message("Cannot save options to SD", 1);
                        break;
                    }
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

int main() {
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

    load_option();
    // Initialize USB Host enable state based on loaded option (0 = UART, 1 = USB)
    apply_input_options();
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
        printf("Combined ErrCode: 0x%w", rom_ok);
        cursor(2, 6);
        printf("  Op code: %d (1=OpOS, 2=RdOS,", rom_ok >> 8);
        cursor(2, 7);
        printf("            3=OpBas, 4=RdBas)");
        cursor(2, 8);
        printf("  FS Error: %d (9=NoFile, 5=NoPath)", rom_ok & 0xFF);
        
        cursor(2, 10);
        printf("Listing root directory:");
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
    char mounted_atr_name[16] = "None";
    char mounted_cart_name[16] = "None";
    if (booted) overlay(0);      // hide OSD immediately on auto-boot

    for (;;) {
        if (!booted) {
            overlay(1);
            clear();
            cursor(2, 6);
            print("=== Tang Atari 800 ===");

            cursor(2, 8);
            printf("Mounted: %s", mounted_atr_name);
            cursor(2, 9);
            printf("Cart: %s", mounted_cart_name);

            cursor(2, 10);
            print("1) Disk...\n");
            cursor(2, 11);
            print("2) Cartridge...\n");
            cursor(2, 12);
            print("3) Boot to OS (No BASIC)\n");
            cursor(2, 13);
            print("4) Boot to BASIC\n");
            cursor(2, 14);
            print("5) Soft Reset\n");
            cursor(2, 15);
            print("6) Hard Reset\n");
            cursor(2, 16);
            print("7) Options\n");
            cursor(2, 17);
            print("8) Return to Atari (F12)\n");

            cursor(2, 26);
            print("Enter:Select   V:");
            print(__DATE__);

            delay(300);

            int choice = 0;
            for (;;) {
                uart_keyboard_poll();
                sio_poll();   // Atari runs live behind the menu — keep disk I/O alive
                int r = joy_choice(10, 8, &choice, OSD_KEY_CODE);
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

            if (choice == 0) {
                int selected_idx;
                delay(300);
                int r = menu_disk(&selected_idx);
                if (r == 1) {
                    strncpy(mounted_atr_name, file_names[selected_idx], sizeof(mounted_atr_name));
                    mounted_atr_name[sizeof(mounted_atr_name)-1] = '\0';
                } else if (r == 2) {
                    strncpy(mounted_atr_name, "None", sizeof(mounted_atr_name));
                }
            } else if (choice == 1) {
                int selected_idx;
                delay(300);
                int r = menu_cartridge(&selected_idx);
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
            } else if (choice == 2) {
                reg_virt_kbd_0 = 0x00410000; // Hold OPTION (F8)
                load_system_roms();
                sio_init();
                booted = true;
                overlay(0);
                sio_delay(400);              // Wait for boot process to read OPTION
                reg_virt_kbd_0 = 0x00000000; // Release OPTION
            } else if (choice == 3) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                load_system_roms();
                sio_init();
                booted = true;
                overlay(0);
            } else if (choice == 4) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                *(volatile uint8_t *)(0x00200000 + 0x0244) = 0; // COLDST = 0 (Warm start)
                reg_romload_ctrl = 1;
                delay(20);
                reg_romload_ctrl = 0;
                booted = true;
                overlay(0);
            } else if (choice == 5) {
                // Hard Reset
                cold_boot_atari();
                booted = true;
                overlay(0);
            } else if (choice == 6) {
                delay(300);
                menu_options();
            } else if (choice == 7) {
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
