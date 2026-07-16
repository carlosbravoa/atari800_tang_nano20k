/* Host diskio: FatFs low-level layer backed by a plain image file.
 * 512-byte sectors, pread/pwrite, CTRL_SYNC = fsync. */
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include "ff.h"
#include "diskio.h"

static int img_fd = -1;

int diskio_host_open(const char *path) {
    img_fd = open(path, O_RDWR);
    if (img_fd < 0) { perror(path); return -1; }
    return 0;
}

DSTATUS disk_initialize(BYTE pdrv) { (void)pdrv; return img_fd >= 0 ? 0 : STA_NOINIT; }
DSTATUS disk_status(BYTE pdrv)     { (void)pdrv; return img_fd >= 0 ? 0 : STA_NOINIT; }

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
    (void)pdrv;
    ssize_t n = pread(img_fd, buff, (size_t)count * 512, (off_t)sector * 512);
    return n == (ssize_t)count * 512 ? RES_OK : RES_ERROR;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
    (void)pdrv;
    ssize_t n = pwrite(img_fd, buff, (size_t)count * 512, (off_t)sector * 512);
    return n == (ssize_t)count * 512 ? RES_OK : RES_ERROR;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    (void)pdrv;
    switch (cmd) {
    case CTRL_SYNC: fsync(img_fd); return RES_OK;
    case GET_SECTOR_COUNT: {
        struct stat st;
        if (fstat(img_fd, &st)) return RES_ERROR;
        *(LBA_t *)buff = st.st_size / 512;
        return RES_OK;
    }
    case GET_SECTOR_SIZE: *(WORD *)buff = 512; return RES_OK;
    case GET_BLOCK_SIZE:  *(DWORD *)buff = 1;  return RES_OK;
    default: return RES_PARERR;
    }
}
