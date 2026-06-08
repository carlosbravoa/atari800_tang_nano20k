# Frame-buffer plan — exact speed + rock-steady standard 720p60

**Goal:** exact NTSC Atari speed AND a flicker-free picture that locks on *any* monitor.
**Why this and not more tuning:** see `docs/exact_speed_scaler.md` — the genlocked line-buffer is proven
to be unable to deliver this (no integer-frame clock exists in the monitor's razor-thin tolerance window).
The only fix is to **decouple** the Atari's 59.92 Hz from the HDMI output and emit **textbook 720p60**
(1650×750, 60.00 Hz, CEA VIC 4) that every monitor recognizes solidly.

---

## Core idea
- The Atari **writes** each video frame into an SDRAM **frame buffer** at its own 59.92 Hz.
- The HDMI side **reads** that buffer out on a **free-running, standard 720p60** raster (60.00 Hz).
- The two are asynchronous; **double-buffer** the frame and swap on the *reader's* VSync, so the reader
  always shows the most-recent *complete* frame. The 59.92↔60.00 Hz mismatch → the reader repeats one
  frame about **every ~12 s** (1 / (60.00−59.92)). Imperceptible, and **no tearing** (swap in blanking).

This is *not* the old slow-controller frame buffer the code warns about — that warning predates the fast
NESTang SDRAM controller. The bandwidth is now available (below).

## What changes vs today
- `scale720p.sv` genlock + line-FIFO read → replaced by: (a) a **writer** (Atari→SDRAM) and (b) a
  **reader** (SDRAM→line cache→standard 720p60). The 3× H/V upscale and pillarbox stay.
- The deep line-FIFO **goes away** — the reader only needs a **1–2 line cache** in BRAM (fetch a source
  line from SDRAM once, repeat it 3× horizontally/vertically from the cache). So this *reduces* BRAM
  pressure rather than adding to it. (No more 100% BSRAM fights.)
- The SDRAM **arbiter gains a third client** (video). It already has core + iosys; add FB-write/FB-read.

## SDRAM geometry & buffer
- Store the **source** frame (not the upscaled 720p): ~**352 cols × 240 rows × 1 byte** (RGB332) ≈ 84 KB.
  Double-buffer ≈ **168 KB** — trivial in the 8 MB SDRAM. Place it above the Atari's RAM/ROM region
  (e.g. base 0x200000), well clear of the 130XE 128 KB + ROMs.
- Reader fetches one source line (≈88 × 32-bit words) per *source* line, 240 source lines per output
  frame, into the line cache; horizontal ×3 and vertical ×3 come from the cache (no re-fetch).

## Bandwidth budget (clk_core 28.6875 MHz, NESTang ~5-cycle 32-bit access ⇒ ~5.7M acc/s ceiling)
| Client | accesses/s | cycles/s | % of 28.69M |
|---|---|---|---|
| Atari core (≈1.79 MHz, ~1 acc/machine-cycle) | ~1.79M | ~9.0M | 31% |
| FB write (352×240 ÷4 × 59.92) | ~1.27M | ~6.3M | 22% |
| FB read (240 lines × 88 words × 60) | ~1.27M | ~6.3M | 22% |
| **Total (+ refresh/arbiter overhead)** | | **~22–24M** | **~80–85%** |

**Feasible but tight.** This ~80% figure is the project's central risk — *measure it first* (Stage 0).
Both video clients are hard-real-time (must hit their deadlines), so the arbiter must interleave them with
the core without starving any. Headroom levers if needed: burst reads in the controller; pack 2 px/byte
less aggressively; or run the SDRAM on a faster dedicated clock (CDC).

## Latency
Up to ~1 frame (reader shows the last *completed* write buffer) ≈ **16–33 ms**. Fine for most Atari use;
perceptible only in twitch titles. This is the price for a rock-solid image — and the reason the old
line-buffer existed. Acceptable given the alternative is flicker/no-lock.

## Implementation stages (each independently verifiable)
- **Stage 0 — bandwidth proof.** Instrument the arbiter to log idle SDRAM cycles at exact speed *before*
  building anything. If there isn't ~20%+ idle, stop and reconsider (burst/faster-SDRAM-clock first).
- **Stage 1 — writer.** Add Atari-video→SDRAM write path + 3rd arbiter client. Verify the machine still
  boots and runs (writes must not starve the core). No display change yet.
- **Stage 2 — reader.** Free-running standard 720p60 raster + SDRAM→line-cache read + 3× upscale, reading
  a fixed (single) buffer. Expect a solid, locked picture (maybe tearing without double-buffer yet).
- **Stage 3 — double-buffer + swap-on-read-VSync.** Tearing gone; frame-repeat absorbs 59.92↔60.00.
- **Stage 4 — exact-speed clock** (clk_core 28.6875 MHz). HDMI stays textbook 720p60 regardless → exact
  speed + steady + both monitors. Re-check bandwidth at the final clock.

## Risks / open questions
- **Bandwidth (~80%)** — the make-or-break; Stage 0 settles it.
- **3-client real-time arbiter** — core + two video streams; design the priority/deadlines carefully.
- **CDC** — writer on clk_core, reader on clk_pixel, buffer-swap handshake across domains.
- **Standard-mode acceptance** — emit exact CEA-861 720p60 (1650/750, correct sync polarities) so monitors
  EDID-match it; this is the whole point (no more razor-thin window).

## What this retires
Once the reader emits standard 720p60, the genlock, the line-FIFO depth wars, the H_TOTAL/near-lock search,
and the clk_pix-margin chase are all **moot** — the output timing is fixed and standard, independent of the
Atari clock. That's why this is the *correct* fix rather than another tuning pass.
