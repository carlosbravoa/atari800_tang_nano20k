# FujiNet on ESP32, wired directly to the Tang Nano 20K — feasibility analysis

*2026-07-16 — analysis only, nothing implemented. Companion to the user notes in
`~/devel/fpga/atari800-tangnano-notes/atari800-tang-esp32.txt` (referred to as "the notes"
below; a few corrections to them are flagged inline).*

## TL;DR

**Very feasible, and cheap on the FPGA side.** The upstream core wrapper
(`atari800core_simple_sdram`) already exposes every SIO signal FujiNet needs as a port, and
`tang_top.sv` already has them on named wires (the peripheral side is currently consumed by
our internal PicoRV32 disk emulation). The whole bridge is: **3–6 FPGA pins routed out, one
AND gate on the core's RX line, two tie-highs replaced with synced inputs, and a CST edit.**
No changes under `rtl/`. Electrically it is a straight 3.3 V ↔ 3.3 V wire job.

The two real costs are not the wiring:
1. **Any RTL change re-rolls placement** → the HDMI cold-blackout canary must be re-checked
   (this is a netlist change, unlike the recent firmware-only builds).
2. **Coexistence policy** between FujiNet drives and our internal D1:/D2: emulation needs a
   firmware/OSD rule, and firmware BSRAM headroom is currently ~150 bytes — even a small OSD
   toggle probably wants the (block-free but netlist-touching) 48→64 KB BSRAM bump first.

## 1. What the core already gives us

From `rtl/common/a8core/atari800core_simple_sdram.vhd` (ports, with their real directions —
**note: the notes' table has PROCEED/INTERRUPT backwards**; they are *inputs to the Atari*,
driven by the peripheral):

| Port | Dir (core) | Real-Atari meaning | FujiNet use | Today in `tang_top.sv` |
|---|---|---|---|---|
| `SIO_COMMAND` | out | command frame active (low) | **required** | `sio_command` wire → internal snoop |
| `SIO_TXD` | out | Atari → peripheral data | **required** (ESP32 RX) | `sio_txd` wire → internal snoop |
| `SIO_RXD` | in | peripheral → Atari data | **required** (ESP32 TX) | driven by `sio_rx_data_in` (PicoRV32 handler) |
| `SIO_PROC` | in | PROCEED, → PIA CA1 | optional (N:/notification) | tied `1'b1` |
| `SIO_IRQ` | in | INTERRUPT, → PIA CB1 | optional | tied `1'b1` |
| `SIO_MOTOR` | out | cassette motor | optional (CAS emu) | `sio_motor` wire (unused off-chip) |
| `SIO_CLOCK` / `SIO_CLOCK_IN` | out / in | sync-serial clocks | not used by FujiNet disks | out unused / in tied `1'b1` |
| `TAPE_AUDIO` | in (8-bit) | cassette audio | optional (CAS audio) | tied `8'h00` |

Minimum viable bridge = **3 pins** (COMMAND, TXD, RXD) + GND.
Comfortable bridge = **5 pins** (+ PROCEED, INTERRUPT).
Full-fat = **6–7** (+ MOTOR, and audio if ever wanted — audio would go into the POKEY mix,
not a pin, see §6).

## 2. RTL changes (all in `src/`, `rtl/` untouched)

```
                      ┌───────────────────────────────┐
  Atari core          │ tang_top.sv                   │        ESP32 (FujiNet fw)
  SIO_TXD ────────────┼──►(existing snoop) ──► pin ───┼──────► SIO RX  (UART)
  SIO_COMMAND ────────┼──►(existing snoop) ──► pin ───┼──────► CMD
  SIO_RXD ◄── AND ◄───┼── sio_rx_data_in (PicoRV32)   │
               ▲      │                               │
               └──────┼──── 2-FF sync ◄──── pin ◄─────┼─────── SIO TX  (UART)
  SIO_PROC ◄── sync ◄─┼─────────────────── pin ◄──────┼─────── PROCEED   (opt.)
  SIO_IRQ  ◄── sync ◄─┼─────────────────── pin ◄──────┼─────── INTERRUPT (opt.)
  SIO_MOTOR ──────────┼─────────────────── pin ───────┼──────► MOTOR     (opt.)
```

1. **RX wire-AND** (the one functional change): the real SIO bus is effectively open-collector
   with idle-high — multiple peripherals AND onto the same line. Replace
   `.SIO_RXD(sio_rx_data_in)` with `.SIO_RXD(sio_rx_data_in & ext_sio_rx_sync)`.
   The internal handler's output is already treated as an async serial line by the core
   (POKEY oversamples it), so a plain 2-FF synchronizer on the external pin matches the
   existing discipline.
2. **Outputs**: route `sio_command` and `sio_txd` to output pins (they already exist as
   wires; the internal snoop keeps working unchanged in parallel).
3. **Optional inputs**: replace the `1'b1` ties on `SIO_PROC`/`SIO_IRQ` with 2-FF-synced,
   pulled-up input pins. Idle high = today's behavior, so an unconnected ESP32 is harmless.
4. **CST**: add the pins as `LVCMOS33`, `PULL_MODE=UP` on all inputs (idle-high bus).

Estimated diff: ~25 lines in `tang_top.sv`, ~12 lines CST. No clock-domain novelty, no BSRAM,
no SDRAM interaction.

**Risk that dominates the RTL work: placement.** This is a real netlist change, so the HDMI
TMDS canary (worst SETUP slack on the `video_data` path, healthy ≥ ~0.5 ns, currently
2.398 ns) must be re-checked, with `place_option` rerolls available if it degrades. Budget a
build-verify-flash-soak cycle for this alone; do NOT bundle it with unrelated changes, so a
canary regression is attributable.

## 3. FPGA pin candidates

Hard rules from this board's history: pins 69–76/79 are BL616-driven (phantom inputs), 15/16
are PLL feedback pads, 51 is RPLL2_T_in — all off-limits. **The Tang_Nano_20K_3921 schematic
PDF is the authority for any new pin; verify every candidate there before wiring** (that rule
exists because of the months-long phantom-joystick hunt).

Currently used (from `constraints/tang_nano_20k.cst`): 4, 17–20, 25–42, 48, 49, 53, 57,
59–63, 77, 81–84, 87, 88.

Candidates, in preference order:

| Option | Pins freed/used | Trade-off |
|---|---|---|
| **A. Unused LCD-only header nets** | need 3–5 verified from schematic | Same class as the joystick nets (terminate at the unpopulated FPC connector) — zero conflict unless an RGB LCD is ever attached. Requires schematic session to pick exact numbers. |
| **B. Reclaim `audio_l`/`audio_r` (pins 25/26)** | 2 pins instantly | GPIO PDM audio dies; HDMI audio (primary path) unaffected. Good pair for COMMAND+TXD. |
| **C. Reclaim `usb_dm` (pin 49)** | 1 pin | Only if the direct-USB-HID keyboard path is truly retired (CH9350 UART on pin 53 is the supported path since v1.0). Check `usb_host_enable` OSD option usage first. |
| **D. Joystick pins** | up to 10 | Only if a FujiNet build variant is acceptable that drops physical joysticks — probably not; listed for completeness. |

A realistic phase-1 set with zero schematic work: **COMMAND=25, TXD=26 (option B), RXD=49
(option C)** — all already CST-known GPIO. PROCEED/INTERRUPT then wait for verified LCD-net
pins (option A) in phase 2.

## 4. ESP32 side

- **Voltage**: all our GPIO are LVCMOS33 → direct wiring, common GND, no level shifters.
  Recommend 100–220 Ω series resistors per line (protection + edge taming on jumper wires).
- **Pin map**: the notes list GPIO 13/14/12/15/2. **Do not trust that without checking** —
  FujiNet firmware pin maps are per-board-target headers in the `fujinet-firmware` repo
  (`include/pinmap/*.h`, e.g. `fujinet-v1.h` vs devkit variants). Pick the build target
  first, then wire to *its* map. Two ESP32 strapping-pin caveats regardless of map:
  - **GPIO 12** must be low at ESP32 reset (flash-voltage strap) — an idle-high SIO line
    parked on it can brick boot. If the chosen map really puts SIO data there, add a series
    resistor + only-drive-after-boot discipline, or pick a different build target.
  - **GPIO 2** must be floating/low for flashing.
- **Power**: ESP32 from its own USB supply first (Wi-Fi bursts ~500 mA). Sharing the Tang's
  5 V rail is a later convenience experiment.
- **SD card on the ESP32** (per the notes) is optional — FujiNet's main storage is
  Wi-Fi/TNFS; local SD is a nice-to-have.

## 5. Coexistence with the internal disk emulation — the actual design work

Both "drives" sit on the same wire-AND bus, exactly like chained real hardware. Collisions
happen only when the same device ID answers twice. Current firmware behavior is already
half-right: an **unmounted** internal slot stays silent (and the D1:/D2: object menus with
Detach already exist), so the phase-1 rule is simply:

> **Detach internal D1:/D2: when using FujiNet.** FujiNet's CONFIG then boots as D1: and
> everything behaves like a real FujiNet on a real Atari.

Refinements worth doing (phase 2, firmware):
1. **OSD "SIO: Internal / FujiNet" toggle** that hard-gates `sio_process_command()` (one
   `if`), so a mounted internal disk can't fight FujiNet even by accident. Persist in
   `atari.ini`.
2. The on-screen SIO activity indicator and LED2/LED4 watch the *Atari-side* lines, so they
   keep working for FujiNet traffic for free — nice.
3. The SIO debug line keeps working too (the snoop sees all command frames), which gives us
   protocol visibility into FujiNet transactions — genuinely useful for bring-up.

**Firmware budget warning**: BSRAM headroom is ~150 bytes right now. The toggle + ini key +
menu row will not fit comfortably; plan the **48→64 KB BSRAM depth bump** (free in Gowin
block-rounding, but a netlist change — conveniently, so is the pin work: do both in the same
canary-checked build).

## 6. Functional scope by phase

| Phase | Wires | Gets you | Effort |
|---|---|---|---|
| **1 — proof** | CMD, TXD, RXD, GND | FujiNet CONFIG boots from D1:, TNFS/ATR disk mounts, D: full function. High-speed SIO *probably* works (POKEY-divisor based; core POKEY serial is the faithful MiSTer one) — if flaky, set FujiNet to standard 19200. | ~25 lines RTL + CST + 1 canary-checked build. Rule: internal drives detached. |
| **2 — solid** | + PROCEED, INTERRUPT | N: network device interrupts, R: handler comfort; OSD toggle; README section. | Schematic session for 2 pins + firmware toggle (wants BSRAM bump). |
| **3 — complete** | + MOTOR (and TAPE_AUDIO mix internally) | C: cassette emulation incl. audio-through (`TAPE_AUDIO` port is sitting there tied to zero — feed it a PDM/level from the ESP32 audio line or just skip audio). | Small; only if cassette matters. |

## 7. Things that could bite (ranked)

1. **HDMI canary regression** from the netlist change — known, checkable, reroll-able.
2. **Device-ID collision UX** — solved by rule/toggle above, but a user WILL eventually mount
   internal D1 with FujiNet CONFIG attached; the toggle (phase 2) is the real fix.
3. **High-speed SIO timing** — FujiNet defaults to US-Doubler-style speeds. Our core is
   cycle-exact NTSC so it *should* be fine, but validate early and document the FujiNet
   fallback setting.
4. **ESP32 strapping pins** — check the actual pinmap header, not folklore (incl. the notes).
5. **Pin verification debt** — any option-A pin must be schematic-verified; do not repeat the
   pins-69-76 incident.
6. Long jumper wires at 19200–~68 kbaud are fine; keep under ~25 cm and grounded well anyway.

## 8. What this does NOT require

- No SIO connector, no level shifters, no changes under `rtl/`, no SDRAM/clock work, no
  firmware changes for phase 1 (the detach rule uses existing menus), no impact on the
  scandoubler/video path beyond the placement lottery every netlist change takes.

## 9. Suggested first session

1. Schematic pass → pick and verify 5 pins (or accept option B+C's 25/26/49 for 3-pin start).
2. `tang_top.sv` + CST edit (pins, AND gate, syncs) **plus** the BSRAM 48→64 KB bump in the
   same build; full verification protocol; flash; confirm HDMI stable + Atari boots + internal
   disks still work with nothing connected (idle-high inputs = no behavior change).
3. Wire ESP32 devkit flashed with the matching FujiNet target; detach internal drives; watch
   the SIO debug line for the first `d70`-style FujiNet device commands (FujiNet devices use
   IDs 0x31–0x38 for D:, 0x70 for the FujiNet control device) and let CONFIG boot.
