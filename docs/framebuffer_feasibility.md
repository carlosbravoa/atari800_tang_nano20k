# Frame buffer — feasibility analysis & burst design (authoritative)

**Target:** full-speed Atari (exact NTSC, clk_core 28.6875 MHz / cl=16), **single shared SDRAM
buffer**, **steady standard 720p60** image. Latency minimal (no double-buffer; a slow tear line
is accepted).

**Verdict: FEASIBLE in `src/` only — no `rtl/` changes.** The blocker is SDRAM *transaction
efficiency*, not bandwidth, clock speed, or the Atari core.

---

## Root cause (measured this session, not theorized)

Each SDRAM access ties up the arbiter for ~**210 ns** = ~70 ns SDRAM (single word, full
activate→read→**auto-precharge**) + ~4 clk_core cross-clock handshake ≈ 6 clk_core. So arbiter
throughput ≈ **4.8 M transactions/s**. Loads (trans/s × 210 ns):

| Client | trans/s | arbiter % |
|---|---|---|
| Atari (random single word) | 1.79 M | 37% |
| FB writer (88 single words/line) | 1.27 M | 27% |
| FB reader (88 single words/line) | 1.27 M | 27% |
| **B4 total** | | **~94% → saturated → Atari misses its 558 ns window → no boot** |
| B3 (no reader) | | ~64% → worked |

It is a **transaction-count** problem. The writer/reader touch **88 consecutive words in one
SDRAM row** but pay a full precharged single-word transaction + handshake for *every* word — the
most wasteful SDRAM mode. The Atari machine-cycle window is 16 clk_core = **558 ns**; at ~94%
occupancy an access is almost always in flight when the Atari asks, and contention tips it past
558 ns → ANTIC corruption.

This was the plan's documented headroom lever (`frame_buffer_plan.md`: "burst reads in the
controller"). We derailed because Stage 0 measured *average* bandwidth (~40% → "GO") rather than
*transaction throughput + per-window latency*, then pursued clock decoupling (clk_mem) — harmless
and mildly helpful, but not the lever.

## Why a closed-source sister core does full-speed video on the same chip
Burst / open-page SDRAM: one activate, many words at ~1 cycle each, one precharge → 88 words ≈ 1
transaction, not 88. Our NESTang config is burst-length-1 + auto-precharge-every-word. The
constraint is our controller configuration, **not the device**.

## The fix: burst length 4 (BL4) for the two video clients only

Atari accesses stay single-word (random; only 37%, fine). Only the sequential video streams burst.

- **`src/sdram_nestang.v`** — add a BL4 read+write path: MODE_REG burst length = 4; FSM
  drives/captures 4 data beats per CAS; keep auto-precharge (now amortized over 4 words).
- **`src/gw2ar_sdram.sv` + arbiter (`src/tang_top.sv`)** — a burst client transaction moves 4
  words (one req → 4 words + one completion). Arbiter gains a burst-aware path; Atari path
  unchanged.
- **`src/fb_reader.sv` / `src/fb_writer.sv`** — issue BL4 bursts: an 88-word line = **22 bursts**
  (88 divisible by 4; FB_BASE & stride are 4-aligned, so no burst crosses awkwardly). The reader
  already fetches a whole sequential line — ideal.

**Why BL4 (the key constraint):** a burst is non-preemptible, so the Atari waits behind at most
**one** burst. BL4 ≈ 262 ns; Atari wait (≤262) + its own access (210) = **471 ns < 558 ns** ✓.
BL8 (~349 ns) pushes the Atari to the window edge — reject. Strict priority still lets the Atari
slot in *between* the 22 bursts of a line.

**Budget with BL4:**

| Client | arbiter % |
|---|---|
| Atari | 37% |
| Writer (22 bursts/line) | ~8% |
| Reader | ~8% |
| **Total + refresh** | **~58%** — comfortable; Atari always makes its window |

## On `rtl/` changes
**Not needed.** The Atari core's SDRAM demand (37%) is acceptable; the bottleneck is entirely our
`src/` controller/client efficiency. No precise `rtl/` edit beats "burst the video clients," so
keep the stable core untouched (per the cost/stability concern).

## What stays from the work already done
- **clk_mem (57.375 MHz) decoupled SDRAM controller** — KEEP. Burst data beats run on clk_mem, so
  faster beats shrink the Atari's max wait-behind-a-burst. The 4-phase handshake + SA_WAIT stay.
- **3→4-client arbiter, fb_writer, fb_reader, single-buffer** — KEEP; only the transaction
  granularity changes (single word → BL4 for the two video clients).

## Implementation order (each verifiable)
1. **BL4 in the controller**, exercised by the **writer** first (reader still gated off). Pass =
   Atari boots + writer active (as B3) but now at ~8% writer load.
2. **Reader issues BL4 bursts**, enable it. Pass = Atari boots + steady 720p60 picture, exact
   speed, faint tear line. ← the target.
3. Tune `H_SRC_OFFSET` / centering if needed.

## Risks
- Controller BL4 FSM correctness (data-beat capture/drive timing) — the one real engineering item;
  isolated to `sdram_nestang.v`, verifiable with the writer-only step.
- Bursts must not cross SDRAM row boundaries mid-burst — guaranteed by 4-word alignment (each BL4
  group wraps within a 4-column boundary; a 256-word row holds 64 such groups).
