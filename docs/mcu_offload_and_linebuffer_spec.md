# Spec: low-latency line-buffer video + robust SIO (lean path) — with optional MCU offload

Status: **proposal / design spec** (2026-06-18). Targets a post-v1.0 rearchitecture on a
branch; v1.0 (`8c6fc69`) stays the stable fallback throughout.

## Direction decision (2026-06-18) — keep it lean, self-contained

The user explicitly values the current design's **leanness: a single self-contained
bitstream, no companion-MCU firmware to build/flash/maintain, only a USB-to-UART controller
needed for input.** Offloading firmware to a BL616 (onboard or external M0S Dock) breaks that
— it either consumes the onboard BL616 (losing the JTAG/UART programming path) or adds an
external module, plus a whole second firmware codebase. So the **BL616 offload is demoted to
an OPTIONAL, DEFERRED track** (§MCU-OFFLOAD), pursued only if we ever hit a hard BSRAM wall.

Crucially, the wins that motivated this work are **separable from the offload**:

| Goal | Needs the BL616? |
|---|---|
| Low video latency (line buffer) | **No** — pure FPGA RTL |
| Robust SIO (no dropped commands) | **No** — `sio_device.vhdl` + our existing PicoRV32 |
| Free SDRAM bandwidth / relax HDMI timing | **No** — falls out of dropping the frame buffer |
| Reclaim the 32 BSRAM firmware blocks | **Yes** — the only offload-only payoff |

We ship fine today at 42/46 BSRAM blocks, and the line-buffer change is net-neutral-to-positive
on BSRAM, so the 32-block reclaim isn't worth its cost yet. **Recommended scope = the lean path
below; leave the firmware in BSRAM.**

## Why (the lean path)

v1.0's pain is self-imposed, and two of the three causes are fixable without touching the
self-contained model:

1. A **frame-buffer video path** (`fb_writer` → SDRAM → `fb_reader`) round-trips every frame
   through the one shared SDRAM: doubles video bandwidth, adds ~1 frame of lag + a tear line +
   the green-ghost burst constraints + razor-thin HDMI timing. → **Replace with a genlocked
   scandoubler line buffer** (§VIDEO): latency ~16 ms → <1 ms, no tear, video SDRAM traffic
   gone, HDMI timing relaxed. **No MCU.**
2. **SIO is bit-banged in PicoRV32 firmware** — the real-time path is in software, which drops
   commands under load (the menu-stuck-on-Boot-OS symptom). → **Graft `sio_device.vhdl`**
   (§SIO): a hardware SIO command-capture + dedicated-POKEY UART front-end moves the real-time
   path into the fabric; the PicoRV32 keeps only the slow sector lookup. **No MCU.**
3. The **MiSTer VHDL core ported verbatim** (resource-hungry; `rtl/` untouchable) — accept as-is.

The offload (cause "firmware eats 32 BSRAM blocks") is documented in §MCU-OFFLOAD but not part
of the recommended scope.

## §MCU-OFFLOAD (OPTIONAL, DEFERRED) — reference architecture

> **This section and the next ("Target architecture") describe the optional BL616 offload
> only.** The recommended lean path (§VIDEO + §SIO) needs none of it and keeps the PicoRV32
> firmware in BSRAM. Read this only if a future hard BSRAM wall forces reclaiming the 32
> firmware blocks. The lean design sections resume at "SIO disk emulation" below.

Repo `MiSTle-Dev/MiSTeryNano` + firmware `MiSTle-Dev/FPGA-Companion`. Key facts we confirmed
by reading the source:

- **SD card stays on the FPGA.** `src/misc/sd_card.v` + `sd_rw.v` + `sdcmd_ctrl.v` are an
  FPGA-side SD engine with a 512-byte sector buffer. It multiplexes the card between the core
  and the MCU. The **MCU does not touch SD hardware** — its FatFs `disk_read`/`disk_write` go
  over SPI to the FPGA, which performs the actual card I/O.
- **Logical→physical sector translation lives in the MCU.** The core requests a *disk-image*
  sector; that request is forwarded to the MCU, which (knowing the FAT cluster chain of the
  mounted file) returns the *physical card LBA*; the FPGA SD engine reads it. Quote from
  `sd_card.v`: *"the MCU translates sector numbers from those the core tries to use to
  physical ones inside the file system of the sd card."*
- **One half-duplex SPI link, MODE1**, demuxed by `src/misc/mcu_spi.v` into four byte
  channels by a command/id header: `sysctrl`, `hid`, `osd`, `sdc`. Signals: `spi_csn`,
  `spi_sclk`, bidirectional `spi_dat` with a `spi_dir` direction line, and `spi_irqn`
  (FPGA→MCU interrupt so the core can signal "I need a sector" / button events).
- **Onboard BL616 attach** reuses the JTAG + UART pins to synthesize this SPI (mainstream
  path is an external M0S Dock on dedicated header pins). The onboard path is supported
  (cf. C64Nano discussion #150) but changes the FPGA programming workflow (see Risks).
- FPGA companion modules we can adapt: `mcu_spi.v`, `sysctrl.v`, `hid.v`, `osd_u8g2.v`,
  `sd_card.v`/`sd_rw.v`/`sdcmd_ctrl.v`, `gowin_dpb/sector_dpram.v`. Firmware side:
  `sysctrl.c`, `sdc.c`, `osd_u8g2.c`, `hid*`, `spi.c` in `firmware/misterynano_fw/`.

## Target architecture — with the optional offload (§MCU-OFFLOAD)

*(The lean recommended target is simply v1.0 + the §VIDEO and §SIO changes — no SPI link, no
BL616, input and firmware unchanged. The diagram below shows the fuller offloaded variant.)*

```
                 ┌────────────────────────── Tang Nano 20k FPGA ──────────────────────────┐
  SD card ───────┤ sd_card.v (sd_rw) ── shared SD engine                                   │
                 │      │            ↘ sector_dpram (512B) ──► SIO HW engine ──► POKEY/core │
  USB kbd ───────┤ usb_hid_host / CH9350  (KEPT in fabric — input stays here)              │
                 │      │                                                                   │
                 │ Atari core (rtl/, unchanged) ── video ──► scandoubler ──► HDMI (480p)    │
                 │      │                              ↑ genlocked, line buffer (BSRAM)      │
                 │ SDRAM: Atari RAM/ROM/cart only (no frame buffer)                          │
                 │      │                                                                   │
                 │ mcu_spi.v ── sysctrl / sdc / osd channels ── OSD overlay (MCU-driven)     │
                 └──────────┴─── SPI (csn,sclk,dat,dir,irqn) over JTAG/UART pins ───────────┘
                                              │
                            Onboard BL616 (FPGA-Companion firmware):
                            FatFs + image mgmt + menu logic/render + config + sector xlate
```

**Split of responsibilities**

| Function | v1.0 (now) | Target |
|---|---|---|
| FAT32/exFAT + LFN browsing | PicoRV32 FatFs (BSRAM) | **BL616** FatFs, reads card via FPGA |
| OSD menu logic + rendering | PicoRV32 + `gowin_dpb_menu` | **BL616** (u8g2) → `osd` overlay in fabric |
| Config / cart-mode / reset regs | iosys regs | **BL616** via `sysctrl` channel |
| ATR sector → card LBA translation | PicoRV32 | **BL616** `sdc` channel |
| SD sector hardware I/O | `spi_sd.c` bit-bang | **FPGA** `sd_rw.v` (full-speed) |
| SIO protocol to POKEY | PicoRV32 firmware | **FPGA hardware FSM** (see §SIO) |
| Cart image load into SDRAM | PicoRV32 | **BL616** drives FPGA SD-DMA into cart window |
| USB/CH9350 keyboard + joystick | FPGA | **FPGA (unchanged)** — input is NOT offloaded |
| Video scaling | frame buffer 720p | **genlocked scandoubler 480p** |

Keeping **input in the fabric** is deliberate: the onboard BL616's only USB is the
programming/power port, so it cannot easily be a USB host. We already have a working USB HID
host + CH9350 decoder — leave them. The FPGA forwards menu-relevant keys/stick to the BL616
over the `sysctrl` port FIFOs; the BL616 never needs USB.

## SIO disk emulation (§SIO) — lean path, no MCU

**Accurate current architecture (verified 2026-06-18 — corrects an earlier over-statement).**
We are NOT bit-banging SIO. `rtl/common/sioemu/sio_handler.vhdl` (Mark Watson 2017, *newer* than
the 2013 `sio_device.vhdl`) is a hardware byte-UART: TX FIFO, RX FIFO, baud divisor, framing
error, hardware `p2s`/`s2p` shifters. Each RX byte is tagged with a `command_active` bit. What
is in **software** is only **5-byte command-frame assembly + dispatch**: `sio_poll()` drains the
RX FIFO, counts bytes into `sio_cmd_buf[0..4]` (`sio_cmd_idx`), checks the checksum, dispatches,
with 50 ms/200 ms timeout-resync heuristics. When the PicoRV32 is busy (menu/USB/long SD op) it
dispatches late and blows the **~16 ms command-to-ACK window**, or the software assembly
desyncs → the dropped-command / menu-stuck-on-Boot-OS bug.

**Phase B = move frame assembly + validation into hardware; firmware polls one flag.** That is
`sio_device.vhdl`'s distinctive feature (command-capture FSM + `ready` flag at reg `0x15`). We
adopt the **concept**, not the module: `sio_device` is older, owns its own POKEY (would fight
`sio_handler` over `SIO_DATA_IN`), and lacks our FIFO data path; and `rtl/` is no-touch. So the
capture block is a small **new `src/` module**, read-only on the SIO bus, alongside the
unchanged `sio_handler`.

**New module `src/sio_cmd_capture.sv`** (sys_clk domain, read-only). Reads the already-synchronized
`sio_command_sys` + `sio_txd_sys` (+ divisor); a command-gated UART-RX assembles the 5-byte
frame, verifies the checksum, and latches it on command-line release. iosys registers:
- `reg_sio_cmd0..4` (R): the 5 latched bytes (stable while `ready`).
- `reg_sio_cmd_status` (R): bit0 `ready`, bit1 `checksum_ok`, bit2 `overrun`, bit7 `cmd line
  active`, bits[15:8] `seq` (monotonic, lets firmware detect a *new* frame race-free).
- `reg_sio_cmd_ack` (W): clear `ready`, re-arm.

**Handshake (per command):** Atari shifts the 5 bytes → capture latches them, `ready=1`, `seq++`
on COMMAND release → firmware (in any loop) polls `status`, on `ready && seq!=last` reads
`cmd0..4`, pushes the ACK byte to the existing `sio_handler` TX FIFO, does the ATR-sector→LBA
lookup + SD read it already does, streams COMPLETE+data+checksum via the TX FIFO, then writes
`reg_sio_cmd_ack`. The slow path is now safe because the only deadline (command→ACK ~16 ms) is
met simply by polling faster than 16 ms — no FIFO drain / assembly / resync in the critical path.

**Firmware change:** delete the byte-accumulator (`sio_cmd_buf` fill, `sio_cmd_idx`, the
50/200 ms resync, per-byte command drain); replace with the `ready`/`seq` poll above. **Keep
unchanged** the whole dispatch + data phase (`sio_process_command` ACK/COMPLETE/sector bytes via
the `sio_handler` TX FIFO, incl. the da6b187 1-byte-TX-holding-reg fix) — that part works; it's
not the fragile bit. Wire `sio_cmd_capture` into the iosys decode in `iosys_picorv32.v`; reuse
the existing `sio_command_sys`/`sio_txd_sys` syncs in `tang_top.sv`. No change to `sio_handler`
or `rtl/`. Keep the old software-assembly path behind a compile flag until the HW path is proven
(the module is non-intrusive/read-only → clean A/B).

(In the optional offload, the *same* capture block is polled by the BL616 over `sysctrl`/`sdc` +
`spi_irqn` instead of the PicoRV32 — the hardware front-end is identical either way.) Detailed
sketch lives in this section; gates Phase B.

## Generic-core comparison (`../Atari800`, 2026-06-18)

We checked whether the generic foft/scrameta core (AtlasFPGA fork — the ancestor we *didn't*
start from) has changes worth adopting. Conclusion:

- **Do NOT switch the core or back-port shared files.** The generic core is an older snapshot:
  `cart_logic.vhd` 416 vs our 990 lines (we'd lose most of our 49 mappers), `gtia.vhdl` 1596
  vs 2128 (lose VBXE/Altirra palette), `atari800core.vhd` 656 vs 885. We also have files it
  lacks: `vbxe*.vhdl`, `ultime.vhdl` (U1MB), `covox.vhd`, `pbi_rom.vhdl`. The MiSTer base was
  the right choice for the emulation core.
- **Take exactly one thing: `sio_device.vhdl`** (see §SIO above) — the hardware SIO front-end
  the MiSTer port dropped. It is the single highest-value artifact in the generic tree for us.
- The generic core's **ZPU** softcore (`rtl/common/zpu/`) is its in-fabric IO brain — we
  explicitly do NOT want it (it's the softcore-in-fabric we're removing), but reading how the
  ZPU drives `sio_device` documents exactly what the BL616 must do over SPI.

## Low-latency video (§VIDEO)

Replace `fb_writer` + SDRAM frame buffer + `fb_reader` with a **genlocked scandoubler**:
a 1–2 line BSRAM buffer; output pixel clock derived (PLL) from the core so the **output frame
rate exactly follows the Atari** — no buffer, no tear, no frame of lag (~1–2 scanlines ≈ tens
of µs).

**Why this avoids the old genlock dead-end.** `docs/exact_speed_scaler.md` / the project
memory record that genlock was abandoned because monitors rejected the non-standard
exact-speed timing (the native ~786-line frame). Root cause in hindsight: that target did not
**integer-divide** the Atari's 262-line NTSC frame, forcing a non-standard line count. The fix
is to pick a standard CEA mode that *does*:

- Atari NTSC ≈ 15.7 kHz line, 262 lines, 59.94 Hz.
- Scandouble (each source line emitted twice): 31.5 kHz, ~525 lines, 59.94 Hz =
  **720×480p @ 59.94 (CEA-861 VIC 2/3)** — a universally supported HDMI mode, and its
  *nominal* rate is already 59.94, so genlocking to the Atari produces an **in-spec** signal.
- Horizontal: 2× with pillarbox (Atari active ~336–352 px in 720). Optional scanline dimming
  on the doubled lines (looks authentic on a CRT-style display).

480p is the natural target precisely because 262×2 ≈ 525 is integer; 720p would need 3×
vertical (262×3 = 786 ≠ 750) — non-integer, i.e. the very thing that failed before.

**Concrete template: the generic core's scandoubler (verified 2026-06-18).** The foft/scrameta
core at `../Atari800` already implements exactly this architecture in
`rtl/atlas/hdmi/scandoubler_hdmi.vhdl` (+ `scandouble_ram_infer_9.vhdl`), same author/style as
the rest of our `rtl/`. It is a genlocked **ping-pong** scandoubler: two line RAMs; one is
written at the input rate while the other is read out **twice** at 2× rate (`buffer_select`
toggles per line). Output `hsync`/`vsync` are generated by internal counters *triggered from
the input* sync → the output frame is locked to the Atari, ~1 scanline of latency, no tear,
**no SDRAM in the video path at all**. Adopt this as the starting point. Two design choices to
carry over, plus one to improve:

- **Carry over — store the GTIA colour *code*, apply the palette on readout.** Their line RAM
  is **9 bits** (`blank & colour_in[7:0]`); the 8-bit code is converted to RGB only on the
  output side. This is strictly better than our current RGB332: a tiny buffer **and full
  colour fidelity** (no quantization banding). The GTIA palette LUT lives in one place on the
  output side. We feed the scandoubler GTIA's raw `colour`/`hsync`/`vsync`/`blank`, not RGB.
- **Carry over — synchronous genlock from one PLL** (pixel clock locked to the core), ping-pong
  line buffer, optional `scanlines_on` dimming for the CRT look.
- **Improve — standard-mode counters.** Their weakness is a non-standard ~28.32 MHz pixel clock
  (pixel = ½ core), i.e. the exact non-standard-timing trap that bit us before. Keep their
  synchronous-genlock *architecture* but drive the **output sync counters to standard 480p59.94
  totals (858×525)** at the Atari's true refresh. The line buffer absorbs the input↔output rate
  difference *within each line*, so the pixel clock need NOT be a clean integer multiple of the
  core — only fast enough to emit two output lines per input line. That decoupling is what lets
  us hit a standard CEA mode while still genlocking → their low lag **and** our compatibility.

(MiSTeryNano's `src/misc/scandoubler.v` + `video2hdmi.v` are an alternative Verilog template,
but the generic core's VHDL is the closer fit since it already targets our exact GTIA signals.)

**Keep the 720p frame-buffer path as a fallback build** (it is proven to display everywhere).
Make genlocked-480p the default; a build flag selects the old path if a user's display is
fussy. This also de-risks the migration: video and MCU offload can land independently.

### Phase A concrete design (verified against our tree 2026-06-18)

**480p is an integer 2×2 of our source.** Capture is 352×240 today. 480p active = 720×480:
vertical 240×2 = 480 exactly; horizontal 352×2 = 704 centered in 720 → 8 px pillarbox each
side. No fractional scaling on either axis — every Atari pixel becomes a clean 2×2 block. (This
is the deciding advantage over 720p, which forced the non-integer 3× that caused the old
786-line dead-end.)

**Clocking — reuse repo assets, free a PLL.** 480p59.94 = pixel 27.000 MHz, Htotal 858, Vtotal
525, serializer ×5 = 135 MHz:
- `clk_5x` 135 MHz ← **`src/rpll_135m.v`** (already in tree, from the 27 MHz osc).
- `clk_pix` 27.0 MHz ← `clk_5x ÷ 5` via CLKDIV — same structure as today's 371→74.25, just
  smaller. **Frees `rpll_371m`.** `clk_core` (28.6875, `rpll_108m`) unchanged.

**Source signals — set the core generic `palette` 1→0** (a `tang_top.sv` instantiation change,
NOT an `rtl/` edit; confirmed at `atari800core_simple_sdram.vhd:34`, *"0: gtia colour on
VIDEO_B"*). Then `VIDEO_B[7:0]` carries the raw **GTIA colour code** (store 8-bit in the line
buffer), and on the read side **instantiate `gtia_palette.vhdl`** (`ATARI_COLOUR→RGB888`,
`PAL=0`) for full Altirra fidelity, no RGB332 banding. Genlock/timing taps already exported:
`VIDEO_PIXCE`, `VIDEO_HS`, `VIDEO_BLANK`, `VIDEO_START_OF_FIELD`.
*Fallback:* keep `palette=1` + store RGB (12-bit line buffer) — use if `palette=0` clashes with
**VBXE** (VBXE emits RGB that bypasses the colour-code path; palette-on-readout can't carry it).

**Module `src/scandoubler_480p.sv`** replaces `fb_writer` + `fb_reader` + the SDRAM FB client
(arbiter 4→3). Ping-pong line buffer:
- WRITE (clk_core, gated by `VIDEO_PIXCE`): `linebuf[wsel][col] <= VIDEO_B`; at `VIDEO_HS`
  `wsel^=1, col<=0`; at SOF reset to line 0.
- READ (clk_pix): 480p counters (858×525); for output line `oy`, src line `oy>>1`; for output
  px `ox` in the 704 window, src col `ox>>1` → `gtia_palette` → RGB → OSD mix → HDMI. Read stays
  ~1 source line behind write ⇒ **~1 scanline latency**.
- GENLOCK: output vertical counter **snaps to top-of-frame on each Atari `VIDEO_START_OF_FIELD`**
  (CDC clk_core→clk_pix via a toggle, like `fb_reader`'s `frame_start`). Atari 59.92 Hz vs 480p
  nominal 59.94 differ 0.03% → the snap is a sub-line nudge in vblank, invisible, no tear.
- OSD: emit `osd_x/osd_y` from the read counters exactly as `fb_reader` does (`tang_top.sv:1255,
  847`) so the firmware-driven OSD overlay path is unchanged.

**Verify:** (1) target display accepts 480p59.94 at the genlocked ~59.92 — keep the 720p build
behind a flag as universal fallback; (2) re-check the TMDS canary on the 135/27 pair (should
improve); (3) scope read-vs-write line lead to confirm the SOF snap lands in vblank and the
picture is steady; (4) pick colour-code vs store-RGB per VBXE decision.

## Phasing

Do this on a branch; never break the v1.0 fallback. Each phase ends hardware-verified, with
the **HDMI TMDS slack canary** checked (it should get *easier*, not harder, as load drops).
The two changes are independent — land them in either order.

### Recommended (lean) track — no MCU, stays self-contained

- **Phase A — video (§VIDEO, see "Phase A concrete design").** Switch HDMI clocks to 135/27
  (`rpll_135m` + ÷5, frees `rpll_371m`); set core `palette=0` (GTIA code on `VIDEO_B`); add
  `src/scandoubler_480p.sv` (ping-pong line buffer, write clk_core/PIXCE, read clk_pix 2×2,
  genlock-snap on `VIDEO_START_OF_FIELD`, `gtia_palette` on readout, emits `osd_x/osd_y`).
  Remove `fb_writer`/`fb_reader` + SDRAM FB client → arbiter 4→3. Gate the old 720p
  frame-buffer path behind a build flag. Verify on a real display + canary + fallback build.
- **Phase B — SIO (§SIO).** Add `src/sio_cmd_capture.sv` (hardware 5-byte command-frame latch +
  `ready`/`seq` flags, read-only, fed by the existing `sio_command_sys`/`sio_txd_sys` syncs);
  wire its registers into `iosys_picorv32.v`. Rework `sio_poll()` from software frame-assembly
  to a `ready`/`seq` poll; keep `sio_process_command`'s dispatch + TX-FIFO data phase unchanged.
  `sio_handler.vhdl` and `rtl/` untouched. Verify multi-sector loads, D1:/D2:, and the
  menu-stuck-on-Boot-OS repro; keep the old software path behind a compile flag until proven.
- **Phase C — release.** Confirm BSRAM/timing/canary healthy, update README + CLAUDE.md, cut a
  release. v1.0 remains the documented fallback.

### Optional (deferred) track — BL616 offload (§MCU-OFFLOAD)

Pursue only if a future feature hits a hard BSRAM wall and the 32 firmware blocks must be
reclaimed. Accepts the lean-design and programming-workflow costs in §Risks.

- **O0 — decide attach** (onboard BL616 vs external M0S Dock) and accept the new flash workflow.
- **O1 — MCU link.** `mcu_spi.v` + `sysctrl.v` + pins; FPGA-Companion on the BL616; prove a
  `sysctrl` round-trip. PicoRV32 still present.
- **O2 — storage + menu.** `sd_card.v`/`sd_rw.v` shared SD engine + `sdc` channel; move FatFs +
  browsing + menu to the BL616 (`osd` overlay replaces `gowin_dpb_menu`). Reclaim 32 BSRAM
  blocks. The `sio_device` front-end from Phase B is now polled by the BL616 instead of the
  PicoRV32 (front-end unchanged). Cart load moves to the BL616 + FPGA SD-DMA.
- **O3 — retire PicoRV32, release.**

## Risks / open decisions

**Lean track:**
1. **480p genlock display compatibility.** The one real risk on the lean path. Mitigated by
   targeting a standard CEA mode (480p59.94, 858×525) rather than the generic core's
   non-standard pixel clock, and by keeping the 720p frame-buffer fallback build behind a flag.
2. **`sio_device.vhdl` graft.** Low risk — deps present, compiles as-is — but verify the
   PicoRV32↔`sio_device` register handshake meets SIO ACK timing under load before retiring the
   old path. Keep the software SIO behind a flag until the hardware path is proven.
3. **HDMI canary.** Any RTL change can perturb placement; check the TMDS slack each build. This
   change *removes* load, so it should help — but verify, don't assume.

**Optional offload track only (§MCU-OFFLOAD):**
4. **Onboard-BL616 programming workflow (the reason this track is deferred).** Reflashing the
   onboard BL616 with FPGA-Companion repurposes the JTAG/UART pins it normally uses to program
   the FPGA, requiring an external programmer / `m0s_debugger` afterward — and adds a second
   firmware codebase. This is exactly the leanness the user wants to keep, so the track is
   off the table unless a hard BSRAM wall forces it.

**General:** strictly branch-only; keep `main`/v1.0 stable; land Phase A and Phase B as
independent, separately-verifiable steps so neither blocks the other.

## What we reclaim

**Lean track (Phases A+B) — the recommended scope:**
- Latency: ~16 ms + tear → <1 ms, no tear — the accuracy win, the main goal.
- SDRAM: the two video clients (`fb_writer`/`fb_reader`) gone → ~half the bandwidth freed;
  green-ghost burst rules moot; arbiter simpler (4→3 clients).
- BSRAM: `fb_reader` 4-line cache freed; small scandoubler ping-pong line buffer + SIO sector
  buffer added → net neutral-to-positive. (Firmware's 32 blocks stay — by choice.)
- HDMI timing: no clk_core↔clk_pix CDC through SDRAM → the TMDS slack canary should recover
  comfortably (the right-column-garbage fix likely becomes landable).
- SIO robustness: real-time path in hardware → no dropped commands; menu-stuck bug expected gone.
- **Self-containment preserved:** one bitstream, PicoRV32 firmware, USB2UART input — unchanged.

**Optional offload track (§MCU-OFFLOAD), only if ever taken:**
- The additional ~32 BSRAM blocks (PicoRV32+FatFs) + `gowin_dpb_menu` RAM — at the cost of the
  BL616 dependency and programming-workflow change above.
```
