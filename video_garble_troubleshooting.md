# Atari 800 — Garbled Video Troubleshooting Log

## Problem Statement

The HDMI video output is garbled/scrambled while the Atari CPU (SALLY) is running.
When SALLY is halted (via the `HALT` port or OSD pause), the last rendered frame
displays cleanly. Releasing the halt immediately re-garbles the image.

**Key observation:** The image is correct when the CPU is stopped, and broken when
it runs. This rules out the scaler/HDMI pipeline as the root cause — the problem
is in the Atari core's memory access pattern.

---

## System Architecture Context

| Parameter | Value |
|---|---|
| FPGA | Gowin GW2AR-18 (Tang Nano 20K) |
| sys_clk | 27 MHz (oscillator — iosys, USB, audio) |
| clk_core | 54 MHz (rpll_108m → CLKDIV÷4 — Atari core + SDRAM) |
| cycle_length | 32 FPGA clocks per Atari machine cycle |
| Effective Atari speed | 54/32 = 1.6875 MHz ≈ 1.79 MHz |
| SDRAM | Embedded 32-bit, 8 MB, 4 banks × 2048 rows × 256 cols |
| SDRAM latency | ~7 clock cycles (CL=2 + overhead) at 54 MHz |
| HDMI pixel clock | 74.25 MHz (from rpll_371m → CLKDIV÷5) |

The Atari's two bus masters — **ANTIC** (display DMA) and **SALLY** (6502 CPU) —
share a single SDRAM controller via a software arbiter in `tang_top.sv`. ANTIC
must steal bus cycles from SALLY at precise timing windows defined by the colour
clock. If SDRAM is busy serving SALLY when ANTIC needs data, ANTIC's DMA is
delayed, causing shifted or corrupted scan lines.

---

## Attempts Made (Chronological)

### Attempt 1 — Diagnostic CPU Halt (Confirm Root Cause)

**Hypothesis:** If halting the CPU fixes the image, the problem is bus contention
between SALLY and ANTIC, not the video pipeline.

**Implementation:** Added a 28-bit counter to `tang_top.sv` to toggle `HALT` every
~5 seconds:
```systemverilog
reg [27:0] test_halt_cnt = 28'd0;
always_ff @(posedge sys_clk or negedge hw_reset_n) ...
wire test_halt = test_halt_cnt[27];
.HALT (overlay || test_halt),
```

**Result:** ✅ **Confirmed.** Image was clean during halt windows, garbled when CPU
ran. This locked in SALLY/ANTIC bus contention as the root cause.

**Current state:** `test_halt` removed. `HALT` wired only to `overlay`.

---

### Attempt 2 — Atari-Core Priority Arbiter

**Hypothesis:** The SDRAM arbiter was granting PicoRV32 (Pi interface) bus access
at the expense of the Atari core. Giving Atari requests strict priority would
prevent ANTIC starvation.

**Implementation** ([tang_top.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/tang_top.sv)):
- Added `atari_req_pending` latch
- Changed arbiter from round-robin to Atari-first: PicoRV32 only gets the bus when
  no Atari request is pending or active

```systemverilog
assign sdram_req    = atari_req_pending ? atari_req :
                      picorv_req_pending ? picorv_req : 1'b0;
assign sdram_read   = atari_req_pending ? atari_read_en : picorv_read;
// ...etc
```

**Result:** ❌ No visible improvement. The garbling persisted identically.

**Analysis:** PicoRV32 only accesses SDRAM during ROM uploads (not during normal
emulation), so it wasn't actually competing at runtime. The real contention was
always between SALLY and ANTIC themselves.

---

### Attempt 3 — 4-Line LRU Cache on SDRAM Controller

**Hypothesis:** The 7-cycle SDRAM latency means that repeated reads to the same
addresses (e.g. ANTIC reading the same display list line twice per field) could be
served from cache in 1 cycle, freeing bus bandwidth.

**Implementation** ([gw2ar_sdram.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/gw2ar_sdram.sv)):
- Added 4-line × 32-byte LRU cache
- Cache hit returns in 1 cycle instead of 7
- Fixed `S_CACHE_HIT` state bug (missing `cnt <= 2` initialization causing
  double-trigger)

**Result:** ❌ No visible improvement on garbling.

**Analysis:** SALLY's writes to RAM constantly invalidate cache lines. Because
every store (STA, STX, PHA, etc.) to a cached line flushes it, the effective
cache hit rate for ANTIC's display-list reads was poor. SALLY's write traffic
dominated.

---

### Attempt 4 — 3-Stage Line Buffer in Scaler

**Hypothesis:** The scaler was reading while writing to the same line buffer,
causing tearing/shearing artifacts. A 3-buffer scheme (write→ready→display)
would eliminate this.

**Implementation** ([scale720p.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/scale720p.sv)):
- Upgraded from 2-buffer to 3-stage pipeline: `write_buf` → `ready_buf` →
  `display_buf`
- A completed line is promoted to `ready` at H-blank, then to `display` at the
  start of the output scanline

**Result:** ❌ No improvement on garbling (correct diagnosis: the scaler was never
the cause). ✅ Eliminated any tearing that may have existed.

**Current state:** 3-stage buffer remains in place as it is strictly better.

---

### Attempt 5 — 16KB Internal BRAM for Zero Page / Stack

**Hypothesis:** With `internal_ram=0`, EVERY Atari memory access goes to SDRAM —
including Zero Page (0x0000–0x00FF) and Stack (0x0100–0x01FF). SALLY touches ZP
and Stack on virtually every instruction (LDA zp, STA zp, JSR, RTS, PHA…). This
creates a constant stream of SDRAM requests that prevents ANTIC from ever winning
clean arbitration.

Moving the first 16KB to BRAM would eliminate ~80% of SALLY's SDRAM traffic,
leaving the bus almost entirely free for ANTIC during scanlines.

**Implementation** ([tang_top.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/tang_top.sv) line 538):
```systemverilog
// Before:
.internal_ram  (0),
// After:
.internal_ram  (16384),
```
This maps addresses 0x0000–0x3FFF to FPGA Block RAM. SDRAM starts at bank 1
(`sdram_start_bank = 16384/16384 = 1`). ROMs remain in SDRAM at their usual
high addresses, unaffected.

**Result:** ❌ No visible improvement. Garbling identical.

**Analysis:** The issue is deeper than ZP/Stack traffic. Either:
- ANTIC's DMA itself creates enough SDRAM requests that timing fails regardless
- There is a fundamental timing issue in how the core arbitrates SALLY vs ANTIC
  at the VHDL level (not at the SDRAM controller level)
- The `cycle_length=16` window (592 ns) is too tight for the SDRAM controller
  to serve ANTIC after SALLY has started a transaction

---

## Theories Explored but Not Implemented

### Theory A — Overclocking SALLY or ANTIC
**Verdict: Not viable.**
SALLY and ANTIC are phase-locked through `cycle_length`. The colour clock shift
register, pixel enable pulses, and DMA steal windows all derive from the same
`enable_179` heartbeat in `shared_enable.vhdl`. Speeding up one without the
other would produce wrong pixel timing → guaranteed garbling.

`THROTTLE_COUNT_6502 = 6'd15` is the standard 1.79 MHz setting. The `turbo` mode
via this register is noted as broken in the source comments.

### Theory B — Increase cycle_length + Higher Core Clock  ✅ IMPLEMENTED — SOLVED

**Root cause confirmed:**  The Gowin SDRC_HS state machine needs more clock cycles
than the 16-tick Atari bus window allows at 27 MHz.  At 27 MHz / cycle_length=16
each Atari cycle is 592 ns but the SDRAM controller's own state machine takes
~20–25 steps; when it overruns, the core's `address_decoder.vhdl` stretches the
Atari cycle to wait for `SDRAM_REQUEST_COMPLETE`.  That stretch distorts ANTIC's
colour-clock timing, shifting pixel data by fractional colour clocks and producing
the garbled scan lines.

**Why halting the CPU helped:** With SALLY halted there are no competing SDRAM
requests; ANTIC's DMA always gets immediate bus access, the SDRAM returns within
the window, and no cycles are stretched → clean image.

**Fix implemented (branch `test-cycle30-54mhz-sdram-budget`):**

| Parameter | Before | After |
|---|---|---|
| `clk_core` | 27 MHz (raw osc) | 54 MHz (rpll_108m → CLKDIV÷4) |
| `cycle_length` | 16 | 32 |
| `THROTTLE_COUNT_6502` | 15 | 31 |
| Atari CPU speed | 27/16 = 1.6875 MHz | 54/32 = 1.6875 MHz (identical) |
| SDRAM cycles/Atari cycle | 16 @ 27 MHz | 32 @ 54 MHz |
| SDRAM step wall time | 37 ns | 18.5 ns |
| SDRAM total latency | ~20 × 37 ns = 740 ns (overruns) | ~20 × 18.5 ns = 370 ns < 592 ns ✓ |

The Atari speed is unchanged, but the SDRAM completes in half the wall time — well
within the 32-tick budget — so no Atari cycle ever stretches.

**PLL constraint (GW2AR has only 2 rPLLs):**
`cycle_length=30` was tried first but `shared_enable.vhdl` only tolerates
power-of-2 cycle lengths (index formula `cycle_length/(2^i)-1` underflows at
i=cycle_length_bits when cycle_length is not a power of 2).  `cycle_length=32`
was used instead.

`rpll_12m` (USB 12 MHz) was removed and replaced by `rpll_108m`, a single PLL
generating 216 MHz (CLKOUT) + 12 MHz (CLKOUTD÷18).  A `CLKDIV÷4` primitive on
the 216 MHz output produces the 54 MHz core clock.  The 2-PLL device limit is
preserved.

**CDC between iosys (27 MHz) and arbiter (54 MHz):**
`iosys_picorv32` must remain on 27 MHz — its firmware has hardcoded SPI timing
for the SD card init phase (≤400 kHz), which would double and fail at 54 MHz.
A three-layer CDC bridge in `tang_top.sv` handles the crossing:

1. `rv_valid` (27 → 54 MHz): 2-FF level synchroniser → `rv_valid_core`
2. `rv_ready` (54 → 27 MHz): toggle synchroniser (`rv_done_toggle_r`, 3-stage
   `rv_done_sys_r`, XOR edge-detect → `rv_ready_sync`)
3. `rv_hold`: set on PicoRV32 transaction completion; cleared when `rv_valid_core`
   deasserts.  Prevents phantom re-launches during the ≈8 clk_core cycles between
   completion and iosys acknowledging `rv_ready`.

---

## Resolution

**✅ SOLVED.** First correct Atari video confirmed on hardware after the
`cycle_length=32` / `clk_core=54 MHz` change.

### Final State of Modified Files

| File | Change |
|---|---|
| `src/tang_top.sv` | 54 MHz core clock, cycle_length=32, THROTTLE=31, CDC bridge |
| `src/rpll_108m.v` | New dual-output PLL (216 MHz + 12 MHz) |
| `build.tcl` | rpll_12m → rpll_108m |
| `src/gw2ar_sdram.sv` | 4-line LRU cache (remains) |
| `src/scale720p.sv` | Ping-pong line buffer scaler (remains) |
