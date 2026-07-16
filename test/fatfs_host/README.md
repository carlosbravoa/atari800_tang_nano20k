# Host-side FatFs volume-safety suite

Tests the firmware's SD/disk layer **on the PC** against a file-backed FAT image, so
volume-corruption bugs are caught before they ever touch a real card (born from the
2026-07-16 incident where disk-write testing destroyed an SD card's filesystem —
INVESTIGATE.md #7).

**Property under test:** no sequence of firmware disk operations may damage the FAT
volume. Every scenario runs on a fresh `mkfs.vfat` image and must leave it
`fsck.fat`-clean, in addition to its own functional assertions.

## How it stays honest

`extract_fw_fs.py` pulls `mount_atr`, `atr_read_sector`, `atr_write_sector`,
`atr_format` and `create_blank_atr` **verbatim out of `firmware/firmware.c` at every
build** — the harness cannot drift from the shipped code. It compiles them against the
firmware's own `ff.c`/`ffconf.h` (with `-DHOST_FATFS_TEST`, which only swaps the
bare-metal `picorv32.h` include for host libc). `diskio_host.c` maps sectors onto a
plain image file.

## Run

```bash
cd test/fatfs_host && ./run_tests.sh
```

Needs `gcc`, `python3`, `mkfs.vfat`, `fsck.fat` (dosfstools).

## Scenarios

| Name | What it proves |
|---|---|
| `s_write` | mount + SIO-shaped sector writes + readback verify |
| `s_dupguard` | same ATR mounted on D1+D2 → second mount demoted to RO; writes through it refused (the SD-killer combination) |
| `s_roattr` | PC-copied read-only attribute is auto-healed (f_chmod) → writable mount |
| `s_create x6` | "New blank disk" on both slots; created images immediately writable |
| `s_format` | SIO FORMAT zero-fills the whole image |
| `s_stress 500` | interleaved 2-drive writes + directory listings + detach/remount cycling |
| `s_full` | filesystem-full → graceful create failure (stage/err codes), volume intact |
| `s_dupwrite_raw` | INFORMATIONAL: the pre-guard bug (two raw write-FILs, extending) — fsck reports whether this sequence damaged the volume |

## Track record

- Caught (before any hardware test): **stale-`ff.o` build bug** — `firmware/Makefile`'s
  `HDRS` didn't cover `fatfs/*.h`, so the `FF_MAX_LFN` 255→128 change never rebuilt
  `ff.o`; builds #4/#5 shipped with mismatched FILINFO sizes between `ff.o` and
  `firmware.o` and only half the intended stack relief. Found because the harness
  build forced a consistent recompile and the size shifted.

## Extending

Add a scenario = one `if (!strcmp(cmd, ...))` block in `harness.c` + one stanza in
`run_tests.sh` (fresh image, run, `check`). Keep new firmware FS functions inside the
extraction list in `extract_fw_fs.py`.
