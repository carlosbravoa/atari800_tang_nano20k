# Known issues

## A few .xex games show graphics glitches (under investigation)

Most games (`.atr`, `.car`, `.xex`) run perfectly. A small number of demanding titles
loaded as `.xex` show intermittent graphics glitches:

- **Astrodroid** — occasional vertical screen flicker; sprites sometimes garbled / wrong colours.
- **Tiger Attack** — sprites garbled; occasional freezes.

Inputs and general operation are unaffected. The intermittent nature points at real-time edge
cases (heavy ANTIC/player-missile usage) and/or imperfect loading rather than the video path.

**To isolate (TODO):** check whether these — or any — titles glitch the same way when loaded
as `.atr`/`.car`:

- glitches on `.atr`/`.car` too → it's the **core/video** (e.g. P/M emulation, or the genlock
  on exotic display lists), not the XEX loader.
- only on `.xex` → it's the **loader**, most likely the `$0600-$07FF` limitation: the boot
  loader runs at `$0700` and uses `$0600` as its sector buffer, so a program that *loads into*
  page 6/7 overwrites the running loader. Fix would be to relocate the loader into high RAM.
