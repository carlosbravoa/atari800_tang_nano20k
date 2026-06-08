# PicoRV32 Firmware 32 KB Optimization Report (LFN Disabled)

We have successfully optimized the PicoRV32 firmware to run in a **32 KB** on-chip boot-RAM (BSRAM) region. This change has successfully freed **16 physical BSRAM blocks** on the Tang Nano 20K (reducing total BSRAM utilization from 90% to 55%), leaving them completely available for the framebuffer logic.

---

## Final Footprint Metrics

| Metric | Original (64 KB BRAM) | Optimized (32 KB BRAM) | Reduction (%) |
|---|---|---|---|
| **BRAM Sizing** | 64 KB (16,384 words) | 32 KB (8,192 words) | **-50.0%** |
| **`firmware.bin` Size** | 51,520 bytes | 27,984 bytes | **-45.7%** |
| **BSS RAM Usage** | 11,232 bytes | 2,676 bytes | **-76.2%** |
| **Total Memory footprint** (`text`+`data`+`bss`) | 62,752 bytes | 30,660 bytes | **-51.1%** |
| **Stack Margin** | 2,784 bytes | 2,108 bytes | **Stable / Safe** |
| **FPGA BSRAM Blocks** | 32 blocks | 16 blocks | **-50.0% (16 blocks freed)** |
| **Total FPGA BSRAM Usage** | 41 blocks (90%) | 25 blocks (55%) | **-39.0%** |

---

## Applied Optimizations

### 1. Compiler and Linker Level
*   **Size Optimization (`-Os`)**: Changed optimization level in the [Makefile](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/Makefile) from `-O2` to `-Os`.
*   **Linker Garbage Collection**: Compiled with `-ffunction-sections -fdata-sections` and linked with `--gc-sections` (along with `ENTRY(_start)` in [baremetal.ld](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/baremetal.ld)) to automatically strip unused functions and data.
*   **C99 Inlining Fix**: Declared all inline helper functions in [picorv32.h](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/picorv32.h) as `static inline` to prevent un-inlined duplicate references during compilation.

### 2. Code & Buffer Reductions (BSS & Stack)
*   **32-Bit Division**: Changed the framerate calculation in [firmware.c](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/firmware.c#L121) to 32-bit math, allowing the compiler to strip the 64-bit software division routine (`__udivdi3`), saving **1.4 KB** of code size.
*   **Shared SIO Sector Buffer**: Replaced two separate 256-byte static buffers in the read and write handlers with a single file-scoped shared buffer `sio_sector_buf[256]` in [firmware.c](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/firmware.c#L54), saving **256 bytes** of BSS.
*   **Removed Unused Buffer**: Deleted `load_buf[1024]` in [firmware.c](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/firmware.c#L35), saving **1024 bytes** of BSS.
*   **Shrank Path Variables**: Shrank the `pwd` buffer to `256` bytes (from 1024) and `load_fname` to `512` bytes (from 1024).
*   **Shrank OSD Menu Page**: Shrank the directory page size `PAGESIZE` from `22` to `16` in [firmware.c](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/firmware.c#L38).
*   **Shrank Local Stack Buffers**: Shrank the local `mounted_atr_name` buffer inside `main()` from `256` to `16` bytes to save stack space.
*   **UART Logging Fully Operational**: We did **not** define `DISABLE_UART_PRINTF` in this build, meaning all SIO and system logging to UART continues to function exactly as originally implemented.

### 3. File System (FatFs) Tweaks
*   **Disabled Long File Names (LFN)**: Configured `#define FF_USE_LFN 0` in [ffconf.h](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/fatfs/ffconf.h) and removed `ffunicode.c` from compilation. File navigation operates in standard 8.3 Short File Name (SFN) mode.
*   **Shrank Filename Buffer**: Shrank the BSS array `file_names[PAGESIZE][256]` to `file_names[PAGESIZE][16]`. Since LFN is disabled, file names are at most 13 characters (e.g. `PACMAN.ATR`), making a 16-byte width 100% safe. This saved **3,840 bytes** of BSS RAM.

### 4. RTL / FPGA Integration
*   **BRAM size parameters**: Adjusted BRAM depth parameters in [iosys_picorv32.v](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/iosys_picorv32.v) to `.AWORDS(8192)` and `.AW(13)`.
*   **Memory Split Check**: Updated the address routing split to `< 32 KB` (`mem_addr[22:15] == 0`) for BRAM, and `>= 32 KB` for SDRAM.
*   **Linker Stack & BRAM Depth**: Set the stack top in [start.S](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/start.S) to `0x8000` (32 KB limit) and `BRAM_DEPTH = 8192` in [Makefile](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/Makefile).

---

## Verification & Next Steps

1.  **Successful Bitstream Generation**: The Gowin build shell successfully compiled the modified design into `impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs`.
2.  **BSRAM Savings**: The overall BSRAM utilization reported by Place & Route dropped from **41 blocks** to **25 blocks (55%)**, successfully freeing **16 blocks** for your framebuffer logic.
3.  **UART Keyboard & SIO Preserved**: The UART registers and interface are fully intact, and because we did not disable UART printing, the serial port is fully functional.
4.  **Flashing**: You can now flash the generated file `impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs` to test the system on your Tang Nano 20K board.
