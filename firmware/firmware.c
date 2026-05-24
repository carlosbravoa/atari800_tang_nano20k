// Simple firmware for Tang Atari 800
// Adapted from SNESTang firmware for Atari 800 core
// Nand2mario & Google DeepMind team, 2026

#include <stdbool.h>
#include "picorv32.h"
#include "fatfs/ff.h"
#include "firmware.h"

uint32_t CORE_ID;

#define OPTION_FILE "/atari.ini"
#define OPTION_INVALID 2

#define OPTION_OSD_KEY_SELECT_START 1
#define OPTION_OSD_KEY_SELECT_RIGHT 2

int option_osd_key = OPTION_OSD_KEY_SELECT_RIGHT;
#define OPTION_KBD_USB   1
#define OPTION_KBD_UART  2
int option_keyboard_type = OPTION_KBD_UART; // Default to UART keyboard
#define OSD_KEY_CODE (option_osd_key == OPTION_OSD_KEY_SELECT_START ? 0xC : 0x84)

char load_fname[1024];
char load_buf[1024];

FATFS fs;

#define PAGESIZE 22
#define TOPLINE 2
#define PWD_SIZE 1024

char pwd[PWD_SIZE];		// total path length 1023
// one page of file names to display
char file_names[PAGESIZE][256];
int file_dir[PAGESIZE];
int file_sizes[PAGESIZE];
int file_len;		// number of files on this page

// ATR Disk Emulator state
FIL atr_file;
bool atr_mounted = false;
uint16_t atr_sector_size = 128;

static uint8_t sio_cmd_buf[5];
static int     sio_cmd_idx = 0;
static uint32_t sio_cmd_timeout = 0;   // millis timestamp of first byte in current frame

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
        if (strcmp(key, "keyboard") == 0) {
            option_keyboard_type = atoi(value);
            if (option_keyboard_type != OPTION_KBD_USB && option_keyboard_type != OPTION_KBD_UART) {
                option_keyboard_type = OPTION_KBD_UART;
            }
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

    if (f_puts("keyboard=", &f) < 0) {
        message("f_puts failed",1);
        goto save_options_close;
    }
    if (option_keyboard_type == OPTION_KBD_USB)
        f_puts("1\n", &f);
    else
        f_puts("2\n", &f);
        
save_options_close:
    f_close(&f);
    f_chmod(OPTION_FILE, AM_HID, AM_HID);
    return 0;
}

// starting from `start`, load `len` file names into file_names, file_dir. 
// *count is set to number of all valid entries and `file_len` is
// set to valid entries on this page.
// return: 0 if successful
int load_dir(char *dir, int start, int len, int *count) {
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
            strncpy(file_names[0], "<< Return to main menu", 256);
            file_dir[0] = 0;
        } else {
            strncpy(file_names[0], "..", 256);
            file_dir[0] = 1;
        }
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
        int is_atr = 0;
        if (!is_dir) {
            char *ext = strrchr(fno.fname, '.');
            if (ext && (strcasecmp(ext, ".atr") == 0)) {
                is_atr = 1;
            }
        }

        // Print debug information to UART
        uart_printf("Found: '%s' (is_dir=%d, is_atr=%d, size=%d)\n", fno.fname, is_dir, is_atr, (int)fno.fsize);

        if (is_dir || is_atr) {
            if (cnt >= start && file_len < len) {
                strncpy(file_names[file_len], fno.fname, 256);
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
int menu_loadrom(int *choice) {
    int page = 0, pages, total;
    int active = 0;
    pwd[0] = '/';
    pwd[1] = '\0';
    while (1) {
        clear();
        int r = load_dir(pwd, page*PAGESIZE, PAGESIZE, &total);
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
                int r = joy_choice(TOPLINE, file_len, &active, OSD_KEY_CODE);
                int j1, j2;
                joy_get(&j1, &j2);
                if (j1 & 0x200) {
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
                            strncat(pwd, file_names[active], PWD_SIZE);
                        }
                        active = 0;
                        page = 0;
                        break;
                    } else {
                        // Mount the ATR file
                        *choice = active;
                        strncpy(load_fname, pwd, 1024);
                        if (strcmp(pwd, "/") != 0) {
                            strncat(load_fname, "/", 1024);
                        }
                        strncat(load_fname, file_names[active], 1024);
                        
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
                if (r == 2 && page < pages-1) {
                    page++;
                    break;
                } else if (r == 3 && page > 0) {
                    page--;
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
    r = f_open(&f, "/OS.ROM", FA_READ);
    if (r != FR_OK) {
        r = f_open(&f, "/os.rom", FA_READ);
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
    delay(50);
    return 0;
}

bool sio_rx_empty(void) {
    return (reg_sio_rx_stat & 0x100) != 0;
}

void sio_init(void) {
    reg_sio_divisor = 0x28; // divisor for default 19200 bps
    
    // Flush RX FIFO
    while (!sio_rx_empty()) {
        (void)reg_sio_rx;
    }
    
    sio_cmd_idx = 0;
    sio_cmd_timeout = 0;
}

void sio_tx_byte(uint8_t b) {
    while (reg_sio_tx_stat & 0x200) {
        // Wait until TX FIFO is not full
    }
    reg_sio_tx = b;
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
                checksum += byte;
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
    uint8_t device = sio_cmd_buf[0];
    uint8_t cmd = sio_cmd_buf[1];
    uint8_t aux1 = sio_cmd_buf[2];
    uint8_t aux2 = sio_cmd_buf[3];
    uint8_t checksum = sio_cmd_buf[4];
    
    // Verify checksum of command frame
    uint8_t calc_sum = (device + cmd + aux1 + aux2) & 0xFF;
    if (calc_sum != checksum) {
        uart_printf("SIO Command Checksum Error: got %02x, calculated %02x\n", checksum, calc_sum);
        return;
    }
    
    // Only respond to D1: (Device ID 0x31)
    if (device != 0x31) {
        return;
    }
    
    uint16_t sector = aux1 | (aux2 << 8);
    
    switch (cmd) {
        case 0x53: { // Status command
            uart_printf("SIO STATUS\n");
            // 1. Send ACK
            sio_tx_byte(0x41); // 'A'
            
            // 2. Prepare status block (4 bytes)
            uint8_t status_block[4];
            status_block[0] = 0x08; // Active/mounted (bit 3)
            if (atr_sector_size == 256) {
                status_block[0] |= 0x04; // Double density (bit 2)
            }
            
            status_block[1] = 0xFF; // Hardware status
            status_block[2] = 0xE0; // Timeout
            status_block[3] = 0x00;
            
            // Calculate status block checksum
            uint8_t sum = 0;
            for (int i = 0; i < 4; i++) {
                sum += status_block[i];
            }
            
            // 3. Delay 1ms
            delay(1);
            
            // 4. Send Complete
            sio_tx_byte(0x43); // 'C'
            
            // 5. Send status bytes
            for (int i = 0; i < 4; i++) {
                sio_tx_byte(status_block[i]);
            }
            
            // 6. Send checksum
            sio_tx_byte(sum);
            break;
        }
        
        case 0x52: { // Read sector command
            uart_printf("SIO READ SECTOR %d\n", sector);
            static uint8_t sector_buf[256];
            int sector_len = 128;
            
            int r = atr_read_sector(sector, sector_buf, &sector_len);
            if (r == 0) {
                // Send ACK
                sio_tx_byte(0x41); // 'A'
                
                // Calculate checksum of sector data
                uint8_t sum = 0;
                for (int i = 0; i < sector_len; i++) {
                    sum += sector_buf[i];
                }
                
                // Delay 1ms
                delay(1);
                
                // Send Complete
                sio_tx_byte(0x43); // 'C'
                
                // Send sector data
                for (int i = 0; i < sector_len; i++) {
                    sio_tx_byte(sector_buf[i]);
                }
                
                // Send checksum
                sio_tx_byte(sum);
            } else {
                uart_printf("Read sector %d failed, sending NAK\n", sector);
                sio_tx_byte(0x4E); // 'N' (NAK)
            }
            break;
        }
        
        case 0x57:   // Write sector command (with verify)
        case 0x50: { // Write sector command (without verify)
            uart_printf("SIO WRITE SECTOR %d\n", sector);
            static uint8_t sector_buf[256];
            int sector_len = (atr_sector_size == 128 || sector <= 3) ? 128 : 256;
            
            // Send ACK
            sio_tx_byte(0x41); // 'A'
            
            // Read data frame from computer
            int r = sio_rx_data_frame(sector_buf, sector_len);
            if (r == 0) {
                int wr = atr_write_sector(sector, sector_buf, sector_len);
                if (wr == 0) {
                    // Send ACK for data frame
                    sio_tx_byte(0x41); // 'A'
                    delay(1);
                    // Send Complete
                    sio_tx_byte(0x43); // 'C'
                } else {
                    uart_printf("Write sector %d failed, sending NAK\n", sector);
                    sio_tx_byte(0x4E); // 'N' (NAK)
                }
            } else {
                uart_printf("Receiving data frame for sector %d failed (error %d), sending NAK\n", sector, r);
                sio_tx_byte(0x4E); // 'N' (NAK)
            }
            break;
        }
        
        default:
            uart_printf("SIO Unknown Command: %02x\n", cmd);
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

    // Timeout: if a partial frame sits for >200 ms, reset accumulator
    if (sio_cmd_idx > 0 && (time_millis() - sio_cmd_timeout) > 200) {
        uart_printf("SIO: frame timeout, resetting (had %d bytes)\n", sio_cmd_idx);
        sio_cmd_idx = 0;
    }

    while (!sio_rx_empty()) {
        uint16_t rx_val  = reg_sio_rx;
        uint8_t  byte      = rx_val & 0xFF;
        uint8_t  cmd_count = (rx_val >> 8) & 0x7F;

        if (cmd_count == 0) {
            // Data-phase byte — not expected here; ignore
            continue;
        }

        // cmd_count == 1 means start of a new 5-byte command frame
        if (cmd_count == 1) {
            sio_cmd_idx     = 0;
            sio_cmd_timeout = time_millis();
        }

        // Accept byte if it's the next expected one
        if (sio_cmd_idx < 5) {
            sio_cmd_buf[sio_cmd_idx++] = byte;
        }

        if (sio_cmd_idx == 5) {
            sio_process_command();
            sio_cmd_idx = 0;
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
        cursor(2, 14);
        print("OSD hot key:");
        cursor(16, 14);
        if (option_osd_key == OPTION_OSD_KEY_SELECT_START)
            print("SELECT&START");
        else
            print("SELECT&RIGHT");

        cursor(2, 16);
        print("Keyboard:");
        cursor(16, 16);
        if (option_keyboard_type == OPTION_KBD_USB)
            print("USB");
        else
            print("UART");

        delay(300);

        for (;;) {
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
                    if (option_keyboard_type == OPTION_KBD_USB)
                        option_keyboard_type = OPTION_KBD_UART;
                    else
                        option_keyboard_type = OPTION_KBD_USB;
                    
                    // Update the hardware register immediately
                    reg_virt_kbd_1 = (option_keyboard_type == OPTION_KBD_USB ? 0x100 : 0x000);
                    
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
            if (j1 & 0x200) {
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
    reg_virt_kbd_1 = (option_keyboard_type == OPTION_KBD_USB ? 0x100 : 0x000);
    sio_init();

    // Auto-load system ROMs on boot
    int rom_ok = load_system_roms();
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

    bool booted = false;
    char mounted_atr_name[256] = "None";

    for (;;) {
        if (!booted) {
            overlay(1);
            clear();
            cursor(2, 6);
            print("=== Tang Atari 800 ===");

            cursor(2, 8);
            printf("Mounted: %s", mounted_atr_name);

            cursor(2, 10);
            print("1) Select ATR Disk Image\n");
            cursor(2, 11);
            print("2) Boot (No BASIC)\n");
            cursor(2, 12);
            print("3) Boot to BASIC\n");
            cursor(2, 13);
            print("4) Soft Reset\n");
            cursor(2, 14);
            print("5) Hard Reset\n");
            cursor(2, 15);
            print("6) Options\n");
            cursor(2, 16);
            print("7) Return to Game (F12)\n");

            cursor(2, 18);
            print("Press Enter to select");

            cursor(2, 20);
            print("Version: ");
            print(__DATE__);

            delay(300);

            int choice = 0;
            for (;;) {
                int r = joy_choice(10, 7, &choice, OSD_KEY_CODE);
                if (r == 1) break;
                int j1, j2;
                joy_get(&j1, &j2);
                if (j1 & 0x200) {
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
                int load_ok = menu_loadrom(&selected_idx);
                if (load_ok == 0) {
                    strncpy(mounted_atr_name, file_names[selected_idx], 256);
                    load_system_roms();
                    sio_init();    // flush stale SIO bytes accumulated during ROM load / core reset
                    booted = true;
                    overlay(0);
                }
            } else if (choice == 1) {
                reg_virt_kbd_0 = 0x00410000; // Hold OPTION (F8)
                load_system_roms();
                sio_init();
                booted = true;
                overlay(0);
                delay(400);                  // Wait for boot process to read OPTION
                reg_virt_kbd_0 = 0x00000000; // Release OPTION
            } else if (choice == 2) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                load_system_roms();
                sio_init();
                booted = true;
                overlay(0);
            } else if (choice == 3) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                *(volatile uint8_t *)(0x00200000 + 0x0244) = 0; // COLDST = 0 (Warm start)
                reg_romload_ctrl = 1;
                delay(20);
                reg_romload_ctrl = 0;
                booted = true;
                overlay(0);
            } else if (choice == 4) {
                reg_virt_kbd_0 = 0x00000000; // Ensure OPTION released
                *(volatile uint8_t *)(0x00200000 + 0x0244) = 1; // COLDST = 1 (Cold start)
                reg_romload_ctrl = 1;
                delay(20);
                reg_romload_ctrl = 0;
                booted = true;
                overlay(0);
            } else if (choice == 5) {
                delay(300);
                menu_options();
            } else if (choice == 6) {
                if (atr_mounted || booted) {
                    booted = true;
                    overlay(0);
                } else {
                    message("No disk mounted yet!", 1);
                }
            }
        } else {
            // Background polling loop — call sio_poll as fast as possible.
            // Also poll for menu toggle key (S2 or F12) without heavy delays.
            sio_poll();
            sio_poll();
            sio_poll();

            // Check for menu toggle (S2 button bit9, or F12 bit3)
            int joy1, joy2;
            joy_get(&joy1, &joy2);
            if ((joy1 & 8) || (joy1 & 0x200) || (joy2 & 0x200)) { // START / F12 or S2 button
                booted = false;
                delay(300);
            }
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
    // Process all pending bytes in the UART receiver
    for (;;) {
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
                            reg_virt_kbd_1 = (option_keyboard_type == OPTION_KBD_USB ? 0x100 : 0x000) | key4;
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
        reg_virt_kbd_1 = (option_keyboard_type == OPTION_KBD_USB ? 0x100 : 0x000);
        last_kbd_time = 0;
    }
}

void backup_process(void) {
    // Stub to satisfy picorv32 dependency
}
