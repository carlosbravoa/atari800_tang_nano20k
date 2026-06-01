# Firmware Specification & Slimming Plan (firmware-off-SDRAM)

Status: **DRAFT for review.** Branch: `firmware-off-sdram`.
Purpose: define what the PicoRV32 firmware MUST do, MAY drop, and MUST NOT regress, so we can
slim it to fit in BSRAM (removing it from SDRAM → eliminates CPU↔ANTIC SDRAM contention, the
root cause of the OSD/boot flakiness). See memory: project-firmware-off-sdram,
project-osd-interim-state.

---

## 1. Why we are doing this

The PicoRV32 currently executes from SDRAM, so its instruction fetches compete with the Atari
core (CPU + ANTIC DMA) for the single SDRAM. This is the structural cause of every
keyboard/OSD/boot problem in this project. The fix is to run firmware from **BSRAM** so its
fetches never touch SDRAM. BSRAM is small, so the firmware must be slimmed to fit.

### Budget (measured 2026-06-01, current firmware)

| Resource | Value |
|---|---|
| BSRAM total (GW2AR-18) | **46 blocks × 18 Kbit = 92 KB** |
| BSRAM already used | 9 blocks (~18 KB) — Atari core, SIO FIFO, OSD text, USB ROM, scaler |
| **BSRAM free** | **37 blocks ≈ 74 KB** |
| Current firmware .text | 70 KB |
| Current firmware .data | 12 B |
| Current firmware .bss | 11.7 KB |
| Stack | 4 KB (STACK_TOP 0x100000 region; actual use less) |

**Conclusion:** current 70 KB .text + 12 KB bss + stack ≈ 86 KB does NOT fit safely in 74 KB.
We must either (a) slim .text well under budget, or (b) split (code in BSRAM, data/stack in
SDRAM — but data-in-SDRAM still causes *some* contention), or (c) I-cache. Target of this spec:
**slim enough that code+data+stack all live in BSRAM with margin.**

### Where the bytes are (measured, .text)

| Component | Size | Notes |
|---|---|---|
| FatFS (`ff.o` + `ffunicode.o`) | **~39 KB** | SD card FAT32 filesystem. Biggest single item. |
| Soft-float + libgcc (`__*df3`, `__udivdi3`, `__umoddi3`, …) | **~12 KB** | Pulled in by printf `%f`/`%w` and 64-bit math. Mostly avoidable. |
| Our app code (`firmware.o` .text) | ~14 KB | menu, SIO, ROM load, options, keyboard poll |
| picorv32 runtime (`picorv32.c`) | ~5.5 KB | printf, delay, joy/overlay helpers, low-level |
| spi_sd.c | ~2.7 KB | SD SPI block driver |
| spiflash.c | ~0.9 KB | SPI flash reader (firmware self-load) |
| **.text total** | **~70 KB** | |

The two big slimming levers are **FatFS (~39 KB)** and **softfloat/64-bit libgcc (~12 KB)**.

---

## 2. Functional requirements — what the firmware MUST do

These are the non-negotiable base needs. Anything here that breaks is a regression.

### R1. Auto-boot the Atari (CRITICAL)
- On power-on, load OS + BASIC ROMs into SDRAM and release the Atari so it boots straight to
  BASIC with **no menu shown** (see CLAUDE.md "Expected Boot Behavior").
- Requires: read `ATARIXL.ROM` (16 KB) → SDRAM 0x704000, `BASIC.ROM` (8 KB) → SDRAM 0x700000;
  toggle `reg_romload_ctrl` to hold/release core reset; set COLDST.

### R2. SD card read access (CRITICAL for R1)
- Read files from a FAT-formatted SD card (the ROMs, and ATR disk images).
- Minimum: mount volume, open file, sequential read, seek (for ATR sector access), readdir
  (for the file browser). FAT32 + likely FAT16; long-file-name (LFN) support is **nice-to-have**.

### R3. OSD menu (CRITICAL — the feature we just fixed)
- Render text overlay (via `reg_textdisp`), navigate with joystick/keyboard (`reg_joystick`),
  toggle overlay on/off. Menu items: select ATR, boot OS/BASIC, soft/hard reset, options,
  return to game.
- Read inputs via `reg_joystick` (fed by hardware keyboard decoder + S2 + F12).

### R4. SIO disk emulation (REQUIRED eventually, currently deferred/flaky)
- Respond to Atari SIO commands (status, read sector, write sector) backed by a mounted ATR file
  on SD. Uses `reg_sio_*`. **Note:** SIO is currently broken/deferred and structurally can't work
  while CPU is frozen during Atari run — its proper fix DEPENDS on this firmware-off-SDRAM work.
  Keep the code, but it is acceptable for SIO to remain non-functional until after the move.

### R5. Options persistence (KEEP)
- Load/save a small options file on SD (OSD hotkey choice, keyboard type). Small, cheap.

### R6. Self-load from SPI flash (KEEP, but see §4 — may change)
- Firmware is currently copied from SPI flash 0x500000 into SDRAM at boot. Once firmware lives in
  BSRAM (loaded at config time via $readmemh baked into the bitstream), **this step may be
  ELIMINATED** — which also removes the `flash_loaded` gate that caused Gowin to prune BSRAM in
  the prior attempt. This is a desirable simplification.

---

## 3. What we can DROP or SLIM — candidates for removal

Mark each KEEP / DROP / SLIM during review.

### D1. Soft-float / printf floating point (~12 KB) — **propose DROP**
- `__adddf3/__subdf3/__muldf3/__divdf3`, `__udivdi3/__umoddi3` pulled in by printf `%f` and any
  64-bit/float math. We have NO genuine need for floating point.
- Action: remove all float usage; use a minimal integer-only printf (or drop printf to UART-debug
  only). Saves ~12 KB. **Biggest easy win.**

### D2. FatFS write support (~? KB of the 39 KB) — **propose SLIM**
- `f_write`, `f_sync`, `f_mkdir`, `f_rename`, `create_chain`, `dir_register` etc. are only needed
  for: ATR *write* (saving disk changes) and options-file *save*.
- If we accept read-only ATR (no disk writes persisted) and store options differently (or accept
  losing save), we can compile FatFS read-only (`FF_FS_READONLY=1`) → big savings.
- DECISION NEEDED: do we need to write to the SD card at all? (ATR writes? options save?)

### D3. FatFS LFN / Unicode (`ffunicode.o` ~1.5 KB + LFN code) — **propose DROP**
- Long file names. If we require 8.3 short names for ROMs/ATRs, drop LFN (`FF_USE_LFN=0`) and
  Unicode table. Saves a few KB and simplifies.
- DECISION NEEDED: are users' ATR/ROM filenames 8.3-compatible, or do we need LFN?

### D4. FatFS f_getfree / f_mkdir / dir create (~3 KB) — **propose DROP**
- Free-space query and directory creation. Not needed for read/boot. Drop unless options-save
  needs mkdir.

### D5. test_sdram() (~? KB) — **propose DROP**
- `test_sdram()` is a bringup diagnostic. Remove from production firmware.

### D6. Verbose uart_printf debug strings (~? KB of rodata) — **propose SLIM**
- Many `uart_printf("...")` diagnostic strings. Useful in dev, but the format strings add up.
  Gate behind a DEBUG macro (compile out for the BSRAM build), keep for dev builds.

### D7. printf %w / custom format specifiers — **propose SLIM**
- Custom width/hex specifiers in `_printf`. Keep only what the menu actually renders.

---

## 4. Architecture change (RTL side, separate doc later)

- Firmware → BSRAM as a $readmemh-initialised ROM (code) + BSRAM RAM (data/bss/stack), OR a
  single read/write BSRAM if size allows.
- **Boot the PicoRV32 directly from BSRAM at reset** (reset vector in BSRAM). This removes the
  SPI-flash→SDRAM copy AND the `flash_loaded` gate, which is what let Gowin prune the BSRAM in the
  prior `feature/picorv32-bram-firmware` attempt ("Nice try, nothing works").
- Prior attempt lesson: full 64 KB across 32 banks got pruned (dead-path constant-fold) and blew
  up DFFs. Avoid by (a) reset-live read path that can't be folded dead, (b) smaller footprint
  after slimming, (c) clean ROM inference or explicit primitives.
- De-risking step before committing: a minimal 1-bank $readmemh BSRAM probe that provably reaches
  an output, reset-live, to confirm Gowin maps+retains it without DFF explosion.

---

## 5. Target budget after slimming (goal)

| Component | Current | Target | How |
|---|---|---|---|
| FatFS | 39 KB | ~20-25 KB | read-only, no LFN, no mkdir/getfree (D2,D3,D4) |
| Softfloat/libgcc | 12 KB | ~2 KB | no float, integer printf (D1) |
| App + libs | 22 KB | ~18 KB | drop test_sdram, gate debug (D5,D6,D7) |
| **.text total** | **70 KB** | **~40-45 KB** | |
| .bss | 11.7 KB | ~8-10 KB | reduce big static buffers (DirBuf, file_names, load_buf) if possible |

Goal: **code + data + stack ≤ ~60 KB**, fitting in 37 free BSRAM blocks (74 KB) with margin.

---

## 6. DECISIONS (answered by user 2026-06-01)

1. **SD writes: REQUIRED.** Must load AND write ATRs (write to the virtual disks). Savestates NOT
   needed. ⇒ FatFS keeps write support. D2 (read-only) is REJECTED.
2. **Long filenames: REQUIRED.** Thousands of ATR files; renaming to 8.3 is unacceptable. ⇒ FatFS
   keeps LFN + Unicode. D3 (drop LFN) is REJECTED.
3. **Floating point + 64-bit div: DROP via disabling exFAT.** Root cause traced: the float
   helpers (`__muldf3/__divdf3/__fixdfsi/__floatsidf/__subdf3`) and 64-bit div/mod
   (`__udivdi3/__umoddi3`) are called ONLY from FatFS `ff.o`, pulled in by **`FF_FS_EXFAT=1`**.
   Our code does no float/64-bit math. **DECISION: FAT32-only — set `FF_FS_EXFAT=0`.** Saves the
   ~12 KB float + ~6 KB 64-bit helpers (~18 KB total). LFN is INDEPENDENT of exFAT and is RETAINED
   (FAT32 supports long filenames). Tradeoff accepted: SD card must be FAT32 (≤32 GB or formatted
   FAT32); exFAT/SDXC cards won't mount.
4. **Debug output: GATE behind DEBUG macro** (assumed; confirm). D6 stands.
5. **SIO: REVIVE immediately after this work.** Keep all SIO code; it must come back as the very
   next task. R4 stays in.
6. **File browser: needs PAGINATION** (no hard small cap; avoid awkwardness). ⇒ list files a page
   at a time from a modest in-RAM window rather than holding thousands of names in .bss.

### MEASURED RESULTS (2026-06-01, applied)

Two FatFS config changes in `ffconf.h`, zero code surgery, no loss of used functionality:
- `FF_FS_EXFAT = 1 → 0` (FAT32-only): .text 71,975 → 64,327 (−7.6 KB)
- `FF_PRINT_FLOAT = 1 → 0`, `FF_PRINT_LLI = 1 → 0`: → **45,735 (−18.6 KB more)**

Root cause of the float was NOT exFAT alone — 43 float calls + 64-bit div lived in FatFS
`f_printf` (which we DON'T use; we only use f_puts/f_gets). Disabling float/lli formatting in
f_printf removed ALL softfloat + 64-bit helpers. f_puts/f_gets/LFN/FAT32 all retained.

| | .text | .bss | total |
|---|---|---|---|
| Original | 71,975 | 11,760 | ~84 KB |
| **After both flags** | **45,735** | **11,104** | **~57 KB** |
| Free BSRAM | | | 74 KB |
| **Margin** | | | **~17 KB ✓ comfortable** |

⇒ Option A (full firmware in BSRAM) is now a comfortable fit. Further slimming (D5 test_sdram,
D6 debug strings, .bss pagination) is now OPTIONAL headroom, not required.

### Impact of these decisions on the budget

Keeping **write + LFN** means FatFS stays ~**35-39 KB** (the two biggest FatFS savings are off the
table). Revised realistic target:

| Component | Current | Target | How |
|---|---|---|---|
| FatFS (write + LFN) | 39 KB | ~35 KB | minor: drop f_getfree/f_mkdir if unused, tune FF_ config |
| Softfloat/libgcc | 12 KB | ~2 KB | drop float, integer-only printf (D1) ✓ |
| App + libs | 22 KB | ~17 KB | drop test_sdram, gate debug (D5/D6/D7) |
| **.text total** | **70 KB** | **~54 KB** | |
| .bss | 11.7 KB | ~6-8 KB | pagination shrinks `file_names` (5.6 KB → small window) |

**Revised conclusion:** realistic slimmed firmware ≈ **54 KB code + ~7 KB data + stack ≈ 65 KB.**
The 37 free BSRAM blocks = **74 KB**, so it FITS — but with only ~9 KB margin. That is tight but
viable. This pushes the RTL architecture decision (see §7).

---

## 7. RTL architecture options given the ~65 KB tight fit

Because FatFS write+LFN can't be shrunk much, "everything in BSRAM with comfortable margin" is
tight. Three options, to choose before implementing:

- **Option A — Full firmware in BSRAM (code+data+stack).** ~65 KB into 74 KB. Simplest model
  (no SDRAM in the CPU path at all → contention GONE). Risk: tight margin; if firmware grows it
  breaks; and the prior attempt shows Gowin BSRAM packing is finicky at scale. Needs the
  reset-live / no-flash-gate structure (§4) and likely explicit primitives.
- **Option B — Split: code+stack in BSRAM, large data buffers in SDRAM.** Eases BSRAM pressure,
  but data-in-SDRAM reintroduces SOME contention when firmware actively runs (menu/SIO) while
  ANTIC runs. Since the menu HALTs the 6502 (but NOT ANTIC), data contention would still cause
  some glitching — partially defeats the purpose. Weaker.
- **Option C — BSRAM instruction cache (firmware stays in SDRAM).** ~8-16 KB I-cache. Robust to
  firmware size, small BSRAM use. But cache *misses* still hit SDRAM, and streaming through 39 KB
  of FatFS during ATR load would thrash a small cache → contention during disk I/O (exactly when
  SIO needs it). Mediocre for this workload.

**Leaning: Option A** (full BSRAM) is the only one that fully removes contention, and the slimmed
~65 KB makes it just-fit. The tight margin is the main risk — mitigated by the float drop (D1) and
pagination (.bss shrink). If A proves infeasible in BSRAM packing, fall back to B.

### Remaining confirmations
- Confirm **D1 (drop float)** and **D6 (gate debug)** — assumed yes.
- Decide **A vs B** after the §4 de-risking probe (does a clean reset-live $readmemh BSRAM ROM of
  ~realistic size map and retain on Gowin?).
