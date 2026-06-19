# Phase A + B — testing & tuning guide

Branch: `feat/linebuffer-video-sio-hwcapture` (off `main` @ v1.0).
Built bitstream: `impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs` (Phase A, timing-clean,
TNS=0 on all clocks, worst path 22.8 ns). Spec: `docs/mcu_offload_and_linebuffer_spec.md`.

## What's in this build (flash `atari800_tn20k.fs`)

- **Phase A active: genlocked 480p59.94 scandoubler video.** ~1–2 scanline latency, no SDRAM
  frame buffer, full Altirra colour (palette on readout). HDMI runs 27 MHz pixel / 135 MHz
  serializer — the old ~0.4 ns TMDS canary danger is gone (now 22.8 ns).
- **Firmware = proven software SIO** (default). Disks should behave exactly as v1.0.
- **Phase B hardware present but dormant**: the SIO command-capture FSM is in the bitstream
  (read-only snoop, harmless) but the firmware doesn't use it yet (see below to enable).

## First power-on — what to look for

1. **HDMI locks as 480p (720×480 @ ~59.94).** If the display shows "no signal"/out of range:
   - Most likely **sync polarity**. 480p is nominally negative sync; this build outputs
     active-high (so `hdmi_audio_out`'s frame-reset logic works). If your display is strict,
     set `SYNC_ACTIVE_LOW=1` in `scandoubler_480p` **and** invert hs/vs only on the path to
     `hdmi.sv` inside `hdmi_audio_out.sv` (not the reset-detect path), then rebuild.
2. **Picture position / stability.** The genlock snaps the read raster to the Atari field each
   frame. If the picture rolls, sits too high/low, or tears:
   - Tune **`VSNAP`** (default 510) in `scandoubler_480p` — it sets where the read raster jumps
     to on each `VIDEO_START_OF_FIELD`, i.e. vertical position and the read-vs-write lead.
     Try values ~495–524. Wrong VSNAP = roll or a tear band.
   - Tune **`H_PIC_OFFSET`** (default 8) for horizontal centring in the pillarbox.
3. **Colours.** Full Altirra palette is applied on readout. If colours are wrong/monochrome,
   the `palette=0` → `VIDEO_B` colour-code path or the `gtia_palette` readout needs a look
   (synthesis kept it; verify on screen).
4. **Audio.** 48 kHz tick retuned for 27 MHz pixel. If pitch is off, the HDMI ACR CTS for
   480p may need adjustment in `hdmi.sv`/`hdmi_audio_out.sv` (secondary — video first).

All tuning knobs are parameters at the top of `src/scandoubler_480p.sv`.

## Enabling Phase B (hardware SIO capture) — optional, test after video

Rebuild firmware with the capture path, then rebuild the bitstream:

```
cd firmware && make EXTRA_CFLAGS=-DSIO_HW_CAPTURE   # Makefile now has the EXTRA_CFLAGS hook
cd .. && QT_QPA_PLATFORM=offscreen .../gw_sh.sh build.tcl
# flash impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs
```

Then verify multi-sector disk loads, D1:/D2:, and that the
"menu stuck after attach + Boot OS" symptom is gone. The hardware capture moves the
real-time command-frame assembly off the CPU; registers are `0x020000ac` (bytes) and
`0x020000b0` (status/seq + ack).

## Fallbacks

- **Known-good 720p video**: `git checkout main` (v1.0 frame-buffer build, displays anywhere).
- **Phase A only, no Phase B hardware**: it's already the default firmware — nothing to do.

## Not yet done (deliberately, low-risk staging)

- fb_writer/fb_reader are still instantiated (dead SDRAM clients). Removing them reclaims SDRAM
  bandwidth and simplifies the arbiter (4→3 clients) — do this only after the scandoubler is
  confirmed working on hardware, so the arbiter isn't touched while video is unverified.
- The BL616 MCU offload remains an optional/deferred track (not built); the lean path keeps
  everything self-contained.

## Build-verification snapshot (this build)

- Synthesis: no errors. TNS = 0.000 (Setup & Hold) on every clock.
- Worst real setup path 22.769 ns (was ~0.4–0.6 ns on the 720p TMDS canary).
- BSRAM 42/46, LUT 11269 — comfortable.
