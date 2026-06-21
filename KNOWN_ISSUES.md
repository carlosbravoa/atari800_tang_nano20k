# Known issues

## Some PAL vertical-scrolling games glitch (this is an NTSC-only machine)

A few demanding titles show garbled sprites, a jumpy/jittery image, or freezes **during
play**:

- **Tiger Attack** (Atari UK, 1988) — sprites garbled; occasional freezes.
- **Astro Droid** (Red Rat Software, 1987) — vertical jitter; sprites garbled / wrong colours.

**Most likely cause: these are PAL games, and this build is NTSC-only.** Both are PAL
British budget titles built around **PAL ANTIC timing** (312 lines / 50 Hz) and aggressive
**per-frame vertical fine scrolling** (writing `VSCROL` mid-frame, often from display-list
interrupts). Run that on an **NTSC** machine (262 lines / 60 Hz) and the scroll regions,
DLI line targets and sprite vertical positions no longer line up → exactly these symptoms.
A real Atari (or MiSTer) set to **NTSC** would behave the same way.

It is **not a loading problem** (Astro Droid runs from cartridge; the issue is gameplay) and
**not a memory/video-path bug** on our side: the SDRAM crossing is synchronous and the core
stalls on a completion handshake, so it can't hand the CPU/ANTIC wrong data — slow SDRAM only
slows the machine, it doesn't corrupt it.

**Why other scrollers are fine:** games like **River Raid** are NTSC-friendly and use *coarse*
scrolling (one LMS-pointer update during VBLANK) — timing-insensitive — so they're unaffected.

### Status: PAL support is not planned
Switching the core to PAL is **not a simple flag**: it changes the machine clock (1.7734 vs
1.7898 MHz), which cascades through `clk_mem`/SDRAM, `clk_pix`/`clk_5x` and the **genlocked
scandoubler** (whose HDMI mode is hard-tuned to NTSC framing: 1216×786 = 3 × 262 lines; PAL's
312 lines would be 936 output lines = a different video mode and PLL). It's effectively a
second complete clock + video configuration. Given these are obscure PAL titles on an NTSC
reference machine, PAL support is **deferred / not planned**.

**To confirm the diagnosis:** run the same games on MiSTer (or a real Atari) **set to NTSC**.
If they glitch the same way → confirmed PAL/NTSC mismatch (nothing to fix here). If they run
clean on NTSC hardware → reopen as a core/wrapper investigation.
