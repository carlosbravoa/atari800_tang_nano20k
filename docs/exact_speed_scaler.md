# Exact-speed video (frame-lock) — investigation log & open issues

**Status:** UNSOLVED / parked. Exact-speed core works; a *steady, monitor-legal* picture at
exact speed does not yet build reliably. We got close but did not nail it. Last updated 2026-06-08.

**Working fallbacks (both solid, on hardware):**
- `main` — `clk_core` 27 MHz, `cycle_length=16`, ~6% slow, **zero jitter, zero corruption.**
- branch `scaler-exact-speed` commit `193674e` — `clk_core` 28.6875 MHz, **exact speed**, but ±1-line
  HDMI genlock jitter (works on tolerant monitors; strict ones may not lock).

---

## The goal and the three coupled problems

Goal: **exact NTSC speed + a clean, monitor-legal 720p picture + steady (no jitter).**

The scaler is a **line buffer** (NOT a frame buffer — ~0.5 ms latency, not a frame). Two separate
defects appear at exact speed, each with a cheap *line-based* fix:

1. **Tearing** — at exact speed the Atari writes lines ~6% faster than the 3×-repeat reader at a
   44–45 kHz line rate consumes them, so the writer pulls ahead within a frame (peak "skew" ~11–16
   source lines) and laps a shallow buffer. **Fix: deepen the line FIFO** to absorb the skew.
2. **±1-line jitter** — the HDMI frame is genlocked to the Atari frame, but the frame works out to a
   **non-integer number of HDMI lines** (e.g. 739.78 at H_TOTAL=1672), so the genlock reset walks
   sub-line each frame → the picture nudges ±1 line. **Fix: pick H_TOTAL so the frame is a near-integer
   number of lines ("frame-lock").** This is a *timing* trick — zero memory, zero lag.

### The triangle (pick two)
| Want | Cost |
|---|---|
| Exact speed + monitor-legal line rate (≤~45.3 kHz) | needs a **deep** FIFO (~20 lines → 8 BSRAM blocks) |
| Exact speed + shallow FIFO (≤16 lines → 4 blocks) | needs a **higher** line rate (~45.8 kHz) |
| Monitor-legal + shallow FIFO | only at the **6% slow** speed (today's `main`) |

"Drop a few lines" (fewer HDMI lines/frame) lowers the line rate → monitor-legal, but a lower rate makes
the reader slower → **bigger** skew → deeper buffer. So "drop lines" and "shallow buffer" pull opposite ways.

---

## Hard numbers established on hardware

- **Monitor line-rate window:** 44.4 kHz (H_TOTAL=1672) is **accepted** (it's the daily build).
  **45.86 kHz (H_TOTAL=1619) is rejected** ("no signal"). Standard 720p is 45.0 kHz. The accepted band
  is roughly **44–45.3 kHz**; 45.08 kHz was tried but only on a marginal build (inconclusive — retest).
- **No *exact* integer-frame solution exists** in the legal band for any reachable PLL combo — searched
  core clock, pixel clock (rpll_371m), and H_TOTAL jointly (see the search scripts in the session). Only
  **near-lock** is achievable. Best near-locks found:
  | clk_core | H_TOTAL | line kHz | frame lines N | jitter period | skew | buffer |
  |---|---|---|---|---|---|---|
  | 28.6875 | 1676 | 44.30 | 738.0008 | **~20 s** (≈imperceptible) | 15.6 | 20-line / 8 blocks |
  | 28.6875 | 1647 | 45.08 | 751.0 | ~1–2 s | 11.2 | 16-line / 4 blocks |
  | 28.5    | 1660 | 44.73 | 750.0 | ~1 s | ~9 | 16-line / 4 blocks |
- The near-perfect jitter (~20 s, H=1676) needs the **20-line FIFO** (8 blocks → 100% BSRAM → no room
  for anything else). The 16-line/4-block options free room but only reach ~1–2 s twitch.

---

## Build attempt log (this session)

| Build | clk_core | genlock | H_TOTAL (kHz) | FIFO | clk_pix Fmax | Result |
|---|---|---|---|---|---|---|
| 193674e | 28.6875 | baseline (vs_fall) | 1672 (44.4) | 32-line | 76.7 | ✅ boots, exact, ±1px **jitter** |
| 22:39 | 28.6875 | active-start | 1676 | 32-line | 74.44 | ❌ no boot |
| 23:05 | 28.6875 | active-start (**vs_rise**) | 1676 | 32-line | 82.5 | boots, ❌ **no image** (wrong vs edge?) |
| 23:16 | 28.6875 | active-start (vs_fall) | 1676 | 32-line | 73.6 | not flashed (sub-74.25) |
| 23:32 | 28.6875 | active-start (vs_fall) | 1676 | 24-line | **81.4** | ❌ **no boot** (comfortable clk_pix!) |
| 07:21 | 28.5 | active-start (vs_fall) | 1619 (45.86) | 16-line | 83.9 | boots, ❌ no image (45.86 rejected? or genlock?) |
| 09:08 | 28.6875 | baseline | 1647 (45.08) | 32-line | 74.87 | not flashed (marginal) |
| 09:37 | 28.6875 | baseline | 1647 (45.08) | 16-line | 74.35 | ❌ no signal (marginal clk_pix) |
| 09:50 | 28.5 | baseline | 1660 (44.73) | 16-line | **83.0** | ❌ **not booting** (comfortable clk_pix!) |

Preserved WIP commits on `scaler-exact-speed`: `d7bda07` (frame-lock WIP, active-start), `28b56bc`
(WIP2, active-start vs_fall + 24-line). `193674e` is the working exact+jitter baseline.

---

## THE OPEN MYSTERY (this is what we have NOT nailed)

**Builds 23:32 (81.4 MHz) and 09:50 (83.0 MHz) had comfortable `clk_pix` and still would not boot/config.**
This kills the "tight clk_pix → no config" theory. There is **no clean correlation** between any metric in
the reports (clk_pix Fmax, BSRAM %, VCO) and boot success. Until this is understood, every frame-lock build
is a coin-flip.

Things we changed that *might* be the real culprit (untested hypotheses):
- **16/24-line FIFO `ADDR_WIDTH`/`DEPTH` change** vs the 32-line baseline — does resizing the line-buffer
  BRAM displace or corrupt the **firmware BSRAM** init at the resource edge? (193674e=32-line boots;
  several 16/24-line builds don't — but 07:21 *did* boot with a 16-line variant, so it's not clean.)
- **PLL at clk_core 28.5 MHz** uses `IDIV_SEL=8` (÷9) → PFD = 3 MHz, possibly below the rPLL's minimum
  PFD → unreliable lock. (But 07:21 also used 28.5 and booted. Inconclusive — needs a PLL-lock check.)
- **active-start genlock (`frame_start`)** was *never confirmed to produce a valid image* — every build
  using it had a second confound (marginal clk_pix, 45.86 kHz, or no-boot). Its correctness is unverified.

---

## Next steps (in priority order) — for whoever resumes this

1. **Add boot/PLL diagnostics before any more frame-lock builds.** Drive LEDs from: `pll_core_locked`,
   `roms_loaded`, and a heartbeat on `clk_core`. Then "no image" vs "dead" is unambiguous, and we learn
   whether the core clock is even alive on the failing builds. *This is the cheapest way to break the
   coin-flip — do it first.*
2. **Isolate one variable at a time from the *known-good* 193674e.** Change ONLY the FIFO depth (32→16),
   rebuild, flash → does it still boot? Then ONLY H_TOTAL (1672→1647) → boot? Then ONLY clk_core
   (28.6875→28.5) → boot? We never did a clean one-variable isolation; we changed several at once each time.
3. **Verify the active-start genlock in isolation** at the *proven* 44.4 kHz / known-good clk_pix, so its
   "no image" results aren't confounded by line-rate or timing.
4. **Firmware BSRAM shrink** — the principled fix. Frees real headroom (the firmware is ~51–64 KB of ~103 KB)
   so the deep FIFO + frame-lock fit with margin and placement stops being a gamble. Enables the
   near-perfect H=1676 / 20 s-twitch / 20-line-FIFO config. Biggest effort, biggest payoff.
5. **Gowin placement seeds / options** — `clk_pix` swings 74–84 MHz run-to-run on the same logic; a
   placement seed sweep might reliably land the comfortable end without touching logic.

## What is NOT the problem (ruled out)
- Frame *buffer* / latency — we never used one; it's a line buffer (~0.5 ms).
- The exact-speed core itself — boots and runs fine at 28.6875 MHz (193674e).
- The near-frame-lock *math* — verified; H_TOTAL=1647→751 lines etc. are correct.
- `clk_pix` margin *alone* — comfortable-margin builds still failed (the open mystery above).
