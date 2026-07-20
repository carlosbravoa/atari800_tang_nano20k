# Known issues

## F12 (OSD menu) can be unresponsive while a PC serial session is engaged

With the PC Link actively engaged (v2.5+; e.g. a live keyboard session or app
connection), the F12 menu key on the physical keyboard sometimes doesn't open the
OSD. Workaround: the S2 button on the board always works, and closing the PC
session restores F12 immediately. Under investigation.


## FIXED (v2.4): disk writes were unreliable — ERROR 139, corrupted disks, could damage the SD card

Writing to mounted disks (SAVE from DOS/BASIC, formatting) was broken in several
stacked ways: writes to D2: failed with ERROR 139, "successful" writes could leave the
disk image's filesystem inconsistent, and — worst — long write sessions could corrupt
the **SD card's own FAT filesystem** (in extreme cases wiping it). Root causes, all
fixed in v2.4 and verified on hardware + a host-side FatFs test suite (`test/fatfs_host/`):

- the SIO write handler performed the slow SD write *before* sending the data-frame ACK,
  blowing the OS's ACK window → retry storms and half-applied multi-sector operations;
- a read-only mounted image failed writes with a bare NAK instead of reporting
  write-protect (now: auto-clear of PC-inherited read-only attributes, "(RO)" marker,
  status write-protect bit, error 144);
- mounting the same image on both drives created two write handles on one file
  (illegal in FatFs, can corrupt the volume — now the second mount is forced read-only);
- an out-of-range sector number made the firmware allocate the gap on the SD card
  (one bad sector number grew a 92 KB ATR to 8+ MB — now rejected like a real drive);
- a firmware stack overflow could corrupt filesystem state during deep menu operations
  (stack usage reduced; a canary now flags it on the OSD debug line).

If your SD card was damaged by an earlier version: reformat it (full FAT32) and recopy
your files. v2.4 also adds DOS FORMAT support and OSD "New blank disk" creation.

## FIXED: mode-8 fine scrolling stuttered (Ninja Commando / Draconus marquees)

Big-letter marquee scrollers (ANTIC mode 8 / GRAPHICS 3 with horizontal fine scroll)
moved in coarse 4-colour-clock jumps instead of gliding smoothly — on photos this read
as per-scanline "shear" of the moving band. Root cause: an upstream Atari800_MiSTer
ANTIC bug — HSCROL bit 1 was applied twice in the mode-8 pixel path (DMA fetch timing
*and* an extra shifter phase-select), summing to one full pixel period, i.e. no visible
effect. Fixed here (one line in `antic.vhdl`, `enable_shift` slow-shift case) and
hardware-verified 2026-07-04: Ninja Commando's title marquee now scrolls smoothly.
Only display lists using mode 8 *with* horizontal scrolling are affected by the change;
all other modes are bit-identical. (Current MiSTer still has this bug.)

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
