FATFS = ../../firmware/fatfs
CC    = gcc
CFLAGS = -O1 -g -Wall -Wno-unused-function -DHOST_FATFS_TEST -I$(FATFS) -I.

fatfs_host: harness.c diskio_host.c fw_fs_extracted.c $(FATFS)/ff.c $(FATFS)/ffunicode.c
	$(CC) $(CFLAGS) -o $@ harness.c diskio_host.c $(FATFS)/ff.c $(FATFS)/ffunicode.c

fw_fs_extracted.c: ../../firmware/firmware.c extract_fw_fs.py
	python3 extract_fw_fs.py

clean:
	rm -f fatfs_host fw_fs_extracted.c *.img

.PHONY: clean
