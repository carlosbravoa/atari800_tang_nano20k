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
| sys_clk | 27 MHz |
| cycle_length | 16 FPGA clocks per Atari machine cycle |
| Effective Atari speed | 27/16 = 1.6875 MHz ≈ 1.79 MHz |
| SDRAM | Embedded 32-bit, 8 MB, 4 banks × 2048 rows × 256 cols |
| SDRAM latency | ~7 clock cycles (CL=2 + overhead) |
| HDMI pixel clock | 74.25 MHz (from PLL) |

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

### Theory B — Increase cycle_length + Higher PLL
**Not yet implemented.**
Running at `cycle_length=30` with `sys_clk=54 MHz` would keep the Atari at
~1.8 MHz but give the SDRAM controller 30 FPGA cycles (≈556 ns) per Atari cycle
instead of 16 cycles (≈592 ns at 27 MHz). The ratio of SDRAM latency to cycle
budget improves significantly (7/30 vs 7/16).

Requires PLL reconfiguration. Medium risk.

### Theory C — VHDL-Level Arbitration Fix (SALLY vs ANTIC)
**Not yet implemented.**
The `address_decoder.vhdl` and `shared_enable.vhdl` serialise bus ownership
between SALLY and ANTIC internally before the request even reaches the SDRAM
controller. The `MEMORY_READY_CPU` / `MEMORY_READY_ANTIC` signals gate whether
each CPU advances its state machine.

If the SDRAM controller takes longer than `cycle_length` clocks to respond (e.g.
during a refresh), the `shared_enable` FSM may stall in an unexpected state,
desynchronising ANTIC's DMA from its pixel counter. This would produce exactly
the symptom observed — garbled image when CPU runs.

This would require reading and possibly patching `shared_enable.vhdl` and/or the
SDRAM controller to guarantee responses within `cycle_length` clocks.

---

## Current State of Modified Files

| File | Change | Status |
|---|---|---|
| [tang_top.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/tang_top.sv) | Atari-priority arbiter + `internal_ram=16384` | In tree |
| [gw2ar_sdram.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/gw2ar_sdram.sv) | 4-line LRU cache + `S_CACHE_HIT` fix | In tree |
| [scale720p.sv](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/scale720p.sv) | 3-stage line buffer | In tree |

---

## Recommended Next Steps (for future session)

1. **Theory C (VHDL arbitration):** Audit `shared_enable.vhdl` — specifically the
   `oldcycle_state` FSM — to check whether an SDRAM stall beyond `cycle_length`
   clocks can desync the ANTIC enable from its pixel counter.

2. **Guarantee sub-cycle SDRAM response:** Modify `gw2ar_sdram.sv` so that if a
   request cannot complete within `cycle_length-1` clocks (e.g. during refresh),
   it asserts a stall signal that both `MEMORY_READY_CPU` and `MEMORY_READY_ANTIC`
   can observe, rather than simply being slow.

3. **Compare against a working reference:** Find another Tang Nano 20K Atari core
   (e.g. from MiSTer or other open-source projects) that produces correct video,
   and diff its SDRAM controller and arbiter design against ours.
