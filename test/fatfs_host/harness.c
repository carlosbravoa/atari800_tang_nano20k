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
