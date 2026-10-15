/* Host harness around the firmware's EXACT disk-layer code (fw_fs_extracted.c,
 * regenerated from firmware/firmware.c at every build).
 *
 * Each subcommand is a complete scenario (state does not persist across runs).
 * run_tests.sh drives these against fresh mkfs.vfat images and fsck.fat's the
 * image after every scenario — the property under test is "no sequence of
 * firmware disk operations may damage the VOLUME".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include "ff.h"

int diskio_host_open(const char *path);

/* ── firmware globals the extracted functions expect ─────────────────────── */
#define ATR_DRIVES 4
FIL atr_file[ATR_DRIVES];
bool atr_mounted[ATR_DRIVES] = {false, false, false, false};
bool atr_readonly[ATR_DRIVES] = {false, false, false, false};
uint16_t atr_sector_size[ATR_DRIVES] = {128, 128, 128, 128};
uint16_t atr_hdr_off[ATR_DRIVES] = {16, 16, 16, 16};
bool atr_dd_fullboot[ATR_DRIVES] = {false, false, false, false};
int mount_silent = 0;
bool xex_active = false;
FIL xex_file;
static uint8_t sio_sector_buf[256];
int cba_stage, cba_err;
FIL bridge_file;
#define HDD_HANDLES 2
#define HDD_DIRBUF  1024
#define HDD_LFN_W   27
#define OPTION_FILE   "/atari.ini"
#define ASH_CART_FILE "/ASH.CAR"
uint8_t  sd_rw = 0;
uint32_t cart_sclust = 0;
uint32_t reg_cart_mode = 0;              /* stands in for the iosys register */
FIL hdd_fil[HDD_HANDLES];
uint8_t hdd_open_f[HDD_HANDLES];
char hdd_dirbuf[HDD_DIRBUF];
uint16_t hdd_dirlen, hdd_dirpos;

/* ── firmware shims ──────────────────────────────────────────────────────── */
static int uart_printf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("  [fw] ", stdout); vprintf(fmt, ap);
    va_end(ap); return 0;
}
static void message(char *msg, int center) {
    (void)center; printf("  [fw msg] %s\n", msg);
}

/* the firmware's exact functions */
#include "fw_fs_extracted.c"

/* ── harness ─────────────────────────────────────────────────────────────── */
static FATFS fs;

static void die(const char *m) { printf("FAIL: %s\n", m); exit(1); }

static void init(const char *img) {
    if (diskio_host_open(img)) exit(1);
    if (f_mount(&fs, "", 1) != FR_OK) die("f_mount");
}

static void fill_pattern(uint8_t *b, int len, uint32_t sector, int slot) {
    for (int i = 0; i < len; i++)
        b[i] = (uint8_t)(sector * 7 + slot * 31 + i);
}

/* SIO-shaped write+verify of a list of sectors through the firmware code */
static int write_verify(int slot, const uint32_t *secs, int n) {
    uint8_t wbuf[256], rbuf[256];
    for (int i = 0; i < n; i++) {
        int len = (atr_sector_size[slot] == 128 || secs[i] <= 3) ? 128 : 256;
        fill_pattern(wbuf, len, secs[i], slot);
        if (atr_write_sector(slot, secs[i], wbuf, len)) {
            printf("FAIL: write sector %u slot %d\n", secs[i], slot); return 1;
        }
        int rlen = 0;
        if (atr_read_sector(slot, secs[i], rbuf, &rlen)) {
            printf("FAIL: readback sector %u\n", secs[i]); return 1;
        }
        if (rlen != len || memcmp(wbuf, rbuf, len)) {
            printf("FAIL: verify sector %u slot %d\n", secs[i], slot); return 1;
        }
    }
    return 0;
}

static const uint32_t SECS[] = {1, 2, 3, 4, 100, 360, 361, 719, 720};
#define NSECS (int)(sizeof SECS / sizeof *SECS)

/* put/get: move files between host and the FAT image (also exercises f_open
 * create paths the firmware uses for atari.ini) */
static int cmd_put(const char *host, const char *fat) {
    FILE *h = fopen(host, "rb"); if (!h) { perror(host); return 1; }
    FIL f; if (f_open(&f, fat, FA_WRITE | FA_CREATE_ALWAYS)) die("put f_open");
    uint8_t buf[4096]; size_t n; UINT bw;
    while ((n = fread(buf, 1, sizeof buf, h)) > 0)
        if (f_write(&f, buf, n, &bw) || bw != n) die("put f_write");
    f_close(&f); fclose(h); return 0;
}
static int cmd_get(const char *fat, const char *host) {
    FIL f; if (f_open(&f, fat, FA_READ)) die("get f_open");
    FILE *h = fopen(host, "wb"); if (!h) { perror(host); return 1; }
    uint8_t buf[4096]; UINT br;
    do { if (f_read(&f, buf, sizeof buf, &br)) die("get f_read");
         fwrite(buf, 1, br, h); } while (br == sizeof buf);
    fclose(h); f_close(&f); return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <image> <scenario> [args]\n", argv[0]); return 2; }
    init(argv[1]);
    const char *cmd = argv[2];

    if (!strcmp(cmd, "put")) return cmd_put(argv[3], argv[4]);
    if (!strcmp(cmd, "get")) return cmd_get(argv[3], argv[4]);

    if (!strcmp(cmd, "setro")) {               /* give the file the R/O attr */
        if (f_chmod(argv[3], AM_RDO, AM_RDO)) die("f_chmod");
        return 0;
    }

    if (!strcmp(cmd, "s_write")) {             /* mount + SIO write pattern */
        if (mount_atr(argv[3], 0)) die("mount");
        if (atr_readonly[0]) die("unexpected RO mount");
        return write_verify(0, SECS, NSECS);
    }

    if (!strcmp(cmd, "s_roattr")) {            /* R/O attribute auto-heal */
        if (f_chmod(argv[3], AM_RDO, AM_RDO)) die("pre-chmod");
        if (mount_atr(argv[3], 0)) die("mount");
        if (atr_readonly[0]) die("auto-heal did not fire (mounted RO)");
        return write_verify(0, SECS, 3);
    }

    if (!strcmp(cmd, "s_dupguard")) {          /* same file on both slots */
        if (mount_atr(argv[3], 0)) die("mount slot0");
        if (mount_atr(argv[3], 1)) die("mount slot1");
        if (!atr_mounted[1]) die("slot1 not mounted");
        if (!atr_readonly[1]) die("DUP GUARD DID NOT FIRE — slot1 is read-write!");
        printf("  guard OK: slot1 demoted to RO\n");
        if (write_verify(0, SECS, NSECS)) return 1;   /* writer still works */
        uint8_t rbuf[256]; int rlen;                   /* reader still reads */
        if (atr_read_sector(1, 100, rbuf, &rlen)) die("slot1 read");
        /* firmware write path honors the flag: */
        uint8_t wbuf[128] = {0};
        if (atr_write_sector(1, 100, wbuf, 128) == 0)
            die("write through RO slot1 unexpectedly succeeded");
        return 0;
    }

    if (!strcmp(cmd, "s_dupwrite_raw")) {      /* OLD BUG demo: two write FILs */
        /* In-place overwrites through duplicate FILs are relatively benign;
         * the volume-killer is ALLOCATION through diverged FILs (each handle
         * extends its own idea of the cluster chain -> cross-linked FAT).
         * Extend the file alternately through both handles to demonstrate. */
        FIL a, b; UINT bw;
        if (f_open(&a, argv[3], FA_READ | FA_WRITE)) die("open a");
        if (f_open(&b, argv[3], FA_READ | FA_WRITE)) die("open b");
        uint8_t buf[4096];
        for (int r = 0; r < 40; r++) {
            memset(buf, 0xA0 + (r & 15), sizeof buf);
            FIL *f = (r & 1) ? &b : &a;
            f_lseek(f, f_size(f));             /* stale size on the other FIL */
            f_write(f, buf, sizeof buf, &bw);
            f_sync(f);
        }
        f_close(&a); f_close(&b);
        printf("  dup-write-raw completed (informational — fsck decides)\n");
        return 0;
    }

    if (!strcmp(cmd, "s_create")) {            /* New blank disk xN */
        int n = atoi(argv[3]);
        char name[16];
        for (int i = 0; i < n; i++) {
            int slot = i & 1;
            int r = create_blank_atr(slot, name);
            if (r) { printf("FAIL: create #%d r=%d stage=%d err=%d\n",
                            i, r, cba_stage, cba_err); return 1; }
            printf("  created %s on D%d ro=%d\n", name, slot + 1, atr_readonly[slot]);
            if (write_verify(slot, SECS, 3)) return 1;  /* fresh image writable */
        }
        return 0;
    }

    if (!strcmp(cmd, "s_format")) {            /* SIO FORMAT semantics */
        if (mount_atr(argv[3], 0)) die("mount");
        /* dirty some sectors first */
        if (write_verify(0, SECS, NSECS)) return 1;
        if (atr_format(0)) die("atr_format");
        uint8_t rbuf[256]; int rlen;
        for (uint32_t s = 1; s <= 720; s += 37) {
            if (atr_read_sector(0, s, rbuf, &rlen)) die("post-format read");
            for (int i = 0; i < rlen; i++)
                if (rbuf[i]) { printf("FAIL: sector %u not zero\n", s); return 1; }
        }
        return 0;
    }

    if (!strcmp(cmd, "s_stress")) {            /* interleaved 2-drive traffic */
        int rounds = atoi(argv[5]);
        if (mount_atr(argv[3], 0)) die("mount 0");
        if (mount_atr(argv[4], 1)) die("mount 1");
        for (int r = 0; r < rounds; r++) {
            uint32_t s = 1 + (r * 13) % 720;
            if (write_verify(r & 1, &s, 1)) return 1;
            if (r % 7 == 3) {                  /* browser-during-writes pattern */
                DIR d; FILINFO fi;
                if (f_opendir(&d, "/")) die("opendir");
                while (f_readdir(&d, &fi) == FR_OK && fi.fname[0]) {}
                f_closedir(&d);
            }
            if (r % 10 == 9) {                 /* detach/attach cycling */
                int slot = r & 1;
                f_close(&atr_file[slot]); atr_mounted[slot] = false;
                if (mount_atr(slot ? argv[4] : argv[3], slot)) die("remount");
            }
        }
        return 0;
    }

    if (!strcmp(cmd, "s_slotsym")) {           /* slot 0 vs slot 1 content identity */
        /* Same file on both slots (guard demotes slot1 to RO — reads must still
         * return byte-identical sectors). This is the HW "D2 lists no files
         * while D1 lists fine" question at the data layer. */
        if (mount_atr(argv[3], 0)) die("mount 0");
        if (mount_atr(argv[3], 1)) die("mount 1");
        uint8_t b0[256], b1[256]; int l0, l1;
        static const uint32_t ds[] = {1, 4, 100, 359, 360, 361, 365, 368, 719, 720};
        for (int i = 0; i < 10; i++) {
            if (atr_read_sector(0, ds[i], b0, &l0)) die("slot0 read");
            if (atr_read_sector(1, ds[i], b1, &l1)) die("slot1 read");
            if (l0 != l1 || memcmp(b0, b1, l0)) {
                printf("FAIL: sector %u DIFFERS between slots (l0=%d l1=%d)\n",
                       ds[i], l0, l1);
                return 1;
            }
        }
        printf("  slot0/slot1 byte-identical on all probed sectors\n");
        return 0;
    }

    if (!strcmp(cmd, "s_eofread")) {           /* read beyond the image's end */
        if (mount_atr(argv[3], 0)) die("mount");
        FSIZE_t size_before = f_size(&atr_file[0]);
        uint8_t b[256]; int l;
        static const uint32_t bad[] = {721, 1024, 65535};
        for (int i = 0; i < 3; i++) {
            int r = atr_read_sector(0, bad[i], b, &l);
            printf("  read sector %u -> r=%d\n", bad[i], r);
            if (r == 0) { printf("FAIL: out-of-range read SUCCEEDED\n"); return 1; }
        }
        FSIZE_t size_after = f_size(&atr_file[0]);
        if (size_after != size_before) {
            printf("FAIL: image GREW %u -> %u bytes (f_lseek-extends bug)\n",
                   (unsigned)size_before, (unsigned)size_after);
            return 1;
        }
        return 0;
    }

    if (!strcmp(cmd, "s_put")) {               /* serial-bridge PUT semantics */
        /* Chunked create-overwrite through the firmware's bridge_put_* trio,
         * exactly as bridge_cmd_put drives them (incl. auto-mkdir of missing
         * folders along the path), then read-back verify. */
        char path[68];
        strncpy(path, argv[3], sizeof path - 1); path[sizeof path - 1] = 0;
        for (int pass = 0; pass < 2; pass++) {     /* second pass = overwrite */
            uint32_t size = 92176 - (uint32_t)pass * 12345;
            if (bridge_mkdirs(path)) die("mkdirs");
            if (bridge_put_open(path)) die("put open");
            uint8_t buf[256];
            uint32_t left = size, off = 0;
            while (left) {
                unsigned int chunk = left > 256 ? 256 : left;
                for (unsigned int i = 0; i < chunk; i++)
                    buf[i] = (uint8_t)((off + i) * 13 + pass);
                if (bridge_put_chunk(buf, chunk)) die("put chunk");
                off += chunk; left -= chunk;
            }
            if (bridge_put_close()) die("put close");
            FIL f; UINT br;
            if (f_open(&f, path, FA_READ)) die("verify open");
            if (f_size(&f) != size) { printf("FAIL: size %u != %u\n",
                (unsigned)f_size(&f), (unsigned)size); return 1; }
            uint8_t rb[256]; off = 0;
            while (off < size) {
                unsigned int chunk = size - off > 256 ? 256 : size - off;
                if (f_read(&f, rb, chunk, &br) || br != chunk) die("verify read");
                for (unsigned int i = 0; i < chunk; i++)
                    if (rb[i] != (uint8_t)((off + i) * 13 + pass)) {
                        printf("FAIL: byte %u pass %d\n", off + i, pass); return 1;
                    }
                off += chunk;
            }
            f_close(&f);
        }
        return 0;
    }

    if (!strcmp(cmd, "s_hdd")) {               /* H: device full lifecycle */
        uint8_t st[4], buf[128];
        /* create + write via handle 0 */
        if (hdd_open("NOTES.TXT", 8, 0)) die("open w");
        const char *msg = "HELLO FROM CIO LAND\x9bLINE TWO\x9b";
        if (hdd_write(0, (const uint8_t *)msg, strlen(msg))) die("write");
        if (hdd_close(0)) die("close w");
        /* read back via handle 1 while handle 0 opens the DIRECTORY */
        if (hdd_open("NOTES.TXT", 4, 1)) die("open r");
        if (hdd_open("", 6, 0)) die("open dir");
        hdd_status(1, st);
        int avail = st[2] | (st[3] << 8);
        if (avail != (int)strlen(msg)) { printf("FAIL: avail %d\n", avail); return 1; }
        if (hdd_read(1, buf, avail) != avail) die("read");
        if (memcmp(buf, msg, avail)) die("verify");
        hdd_status(1, st);
        if (!(st[1] & 2)) die("no EOF flag");
        /* directory listing must mention the file */
        hdd_status(0, st);
        int dav = st[2] | (st[3] << 8);
        if (dav <= 0 || dav > 1024) die("dir avail");
        char dl[1025]; int got = 0;
        while (got < dav) {
            int n = hdd_read(0, (uint8_t *)dl + got, dav - got > 64 ? 64 : dav - got);
            if (n <= 0) die("dir read");
            got += n;
        }
        dl[got] = 0;
        if (!strstr(dl, "NOTES.TXT")) { printf("FAIL: dir=%s\n", dl); return 1; }
        hdd_close(0); hdd_close(1);
        /* append */
        if (hdd_open("NOTES.TXT", 9, 0)) die("open a");
        if (hdd_write(0, (const uint8_t *)"MORE\x9b", 5)) die("append");
        hdd_close(0);
        if (hdd_open("NOTES.TXT", 4, 0)) die("reopen");
        hdd_status(0, st);
        if ((st[2] | (st[3] << 8)) != (int)strlen(msg) + 5) die("append size");
        hdd_close(0);
        /* rename + delete + sanitization */
        if (hdd_rename("NOTES.TXT", "KEEP.TXT")) die("rename");
        if (hdd_open("KEEP.TXT", 4, 0)) die("open renamed");
        hdd_close(0);
        if (hdd_delete("KEEP.TXT")) die("delete");
        if (hdd_open("KEEP.TXT", 4, 0) == 0) die("ghost file");
        char pp[80];
        if (hdd_path("../../ETC/PASSWD", pp)) die("path rejected valid-ish");
        if (strstr(pp, "..") || strchr(pp + 5, '/')) {
            printf("FAIL: unsafe path %s\n", pp); return 1; }
        if (hdd_path("H1:GAME.SAV", pp) || strcmp(pp, "/HDD/GAME.SAV")) {
            printf("FAIL: spec path %s\n", pp); return 1; }
        return 0;
    }

    if (!strcmp(cmd, "s_sdctl")) {             /* sd: LIST (40) / OPENR (47) for ASH */
        uint8_t st[4], buf[128];
        char dl[1025];
        /* fixture: /README.TXT, /games/{A.ATR,B.ATR,sub/}, a 35-char long name,
           /many/F00..F39 for the MORE paging */
        FIL f; UINT bw;
        if (f_open(&f, "/README.TXT", FA_WRITE | FA_CREATE_ALWAYS)) die("mk readme");
        const char *txt = "hello from the sd card\x9b";
        if (f_write(&f, txt, strlen(txt), &bw)) die("wr readme");
        f_close(&f);
        if (f_mkdir("/games") || f_mkdir("/games/sub")) die("mkdir");
        if (f_open(&f, "/games/A.ATR", FA_WRITE | FA_CREATE_ALWAYS)) die("mk a");
        for (int i = 0; i < 12345; i += 128) {
            uint8_t z[128] = {0}; UINT n = 12345 - i > 128 ? 128 : 12345 - i;
            if (f_write(&f, z, n, &bw)) die("wr a");
        }
        f_close(&f);
        if (f_open(&f, "/games/B.ATR", FA_WRITE | FA_CREATE_ALWAYS)) die("mk b"); f_close(&f);
        if (f_open(&f, "/games/a very long file name indeed.xex", FA_WRITE | FA_CREATE_ALWAYS)) die("mk lfn"); f_close(&f);
        if (f_mkdir("/many")) die("mkdir many");
        for (int i = 0; i < 40; i++) {
            char nm[24]; sprintf(nm, "/many/F%02d", i);
            if (f_open(&f, nm, FA_WRITE | FA_CREATE_ALWAYS)) die("mk many"); f_close(&f);
        }
        /* helper: read the listing on handle h into dl */
        #define READ_LISTING(h) do {                                            \
            hdd_status(h, st);                                                  \
            int dav = st[2] | (st[3] << 8);                                     \
            if (dav <= 0 || dav > 1024) { die("listing avail"); }               \
            int got = 0;                                                        \
            while (got < dav) {                                                 \
                int n = hdd_read(h, (uint8_t *)dl + got, dav - got > 128 ? 128 : dav - got); \
                if (n <= 0) { die("listing read"); }                            \
                got += n;                                                       \
            }                                                                   \
            dl[got] = 0; hdd_close(h);                                          \
        } while (0)
        /* 1. root listing: dirs flagged 'd' with 8 spaces, file with right-aligned size, END */
        if (hdd_list("/", 0, 1)) die("list /");
        READ_LISTING(1);
        if (!strstr(dl, "d          games\x9b")) { printf("FAIL: root dir line: %s\n", dl); return 1; }
        if (!strstr(dl, "f       23 README.TXT\x9b")) { printf("FAIL: root file line: %s\n", dl); return 1; }
        if (!strstr(dl, "END\x9b")) die("root END");
        if (strstr(dl, "MORE")) die("root MORE");
        /* 2. subdir listing: size 12345, LFN cut at 27 chars */
        if (hdd_list("/games", 0, 1)) die("list /games");
        READ_LISTING(1);
        if (!strstr(dl, "f    12345 A.ATR\x9b")) { printf("FAIL: size col: %s\n", dl); return 1; }
        if (!strstr(dl, "d          sub\x9b")) die("sub dir line");
        if (!strstr(dl, " a very long file name indee\x9b")) { printf("FAIL: lfn cut: %s\n", dl); return 1; }
        /* 3. missing dir / a file as dir -> error */
        if (hdd_list("/nope", 0, 1) == 0) die("list missing");
        if (hdd_list("/README.TXT", 0, 1) == 0) die("list a file");
        /* 4. paging: 40 entries x 13 bytes > 1 KB? no (520 B) — force MORE with the
              27-char-name rule: 40 x "f        0 F00"EOL = 40 x 15 = 600 B fits; so
              check paging logic via start index instead, then a real MORE with 90 files */
        if (hdd_list("/many", 0, 0)) die("list many");
        READ_LISTING(0);
        if (!strstr(dl, "F00\x9b") || !strstr(dl, "F39\x9b") || !strstr(dl, "END\x9b")) die("many all");
        if (hdd_list("/many", 38, 0)) die("list many@38");
        READ_LISTING(0);
        if (strstr(dl, "F37\x9b") || !strstr(dl, "F38\x9b") || !strstr(dl, "F39\x9b") || !strstr(dl, "END\x9b")) {
            printf("FAIL: start=38: %s\n", dl); return 1; }
        for (int i = 40; i < 90; i++) {
            char nm[24]; sprintf(nm, "/many/F%02d", i);
            if (f_open(&f, nm, FA_WRITE | FA_CREATE_ALWAYS)) die("mk many2"); f_close(&f);
        }
        int total = 0, pages = 0, start = 0;
        for (;;) {
            if (hdd_list("/many", start, 1)) die("list page");
            READ_LISTING(1);
            int cnt = 0; for (char *p = dl; *p; p++) if (*p == '\x9b') cnt++;
            int more = strstr(dl, "MORE\x9b") != NULL;
            if (!more && !strstr(dl, "END\x9b")) die("page tail");
            cnt--;                                  /* the tail line */
            total += cnt; start += cnt; pages++;
            if (!more) break;
            if (pages > 10) die("paging runaway");
        }
        if (total != 90 || pages < 2) { printf("FAIL: paged total %d in %d pages\n", total, pages); return 1; }
        /* 5. OPENR: any path, read-only, status/read/close like H: mode 4 */
        if (hdd_openr("/README.TXT", 1)) die("openr");
        hdd_status(1, st);
        int avail = st[2] | (st[3] << 8);
        if (avail != (int)strlen(txt)) { printf("FAIL: openr avail %d\n", avail); return 1; }
        if (hdd_read(1, buf, avail) != avail) die("openr read");
        if (memcmp(buf, txt, avail)) die("openr verify");
        if (hdd_close(1)) die("openr close");
        if (hdd_openr("/games", 1) == 0) die("openr on a directory");
        if (hdd_openr("/nope.txt", 1) == 0) die("openr missing");
        if (hdd_openr("", 1) == 0) die("openr empty");
        if (hdd_write(1, (const uint8_t *)"x", 1) == 0) die("openr writable?!");
        /* 6. a listing on one handle + a file on the other coexist */
        if (hdd_openr("/README.TXT", 0)) die("openr h0");
        if (hdd_list("/games", 0, 1)) die("list h1");
        hdd_status(0, st);
        if ((st[2] | (st[3] << 8)) != (int)strlen(txt)) die("h0 clobbered by listing");
        hdd_close(0); hdd_close(1);
        #undef READ_LISTING
        return 0;
    }

    if (!strcmp(cmd, "s_sdwrite")) {           /* phase 2b: gate + guards + write ops */
        FIL f; UINT bw; uint8_t st[4], buf[128];
        #define MKFILE(p, txt) do { if (f_open(&f, p, FA_WRITE | FA_CREATE_ALWAYS)) die("mk " p); \
            if (f_write(&f, txt, strlen(txt), &bw)) die("wr " p); f_close(&f); } while (0)
        MKFILE("/A.TXT", "alpha\x9b");
        MKFILE("/ATARIXL.ROM", "rom"); MKFILE("/BASIC.ROM", "rom"); MKFILE("/atari.ini", "ini"); MKFILE("/ASH.CAR", "car");
        /* 1. gate closed: every write op refused, and the files are untouched */
        if (sd_mkdir("/W") == 0) die("mkdir with gate closed");
        if (sd_openw("/N.TXT", 1) == 0) die("openw with gate closed");
        if (sd_delete("/A.TXT", 1) == 0) die("delete with gate closed");
        if (sd_rename("/A.TXT", "/B.TXT", 1) == 0) die("rename with gate closed");
        if (hdd_openr("/A.TXT", 1)) die("A.TXT vanished"); hdd_close(1);
        if (hdd_openr("/N.TXT", 1) == 0) die("N.TXT created with gate closed");
        /* 2. gate open: the normal life cycle */
        sd_rw = 1;
        if (sd_mkdir("/W")) die("mkdir");
        if (sd_openw("/W/N.TXT", 1)) die("openw");
        const char *msg = "written from the shell\x9b";
        if (hdd_write(1, (const uint8_t *)msg, strlen(msg))) die("write");
        if (hdd_close(1)) die("close");
        if (hdd_openr("/W/N.TXT", 1)) die("reopen");
        hdd_status(1, st); int avail = st[2] | (st[3] << 8);
        if (avail != (int)strlen(msg) || hdd_read(1, buf, avail) != avail || memcmp(buf, msg, avail)) die("readback");
        hdd_close(1);
        if (sd_rename("/W/N.TXT", "/W/M.TXT", 1)) die("rename");
        if (sd_rename("/W/M.TXT", "/M.TXT", 1)) die("move");
        if (hdd_openr("/M.TXT", 1)) die("moved file"); hdd_close(1);
        if (sd_delete("/M.TXT", 1)) die("delete");
        if (hdd_openr("/M.TXT", 1) == 0) die("ghost after delete");
        if (sd_delete("/W", 1)) die("rmdir empty");
        if (sd_mkdir("/W")) die("mkdir again");
        MKFILE("/W/X.TXT", "x");
        if (sd_delete("/W", 1) == 0) die("rmdir non-empty allowed");
        if (sd_openw("/W/X.TXT", 1)) die("truncate existing"); hdd_close(1);
        /* 3. name guards hold with the gate open, in any case spelling */
        const char *names[] = {"/ATARIXL.ROM", "/basic.rom", "/Atari.ini", "/ash.car"};
        for (int i = 0; i < 4; i++) {
            if (sd_openw(names[i], 1) == 0) { printf("FAIL: openw %s\n", names[i]); return 1; }
            if (sd_delete(names[i], 1) == 0) { printf("FAIL: delete %s\n", names[i]); return 1; }
            if (sd_rename(names[i], "/Z", 1) == 0) { printf("FAIL: rename %s\n", names[i]); return 1; }
            if (sd_rename("/A.TXT", names[i], 1) == 0) { printf("FAIL: rename onto %s\n", names[i]); return 1; }
        }
        /* 4. mounted ATR guard (by cluster: works under another spelling), lifted after unmount */
        if (mount_atr("/D1.ATR", 0)) die("mount");
        if (sd_delete("/d1.atr", 1) == 0) die("delete mounted (lowercase)");
        if (sd_rename("/D1.ATR", "/X.ATR", 1) == 0) die("rename mounted");
        if (sd_openw("/D1.ATR", 1) == 0) die("openw mounted");
        f_close(&atr_file[0]); atr_mounted[0] = false;
        if (sd_rename("/D1.ATR", "/X.ATR", 1)) die("rename after unmount");
        /* 5. virtual xex guard */
        MKFILE("/G.XEX", "xex");
        if (f_open(&xex_file, "/G.XEX", FA_READ)) die("open xex"); xex_active = true;
        if (sd_delete("/G.XEX", 1) == 0) die("delete active xex");
        f_close(&xex_file); xex_active = false;
        if (sd_delete("/G.XEX", 1)) die("delete xex after eject");
        /* 6. other-handle guard: a file open for reading or writing on handle 0 */
        if (hdd_openr("/A.TXT", 0)) die("openr h0");
        if (sd_openw("/A.TXT", 1) == 0) die("openw over a read-open file");
        if (sd_delete("/A.TXT", 1) == 0) die("delete a read-open file");
        hdd_close(0);
        if (sd_openw("/N1.TXT", 0)) die("openw h0");             /* fresh, empty: cluster 0 */
        if (sd_openw("/N1.TXT", 1) == 0) die("dup write-open of a fresh file");
        if (sd_openw("/N2.TXT", 1)) die("another fresh file on h1 must be allowed");
        hdd_close(0); hdd_close(1);
        /* 7. attached cartridge guard */
        MKFILE("/C.CAR", "cart image");
        if (f_open(&f, "/C.CAR", FA_READ)) die("open car"); cart_sclust = f.obj.sclust; f_close(&f);
        reg_cart_mode = 0x0E;                                     /* attached */
        if (sd_delete("/C.CAR", 1) == 0) die("delete attached cart");
        if (bridge_put_open("/C.CAR") == 0) die("PUT onto attached cart");
        reg_cart_mode = 0;                                        /* detached / dropped, cluster left stale */
        if (bridge_put_open("/C.CAR")) die("PUT onto a DROPPED cart refused (stale cluster)");
        bridge_put_close();
        if (sd_delete("/C.CAR", 1)) die("delete cart after detach");
        /* 8. the gate query text + closing the gate */
        sd_rw = 0;
        if (sd_mkdir("/W2") == 0) die("mkdir after gate closed again");
        #undef MKFILE
        return 0;
    }

    if (!strcmp(cmd, "s_putguard")) {          /* bridge PUT must not hit an open file */
        if (mount_atr("/D1.ATR", 0)) die("mount");
        if (bridge_put_open("/D1.ATR") == 0) die("PUT onto a mounted ATR allowed");
        if (bridge_put_open("/d1.atr") == 0) die("PUT onto a mounted ATR (lowercase) allowed");
        f_close(&atr_file[0]); atr_mounted[0] = false;
        if (hdd_openr("/D1.ATR", 1)) die("openr");
        if (bridge_put_open("/D1.ATR") == 0) die("PUT onto an H:-open file allowed");
        hdd_close(1);
        if (f_open(&xex_file, "/D1.ATR", FA_READ)) die("xex open"); xex_active = true;
        if (bridge_put_open("/D1.ATR") == 0) die("PUT onto the active xex allowed");
        f_close(&xex_file); xex_active = false;
        /* last: a PUT with nothing open succeeds (and truncates the file) */
        if (bridge_put_open("/D1.ATR")) die("PUT after unmount refused"); bridge_put_close();
        if (bridge_put_open("/ATARIXL.ROM")) die("ROM rescue PUT refused");   /* names are NOT guarded here */
        bridge_put_close(); f_unlink("/ATARIXL.ROM");
        if (bridge_put_open("/OTHER.BIN")) die("ordinary PUT refused"); bridge_put_close();
        return 0;
    }

    if (!strcmp(cmd, "s_fourslots")) {         /* D1-D4 all live at once */
        for (int sl = 0; sl < 4; sl++) {
            char nm[16];
            sprintf(nm, "/D%d.ATR", sl + 1);
            if (mount_atr(nm, sl)) die("mount");
            if (atr_readonly[sl]) die("unexpected RO");
        }
        for (int sl = 0; sl < 4; sl++) {
            uint32_t secs[3] = {1, 360, 720};
            if (write_verify(sl, secs, 3)) return 1;
        }
        /* dup guard scans all slots: remount slot0's file on slot3 */
        f_close(&atr_file[3]); atr_mounted[3] = false;
        if (mount_atr("/D1.ATR", 3)) die("dup remount");
        if (!atr_readonly[3]) die("4-slot dup guard failed");
        return 0;
    }

    if (!strcmp(cmd, "s_full")) {              /* create until the FS is full */
        char name[16];
        for (int i = 0; i < 200; i++) {
            int r = create_blank_atr(0, name);
            if (r) {
                printf("  create #%d failed gracefully: r=%d stage=%d err=%d\n",
                       i, r, cba_stage, cba_err);
                return 0;                      /* graceful failure = pass */
            }
        }
        printf("  never filled up (image too big for this test)\n");
        return 0;
    }

    if (!strcmp(cmd, "s_ddlayout")) {          /* both DD layout conventions */
        /* argv[3] = packed-boot image, argv[4] = full-boot image; generator
         * tagged every sector's first 4 bytes: 'S' lo hi layout */
        if (mount_atr(argv[3], 0)) die("mount packed");
        if (mount_atr(argv[4], 1)) die("mount fullboot");
        if (atr_sector_size[0] != 256 || atr_sector_size[1] != 256) die("not DD");
        if (atr_dd_fullboot[0]) die("packed misdetected as fullboot");
        if (!atr_dd_fullboot[1]) die("fullboot layout not detected");
        static const uint32_t dsecs[] = {1, 2, 3, 4, 5, 100, 719, 720};
        for (int sl = 0; sl < 2; sl++)
            for (int i = 0; i < 8; i++) {
                uint8_t rbuf[256]; int rlen;
                uint32_t s = dsecs[i];
                if (atr_read_sector(sl, s, rbuf, &rlen)) die("dd read");
                if (rlen != (s <= 3 ? 128 : 256)) die("dd wire length");
                if (rbuf[0] != 0x53 || rbuf[1] != (s & 0xFF) ||
                    rbuf[2] != (s >> 8) || rbuf[3] != sl) {
                    printf("FAIL: slot %d sector %u tag %02x %02x %02x %02x\n",
                           sl, s, rbuf[0], rbuf[1], rbuf[2], rbuf[3]);
                    return 1;
                }
            }
        /* writes honor the layout: write+verify, then confirm untouched
         * neighbors (boot sector 3, data sector 5) kept their tags */
        uint32_t wsecs[4] = {2, 4, 100, 720};
        for (int sl = 0; sl < 2; sl++) {
            if (write_verify(sl, wsecs, 4)) return 1;
            uint8_t rbuf[256]; int rlen;
            if (atr_read_sector(sl, 5, rbuf, &rlen)) die("neighbor read 5");
            if (rbuf[0] != 0x53 || rbuf[1] != 5) die("write clobbered sector 5");
            if (atr_read_sector(sl, 3, rbuf, &rlen)) die("neighbor read 3");
            if (rbuf[0] != 0x53 || rbuf[1] != 3) die("write clobbered boot sector 3");
        }
        return 0;
    }

    fprintf(stderr, "unknown scenario %s\n", cmd);
    return 2;
}
