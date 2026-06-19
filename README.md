# Atari 800 — Tang Nano 20K Port

> This project started as a vibe-coding experiment with no shame. But now we have a full Atari800XL/130XE running with full NTSC Atari speed, low-latency jitter-free HDMI (now a genlocked line-buffer, with optional CRT scanlines), keyboard, joystick, ATR disks, cartridges and `.xex` executables, all on this really small device. It's a blast to play with. It took a lot of effort to get the coding agents focused on the right challenge/issue. Enjoy it (because I am)!


<img width="400" height="400" alt="Eureka! Atari running Montezuma from an ATR Disk" src="https://github.com/user-attachments/assets/20121280-905e-4c15-8795-352eec9abf01" />

_Eureka! Atari running Montezuma from an ATR Disk_

FPGA emulation of the Atari 800/800XL/65XE/130XE on the
[Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
(GW2AR-LV18QN88PC8/I7).

Based on the [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) core by Mark Watson,
adapted for the Gowin FPGA toolchain.

---

## ⚡ Minimum to get running

The absolute essentials — everything below this section is detail.

1. A **Sipeed Tang Nano 20K**.
2. A **FAT32 micro-SD** with `ATARIXL.ROM` (16384 B) and `BASIC.ROM` (8192 B) in the root
   (**you supply these ROMs**). Drop your `.atr` disks and `.car`/`.rom` cartridges on it too.
3. **Flash the bitstream** (firmware is baked in — nothing else to flash). Grab the zip from
   the [latest release](https://github.com/carlosbravoa/atari800_tang_nano20k/releases/latest)
   (or build it yourself, see [Build](#build)):
   ```bash
   openFPGALoader -b tangnano20k -f atari800_tn20k.fs
   ```
4. Plug in **HDMI** and the **SD card**, then **power on** → it auto-boots to **BASIC**.
5. Press **S2** (onboard button) to open the OSD. A **DB9 joystick on port 1** alone can drive it
   (no keyboard needed). To boot a disk: OSD → *D1:* → *Attach disk* → pick → *Hard Reset*.
   To run a cartridge: OSD → *Cart:* → *Attach cartridge* → pick (boots immediately).

That's a working machine. For a keyboard, the simplest is a **CH9350 USB-host board, one wire to
Pin 53** (see [Keyboard](#keyboard-input)) — with the optional **arrow-keys-as-joystick** mode,
the keyboard alone covers everything.

---

## Features

- **Atari 800 / 800XL / 65XE / 130XE** emulation (6502 CPU, ANTIC, GTIA, POKEY, PIA)
- **HDMI video — genlocked, low-latency, no frame buffer** (v2.0): the Atari frame is shown via a
  small line-buffer **scandoubler** (integer 3× → 1056×720 active, HD-class) whose pixel clock is
  **frequency-locked to the core**, so it's rock-steady (no jitter, no tear) with only ~1–2
  scanlines of latency — the SDRAM frame buffer is gone entirely
- **CRT scanlines** (OFF / 25 / 50 / 75 %) and **horizontal position** — both adjustable live in the OSD
- **HDMI audio** — 48 kHz stereo PCM in HDMI 1.3 data islands (no extra hardware)
- **GPIO audio** — sigma-delta PDM on GPIO pins (add RC filter for analogue)
- **On-chip SDRAM** — GW2AR-18 embedded 64 Mbit, custom controller
- **SD card ROM loader** — reads `ATARIXL.ROM` (16 KB) and `BASIC.ROM` (8 KB) at boot
- **On-Screen Display (OSD)** — file browser (24 entries/page), disk mount/unmount, options menu; driven by **keyboard and/or DB9 joystick**, toggled with the onboard **S2** button (or **F12**). The Atari keeps **running live behind the menu** (inputs are masked while it's open)
- **UART / serial keyboard** — raw USB HID reports over serial frames from a CH9350 USB-host board or Raspberry Pi Pico (one wire to Pin 53, no resistors); decoded in hardware, both CH9350 frame variants supported. **F9 = soft reset**, **F12 = OSD menu**
- **2 × Atari/Commodore DB9 joysticks** — active-low; wired to GPIO **pins** (no DB9 connectors on the board — see [wiring](#atari-db9-joystick); pins changed 2026-06: the old ones collided with the onboard BL616 MCU)
- **Arrow keys as joystick** — optional OSD toggle: arrow keys drive Joystick 1, **Left-Alt = fire** (for keyboard play; persists in `atari.ini`)
- **SIO disk emulation, two drives** — mount `.atr` and raw `.xfd` images as **D1: and D2:** from the SD card; live mount/swap while the machine runs
- **Cartridge loading** — `.car` (50 mapper types: XEGS, switchable XEGS, AtariMax, OSS, SDX, Williams, MegaCart up to 4 MB, SIC, Turbosoft…) and raw `.rom` (2/4/8/16K) from the SD card; select it and the machine cold-boots into the cart. Unsupported CAR types show their type id on screen
- **`.xex` executables** (v2.0) — boot Atari binary-load programs directly from the SD card: a baked-in 6502 loader is served as a virtual boot disk on D1:, handling the multi-segment `$FFFF`/INITAD/RUNAD format
- **Hardware SIO command capture** (v2.0) — the 5-byte SIO command frame is assembled in the FPGA, so disk loading no longer depends on the firmware polling in time
- **Long filenames** on the SD card (FatFs LFN); file browser with folders, 24 entries/page, instant Left/Right paging

---

## Status

| Feature | Status |
|---|---|
| Atari boot (BASIC) — auto-boots on power-on | ✅ Working |
| HDMI video — genlocked line-buffer, 1056×720 (3× integer), low-latency, no jitter/tear | ✅ Working |
| CRT scanlines (OFF/25/50/75 %) + horizontal position — live OSD options | ✅ Working |
| `.xex` executable loading (virtual-disk 6502 loader) | ✅ Working |
| Hardware SIO command-frame capture | ✅ Working |
| HDMI audio (48 kHz PCM) | ✅ Working |
| GPIO sigma-delta audio | ✅ Working |
| SD card ROM loader | ✅ Working |
| OSD menu (keyboard and/or DB9 joystick, S2/F12 toggle) | ✅ Working — rock-solid |
| UART / serial keyboard (CH9350 / Pi Pico) | ✅ Working (hardware decoder, both frame variants) |
| Long filenames (FatFs LFN) + folder browsing | ✅ Working |
| F9 soft-reset hotkey | ✅ Working |
| DB9 joystick (wired to GPIO pins) | ✅ Working |
| Arrow keys as Joystick 1 (OSD toggle, Left-Alt fire) | ✅ Working |
| SIO disk emulation (.atr / .xfd), **D1: + D2:** | ✅ Working — per-drive mount/unmount, live swap; SIO activity LEDs |
| Live OSD overlay (game runs behind menu, inputs masked) | ✅ Working |
| Core timing — exact NTSC speed (28.6875 MHz / `cycle_length=16`) | ✅ Working |
| Cartridge images (.car / .rom) | ✅ Working — 8K/16K, banked, and 4 MB MegaCart verified on hardware; 50 mapper types, up to 4 MB |

> **Architecture note — firmware runs from BSRAM:** The PicoRV32 IO subsystem (OSD, SD
> access, keyboard) executes from on-chip **BSRAM**, not SDRAM. This removes its instruction
> fetches from the SDRAM bus so they no longer contend with the Atari core's CPU/ANTIC DMA —
> which is what makes the OSD menu rock-solid while the machine runs. The firmware image is
> baked into the bitstream at FPGA-config time (no separate firmware flash step).
>
> **Keyboard runs in hardware:** the CH9350/UART keyboard is decoded by a dedicated RTL module
> (`uart_kbd_ch9350.sv`), independent of the softcore and the SDRAM bus.

> **Video / clock (v2.0):** The Atari core runs at **28.6875 MHz / `cycle_length=16` = exact NTSC
> machine speed**. Video is now a **genlocked line-buffer scandoubler** — there is **no SDRAM
> frame buffer**. The Atari frame is captured a few lines at a time and read out as a custom
> **1056×720** raster (integer 3× of the Atari's 352×240) whose pixel clock (57.375 MHz =
> 2× core, from a cascaded PLL) is **frequency-locked to the machine**: exactly one output frame
> per Atari frame → integer line count → **no ±1-line jitter and no tear**, at only ~1–2
> scanlines of latency. The panel sees it as an HD (720-line) signal. This freed the SDRAM bus
> for the Atari core + IO alone.

> **⚠️ Display compatibility:** staying jitter-free requires a **non-standard timing**
> (1056×720 active, declared as 720p) rather than exact CEA 720p — the Atari's frame rate
> simply doesn't divide evenly into any standard HDMI mode. **Most modern TVs and monitors
> accept it on a direct connection**, but some **strict or older displays** — and pass-through
> gear like **HDMI splitters, AV receivers and capture cards** — may reject it outright
> ("no signal" / "unsupported" / "out of range"). If your display won't show it, flash the
> standard-720p **[v1.1 release](https://github.com/carlosbravoa/atari800_tang_nano20k/releases/tag/v1.1)**
> instead (fully CEA-standard, at the cost of higher latency).

---

## Hardware Required

| Item | Notes |
|------|-------|
| Sipeed Tang Nano 20K | GW2AR-LV18 FPGA |
| MicroSD / TF card | FAT32, ≤ 32 GB |
| HDMI cable + monitor | Any HDMI 1.3+ monitor |
| Keyboard (recommended) | CH9350 USB-host board or a Raspberry Pi Pico → 1 wire to **Pin 53** (see [Keyboard](#keyboard-input)) |
| DB9 joystick | Standard Atari/Commodore DB9, **wired to GPIO pins** (no DB9 connector on the board — see [wiring](#atari-db9-joystick)). Enough on its own to drive the OSD. |
| Dupont jumper wires | To wire the joystick / keyboard to the GPIO header |

---

## SD Card Setup

Format a MicroSD card as **FAT32**. Place these files in the root directory:

```
/
├── ATARIXL.ROM   ← Atari XL/XE OS ROM, exactly 16384 bytes
├── BASIC.ROM     ← Atari BASIC ROM, exactly 8192 bytes
├── games/        ← your .atr disks and .car/.rom cartridges, any folders,
└── ...              long filenames fine
```

> File names are matched case-insensitively (`ATARIXL.ROM`/`atarixl.rom`, `BASIC.ROM`/`basic.rom`).
> You must supply your own ROM images — they are not included in this repository.

The PicoRV32 firmware (running from BSRAM) loads both ROMs into SDRAM on every boot, then
releases the Atari core from reset so it auto-boots to BASIC.

---

## Quick Start

Get to a BASIC prompt in a few minutes:

1. **SD card** — format FAT32, copy `ATARIXL.ROM` (16384 B) and `BASIC.ROM` (8192 B) to the root
   (supply your own — see [SD Card Setup](#sd-card-setup)). Add any `.atr` disk images you like.
2. **Flash** the bitstream (from the [latest release](https://github.com/carlosbravoa/atari800_tang_nano20k/releases/latest) zip, or your own build):
   ```bash
   openFPGALoader -b tangnano20k -f atari800_tn20k.fs
   ```
   The firmware is baked in — **no separate firmware flash**.
3. **Connect HDMI** to a monitor, and the SD card.
4. **Power on** — the Atari **auto-boots to BASIC** (no menu shown).
5. **Open the OSD** with the onboard **S2** button (or **F12** on a keyboard).
   - Navigate with a **DB9 joystick on port 1** (up/down + fire) *or* a keyboard — either works on its own.
   - For typing/games, attach a **UART/CH9350 keyboard** (one wire to Pin 53 — see [Keyboard](#keyboard-input)).

**To boot a disk:** open the OSD → **1) D1:** → **Attach disk...** → pick your `.atr` → **7) Hard Reset**.
**To run a cartridge:** open the OSD → **3) Cart:** → **Attach cartridge...** → pick — it boots immediately.

> **Input wiring note:** the board has no DB9 or USB connectors — the joystick and keyboard
> attach to **GPIO header pins** (see the wiring sections below). A DB9 joystick alone is enough
> to drive the whole OSD if you don't have a keyboard yet.

### Cartridge sizes & formats

| Format | Max size | Limited by |
|---|---|---|
| `.car` | **4 MB** | The 4 MB SDRAM cart window (8 MB chip; the rest holds Atari RAM and ROMs) |
| `.rom` (raw) | **16 KB** | Raw dumps carry no mapper info — only the simple unbanked sizes (2/4/8/16 KB) work |

A whole cartridge must be **resident in SDRAM** because bank switching is a real-time hardware
decision made by the 6502 — there's no opportunity to stream banks from the SD card on demand
(SD latency is ~1000× too slow for the bank-select→read window). This covers everything up to
**MegaCart 4 MB** (`.car` type 63). The!Cart 32/64/128 MB still can't fit the 8 MB SDRAM and are
rejected. For dumps larger than 16 KB, convert them to `.car` so the mapper type is encoded in
the header.

---

## Build

### Prerequisites

- [Gowin EDA IDE](https://www.gowinsemi.com/en/support/download_eda/) V1.9.x
- `riscv64-unknown-elf-gcc` (RISC-V toolchain for firmware)
- `openFPGALoader` (for flashing)

### Synthesise and generate bitstream

```bash
cd atari800_tang_nano20k_parallel
QT_QPA_PLATFORM=offscreen /path/to/gowin/IDE/bin/gw_sh.sh build.tcl 2>&1 | tee build.log
```

Output: `impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs`

### Build firmware

```bash
make -C firmware
```

This compiles the firmware and generates the BSRAM init hex (`src/fw_lane{0..3}.hex`,
`src/fw_words.hex`) via `firmware/bin2bram.py`. The hex files are consumed by `build.tcl` (via
`$readmemh`) and embedded into the bitstream — so **rebuild the firmware before the bitstream**
whenever firmware changes. (The generated hex are tracked in git, so a bitstream-only build works
without the RISC-V toolchain.)

### Flash

**Flash the bitstream only** — the firmware is inside it (loaded into BSRAM at config time):
```bash
openFPGALoader -b tangnano20k -f impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs
```

> There is **no separate firmware flash step** anymore. The firmware runs from on-chip BSRAM,
> not from SPI flash → SDRAM as in earlier versions.

---

## Keyboard-less OSD Navigation

By default, the OSD menu can be operated completely using your **DB9 Joystick 1** and the onboard **S2 button** on the Tang Nano 20K:
- **Toggle OSD Menu:** Press the onboard **S2** button (the rightmost button on the Tang Nano), or **F12** on the keyboard — either opens *and* closes the menu.
- **Move Cursor Up/Down:** Move **Joystick 1 Up/Down**.
- **Change Page:** In long file lists, **Left/Right** moves between pages; pressing **Down** past the last entry or **Up** past the first also flips to the next/previous page.
- **Confirm / Load File:** Press the **Joystick 1 Fire** button.
- **Go Back:** Select `..` or `<< Back` inside the file browser; submenus also have `<< Back`.

This allows booting games and mounting disks completely without any keyboard attached.

---

## Keyboard Input

For typing or keyboard-controlled games: a **CH9350 / Pi Pico UART board** — one wire, no
resistors, decoded in hardware. (A DB9 joystick alone already drives the whole OSD, so a
keyboard is optional for browsing/mounting disks.)

### CH9350 / Raspberry Pi Pico UART board
A cheap external micro-module acts as the USB host for your keyboard and streams standard
**CH9350 UART serial frames** (115200 baud, 8N1) of raw USB HID reports into the FPGA — decoded
by a dedicated hardware module. **One data wire to Pin 53**, no resistors. Setup details below.

### CH9350 / Pi Pico wiring & setup

#### Wiring
Both modules connect to the Tang Nano 20K GPIO header using only **one data wire**:
```
External Module                    Tang Nano 20K GPIO header
──────────────────                    ──────────────────────────
GND            ─────────────────────► GND  (any GND pin)
5V/VCC         ─────────────────────► 5V   (powers the module)
UART TX        ─────────────────────► Pin 53 (IOR38B - USB D+ header pin)
```

#### Option A: CH9350 Module Setup
The CH9350 is a plug-and-play USB Host to UART converter chip.
1. Set the DIP switches on your CH9350 board to **State 0 (Host Mode / Direct Data Transmit)** and **115200 Baud Rate**.
   - (Typically on CH9350L boards: set configuration switches `S1` and `S2` to select Host Mode at 115200 baud).
2. Plug your USB keyboard into the USB-A port on the CH9350 board.
3. Connect the CH9350's `TXD` pin directly to **Pin 53** on the Tang Nano 20K.

#### Option B: Raspberry Pi Pico (RP2040) Setup
The Pi Pico acts as a programmable drop-in replacement for the CH9350.
1. Connect a USB keyboard to the Pi Pico's micro-USB port using a micro-USB-to-USB-A OTG adapter.
2. Program the Pico with a sketch that:
   - Uses the `TinyUSB` library in host mode to capture keyboard events.
   - For every keypress/release, formats the 8-byte HID report into a CH9350 packet:
     - Header: `0x57 0xAB` (2 bytes)
     - Command: `0x88` (1 byte)
     - Length: `0x0B` (1 byte)
     - Keyboard ID: `0x10` (1 byte)
     - HID Report: `[modifiers, 0x00, key1, key2, key3, key4, key5, key6]` (8 bytes)
     - Serial number: `0x00` (1 byte)
     - Checksum: (1 byte, accumulation sum of bytes from the Keyboard ID through the serial number)
   - Transmits this frame over the Pico's UART TX pin at **115200 baud**.
3. Connect the Pico's UART TX pin directly to **Pin 53** on the Tang Nano 20K.

---



## Key Mapping (USB HID keyboard)

| USB key | Atari key / function |
|---------|----------------------|
| A–Z | A–Z |
| 0–9 | 0–9 |
| F1–F4 | F1–F4 |
| F5 / Insert | Help |
| F6 | Start (console key) |
| F7 | Select (console key) |
| F8 | Option (console key) |
| Escape | Escape |
| Backspace | Delete |
| Arrow keys | Atari cursor keys (move directly — CTRL is implied) |
| ISO #/~ key (next to ISO Enter) | `*` |
| `[ ]` | Cursor up / down |
| `\ '` | Cursor right / left |
| Grave / Num Lock | Break |
| Left/Right Shift | Shift |
| Left/Right Ctrl | Control |
| Right Alt | Inverse Video |
| Caps Lock | Caps Lock |
| **F9** | **Soft reset** (warm start, in-game) |
| **F12** | **OSD menu** open/close |

---

## Atari DB9 Joystick

Standard Atari/Commodore DB9 joystick. No resistors needed — internal FPGA pull-ups are used.

### Wiring

> **Pin change (2026-06):** the joysticks previously sat on pins 69–76/79, which are **not free
> GPIO** on the Tang Nano 20K — they carry the onboard BL616 MCU's UART/HSPI lines and the
> WS2812 LED data. The BL616 drove them, creating permanent phantom joystick input (games
> auto-skipped intros/cutscenes). The pins below carry LCD-only nets (unpopulated FPC
> connector) and are safe. Don't ever wire anything to pins 69–76/79.

```
DB9 male plug (pin face, looking at solder side of plug)
 ┌───────────────────────┐
 │  1   2   3   4   5   │    Joystick 1     Joystick 2
 │    6   7   8   9     │    (joy1_n)       (joy2_n)
 └───────────────────────┘
   │   │   │   │           FPGA pin       FPGA pin
   │   │   │   └── GND ─── GND header     GND header
   │   │   └────── Left ── pin 29         pin 42
   │   └────────── Down ── pin 28         pin 41
   └────────────── Up ──── pin 27         pin 32

DB9 pin 3  Left  → joy1_n[2] pin 29 / joy2_n[2] pin 42
DB9 pin 4  Right → joy1_n[3] pin 30 / joy2_n[3] pin 48
DB9 pin 6  Fire  → joy1_n[4] pin 31 / joy2_n[4] pin 77
DB9 pin 8  GND   → GND on GPIO header
```

All signals are **active low**. Connect the joystick's GND (pin 8) to any GPIO header GND.
Do **not** connect pin 7 (+5V) unless your joystick requires power.

---

## Audio

### HDMI Audio (recommended — zero extra hardware)

POKEY audio is embedded in HDMI data islands at **48 kHz stereo PCM**. Any HDMI
monitor or AV receiver with audio output plays it directly. No wiring needed.

### GPIO Audio (analogue — optional)

1-bit sigma-delta PDM on GPIO pins. Add a simple RC low-pass filter:

```
FPGA pin 25 (audio_l) ─── 1 kΩ ───┬─── 3.5 mm jack LEFT
                                   │
                                  10 nF
                                   │
                                  GND

FPGA pin 26 (audio_r) ─── 1 kΩ ───┬─── 3.5 mm jack RIGHT
                                   │
                                  10 nF
                                   │
                                  GND

3.5 mm jack SLEEVE ───────────────── GND
```

RC cutoff: 1 / (2π × 1 kΩ × 10 nF) ≈ **15.9 kHz** — adequate for POKEY audio.

---

## Status LEDs

The Tang Nano 20K has 4 usable active-low LEDs on pins 17–20. Physical labels vs RTL bus index
differ — reason in **pins** (the RTL port is `leds_n[4:1]` → pins 17,18,19,20 → physical
**LED2,LED3,LED4,LED5**).

| Pin | Physical LED | Meaning |
|-----|------|---------|
| 17 | LED2 | **SIO data activity** — blinks in rhythm with the disk-load sounds; if it goes dark mid-load while LED4 keeps flashing, the load is stuck |
| 18 | LED3 | **Atari booted** (ROMs loaded) — solid ON in normal operation |
| 19 | LED4 | **SIO command frames** — one flash per drive request |
| 20 | LED5 | Heartbeat (~0.8 Hz) — FPGA alive |

Normal good state: heartbeat blinking, LED3 solid, LED2/LED4 flickering during disk access.

If the Atari does not boot to BASIC, check:
- SD card is FAT32 formatted, fully inserted
- `ATARIXL.ROM` (16384 B) and `BASIC.ROM` (8192 B) are in the root directory

---

## OSD Menu

The Atari auto-boots first. Press **S2** (or **F12**) to open/close the menu:

```
=== Tang Atari 800 ===

1) D1: Montezuma.atr
2) D2: None
3) Cart: None
4) Boot to OS (No BASIC)
5) Boot to BASIC
6) Soft Reset
7) Hard Reset
8) Options
9) Return to Atari (F12)
```
- **D1: / D2: / Cart:** — each shows its current attachment inline and opens a small
  object menu when selected: **Attach...** (file browser, filtered to `.atr`/`.xex` for
  drives, `.car`/`.rom` for the cart) / **Detach** / **<< Back**. Attaching a cartridge
  **cold-boots straight into it**; detaching it cold-boots back to BASIC. Disks
  attach/detach live. Selecting a **`.xex`** on D1: mounts it as a virtual boot disk and
  **cold-boots straight into the program** (BASIC disabled)
- **Boot to OS / Boot to BASIC** — load ROMs and (re)boot the Atari
- **Soft / Hard Reset** — warm or cold restart (F9 is a soft-reset hotkey in-game)
- **Options** — OSD hot key, **Arrow keys: NORMAL/JOYSTICK** (see below), **Scanlines**
  (OFF / 25 / 50 / 75 %), and **H position** (Left/Right to slide the picture live). All persist in `atari.ini`
- **Return to Atari** — close the OSD (also via S2 / F12)

> While the menu is open, the Atari **keeps running live behind it** (you'll hear the game
> continue); keyboard and joystick inputs are masked from the machine so menu navigation
> doesn't play the game.

### Playing with the keyboard (arrow keys as joystick)

In **OSD → Options**, toggle **`Arrow keys: NORMAL → JOYSTICK`**. While set to JOYSTICK:

- ↑ ↓ ← → drive **Joystick 1** (alongside any physical DB9 stick on port 1), **Left-Alt = fire**.
- Those keys are suppressed from the Atari keyboard so they only move the stick (no stray typing).
- Toggle back to **NORMAL** to type again. The setting is saved to `atari.ini` and survives reboots.

### Booting a disk image

1. Copy your `.atr` disk images anywhere on the SD card (root or subfolders).
2. Power on (Atari boots to BASIC), then press **S2** / **F12** to open the OSD.
3. Choose **1) D1:** → **Attach disk...**, browse to your `.atr`, press **Fire**/**Enter** to mount it.
4. Choose **7) Hard Reset** (cold boot) — the Atari now boots from the mounted disk (e.g. into DOS).

The mounted images show on the `D1:`/`D2:` lines. Most DOS disks and bootable games work;
the emulated drives respond as **D1: and D2:** — use D2: for data disks or disk 2 of
multi-disk games, or swap D1: live when a game asks for the next disk.

---

## Pin Reference

### FPGA pins used

| Function | FPGA pin | IO name | Dir |
|----------|----------|---------|-----|
| System clock (27 MHz) | 4 | LPLL1_T_in | in |
| Reset button S1 | 88 | — | in |
| Spare button S2 | 87 | — | in |
| LED 1–4 | 17–20 | IOL49A–IOL51B | out |
| HDMI TMDS CLK +/− | 33, 34 | IOB24A/B | out |
| HDMI TMDS D0 +/− | 35, 36 | IOB30A/B | out |
| HDMI TMDS D1 +/− | 37, 38 | IOB34A/B | out |
| HDMI TMDS D2 +/− | 39, 40 | IOB40A/B | out |
| GPIO Audio L | 25 | IOB6A | out |
| GPIO Audio R | 26 | IOB6B | out |
| SD CLK | 83 | — | out |
| SD MOSI | 82 | — | out |
| SD MISO | 84 | — | in |
| SD CS | 81 | — | out |
| Keyboard UART RX (CH9350/Pico TX) | 53 | IOR38B | in |
| (reserved — legacy USB D−, unused) | 49 | IOR49A | — |
| Joy1 Up/Dn/Lt/Rt/Fire | 27,28,29,30,31 | IOB8A…IOB18A (LCD-only nets) | in |
| Joy2 Up/Dn/Lt/Rt/Fire | 32,41,42,48,77 | IOB18B…IOT30A (LCD-only nets) | in |

---

## Directory Structure

```
atari800_tang_nano20k_parallel/
├── build.tcl                  # Gowin build script (synthesis + P&R + bitstream)
├── constraints/
│   └── tang_nano_20k.cst      # Physical pin constraints
├── firmware/
│   ├── firmware.c             # PicoRV32 firmware (OSD, ROM loader, keyboard)
│   ├── bin2bram.py            # firmware.bin → BSRAM init hex (4 byte lanes)
│   ├── baremetal.ld           # linker: 48 KB BSRAM region + stack-headroom guard
│   └── Makefile
├── rtl/                       # Upstream Atari core VHDL
│   └── common/a8core/         # 6502, ANTIC, GTIA, POKEY, PIA, SIO
└── src/                       # Tang Nano-specific SystemVerilog / Verilog
    ├── tang_top.sv            # Top-level module (arbiter, clocks, input masking)
    ├── gw2ar_sdram.sv         # SDRAM handshake adapter (clk_core <-> clk_mem)
    ├── sdram_nestang.v        # Low-latency SDRAM controller (NESTang-derived)
    ├── scandoubler_480p.sv    # Genlocked line-buffer scandoubler (Atari video → 1056×720, 3×, scanlines)
    ├── rpll_287m.v            # Cascaded PLL: 114.75 → 286.875 MHz (HDMI 5×, pixel = 2× core)
    ├── iosys_picorv32.v       # PicoRV32 IO subsystem (OSD, SD); firmware in BSRAM
    ├── fw_bram.v              # 48 KB byte-laned BSRAM firmware boot RAM
    ├── fw_lane{0..3}.hex      # firmware BSRAM init (generated by bin2bram.py)
    ├── hdmi_audio_out.sv      # HDMI wrapper (hdl-util/hdmi library)
    ├── usb_to_atari800.sv     # HID codes → Atari keyboard matrix / console keys
    ├── uart_kbd_ch9350.sv     # Hardware CH9350/UART keyboard decoder
    ├── simplespimaster.v      # SPI master (SD card)
    ├── simpleuart.v           # UART (UART keyboard RX + debug TX)
    ├── picorv32.v             # PicoRV32 RISC-V softcore
    └── hdmi2/                 # hdl-util/hdmi library (720p TMDS)
```

---

## Known Limitations / Roadmap

- **SIO disk emulation** — ✅ working (D1: + D2:, read + write); hardware command-frame capture
- **`.xex` executables** — ✅ working (virtual-disk 6502 loader). A program that loads into
  page `$0600-$07FF` can clash with the running loader; relocating the loader to high RAM is a
  possible future fix
- **Atari speed** — ✅ exact NTSC speed (28.6875 MHz core), genlocked line-buffer video (no
  frame buffer) — jitter-free, tear-free, low-latency 1056×720
- **A few demanding `.xex` titles** show intermittent graphics glitches (see `KNOWN_ISSUES.md`)
- **Joystick paddles** — analogue pot inputs not implemented
- **Cartridge images** — ✅ `.car`/`.rom` working, banked + 4 MB MegaCart hardware-verified; 50 CAR
  types up to 4 MB (The!Cart 32/64/128 MB cannot fit the 8 MB SDRAM). Rejected types
  show their id on screen — report them if the core should support one
- **Machine is NTSC** (`PAL=0`); runtime PAL/NTSC switch planned

---

## Credits & Licences

- **Atari 800 core** — [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) by Mark Watson (GPL)
- **HDMI library** — [hdl-util/hdmi](https://github.com/hdl-util/hdmi) (MIT)
- **USB HID host** — [nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host) (Apache 2.0)
- **PicoRV32** — [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) (ISC)
- **IO subsystem** — adapted from [nand2mario/nestang](https://github.com/nand2mario/nestang)
- **Low-latency SDRAM controller** — adapted from **nand2mario**'s NESTang Tang Nano 20K controller
  ([sdram-tang-nano-20k](https://github.com/nand2mario/sdram-tang-nano-20k)). Our `sdram_nestang.v`
  is that controller with a 32-bit masked-write path and half-rate BL2 burst reads added.
  Huge thanks — this is what made the low-latency, corruption-free core possible.

This Tang Nano 20K port: see upstream projects for their respective licence terms.
