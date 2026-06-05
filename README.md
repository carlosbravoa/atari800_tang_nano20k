# Atari 800 — Tang Nano 20K Port

> Don't take this project too seriously (yet). It is a vibe-coding experiment with no shame. It took 2 weeks to get something reasonable working — and **SIO disk emulation now works**, so you can mount `.atr` images and boot DOS/games. Timings are still a bit fast, but it's a blast to play with.

FPGA emulation of the Atari 800/800XL/65XE/130XE on the
[Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
(GW2AR-LV18QN88PC8/I7).

Based on the [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) core by Mark Watson,
adapted for the Gowin FPGA toolchain.

---

## Features

- **Atari 800 / 800XL / 65XE / 130XE** emulation (6502 CPU, ANTIC, GTIA, POKEY, PIA)
- **HDMI video** — 720p/60 Hz, scaled from Atari native (hdl-util/hdmi library)
- **HDMI audio** — 48 kHz stereo PCM in HDMI 1.3 data islands (no extra hardware)
- **GPIO audio** — sigma-delta PDM on GPIO pins (add RC filter for analogue)
- **On-chip SDRAM** — GW2AR-18 embedded 64 Mbit, custom controller
- **SD card ROM loader** — reads `ATARIXL.ROM` (16 KB) and `BASIC.ROM` (8 KB) at boot
- **On-Screen Display (OSD)** — file browser, disk image selection, options menu (navigable via DB9 Joystick + S2 button!)
- **OSD Keyboard-less Navigation** — toggle OSD via onboard S2 button; navigate and select files using physical DB9 Joystick 1
- **UART / Serial Keyboard (Primary)** — supports raw USB HID reports sent over serial frames via an external CH9350 board or Raspberry Pi Pico (no resistors required, uses Pin 53)
- **USB HID Keyboard (Secondary)** — direct low-speed USB keyboard connection to the FPGA GPIO pins (requires 15 kΩ pull-down resistors, see below)
- **Atari DB9 joystick ports × 2** — active-low GPIO, no resistors needed
- **SIO disk emulation** — mount `.atr` disk images from the SD card

---

## Status

| Feature | Status |
|---|---|
| Atari boot (BASIC) — auto-boots on power-on | ✅ Working |
| HDMI video 720p/60 Hz | ✅ Working |
| HDMI audio (48 kHz PCM) | ✅ Working |
| GPIO sigma-delta audio | ✅ Working |
| SD card ROM loader | ✅ Working |
| OSD menu (S2 button + DB9 joystick + keyboard) | ✅ Working — rock-solid |
| UART / serial keyboard (CH9350 / Pi Pico) | ✅ Working (hardware decoder) |
| USB HID keyboard | ✅ Working |
| DB9 joystick | ✅ Working |
| SIO disk emulation (.atr) | ✅ Working — mount `.atr` images, boot DOS/games |
| Cartridge images (.car / .rom) | 🔜 Planned |

> **Architecture note — firmware runs from BSRAM:** The PicoRV32 IO subsystem (OSD, SD
> access, keyboard) executes from on-chip **BSRAM**, not SDRAM. This removes its instruction
> fetches from the SDRAM bus so they no longer contend with the Atari core's CPU/ANTIC DMA —
> which is what makes the OSD menu rock-solid while the machine runs. The firmware image is
> baked into the bitstream at FPGA-config time (no separate firmware flash step).
>
> **Keyboard runs in hardware:** the CH9350/UART keyboard is decoded by a dedicated RTL module
> (`uart_kbd_ch9350.sv`), independent of the softcore and the SDRAM bus.

> **Video / clock:** The Atari core and SDRAM run at **54 MHz / `cycle_length=32`** so each
> SDRAM access completes within the Atari bus window (the original 27 MHz / `cycle_length=16`
> exceeded it, causing video garble). The HDMI scaler genlocks to this 54 MHz line cadence.

> **Known caveats (this baseline):** ① The Atari currently runs slightly fast (timing tuning
> pending). ② `clk_core` is modestly above the tool's reported Fmax; it boots reliably in
> practice but the timing margin work is tracked. ③ The status LEDs presently carry diagnostic
> signals (see [Status LEDs](#status-leds)), not the normal status set.

---

## Hardware Required

| Item | Notes |
|------|-------|
| Sipeed Tang Nano 20K | GW2AR-LV18 FPGA |
| MicroSD / TF card | FAT32, ≤ 32 GB |
| HDMI cable + monitor | Any HDMI 1.3+ monitor |
| DB9 joystick | Standard Atari/Commodore DB9 (required for OSD navigation if no keyboard) |
| USB-A female + 2 × 15 kΩ (optional) | For USB HID keyboard |

---

## SD Card Setup

Format a MicroSD card as **FAT32**. Place these files in the root directory:

```
/
├── ATARIXL.ROM   ← Atari XL/XE OS ROM, exactly 16384 bytes
└── BASIC.ROM     ← Atari BASIC ROM, exactly 8192 bytes
```

> File names are matched case-insensitively (`ATARIXL.ROM`/`atarixl.rom`, `BASIC.ROM`/`basic.rom`).
> You must supply your own ROM images — they are not included in this repository.

The PicoRV32 firmware (running from BSRAM) loads both ROMs into SDRAM on every boot, then
releases the Atari core from reset so it auto-boots to BASIC.

---

## Quick Start

1. Insert SD card with `ATARIXL.ROM` and `BASIC.ROM` (FAT32)
2. Flash the FPGA bitstream (see [Build](#build) or use a pre-built `.fs`) — the firmware is
   baked into the bitstream, so there is **no separate firmware flash step**
3. Connect HDMI
4. Connect a DB9 Joystick to port 1 and/or a keyboard (see below)
5. Power on — the Atari **auto-boots to BASIC**. Press the onboard **S2** button (or **F12**) to
   open the OSD menu; navigate with Joystick 1 or the keyboard.

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
- **Go Back:** Select `..` or `<< Return to main menu` inside the file browser.

This allows booting games and mounting disks completely without any keyboard attached.

---

## Keyboard Input Alternatives

To get a full keyboard mapping for typing or playing keyboard-controlled games, you have three options:

### 1. USB Keyboard with 15 kΩ pull-down resistors (Recommended)
This uses the FPGA's built-in USB Host controller. Connect a USB-A female connector to the Tang Nano GPIO pins and add 15 kΩ pull-down resistors to GND on both the D− and D+ lines (see [USB HID Keyboard](#usb-hid-keyboard-requires-resistors)).

### 2. PS/2 Keyboard using internal FPGA pull-ups (Zero Resistors)
A PS/2 keyboard can be wired to GPIO pins 49 (CLK) and 53 (DAT) or similar. By configuring the FPGA's internal pull-up resistors (`PULL_MODE=UP` in `tang_nano_20k.cst`), no external components or resistors are needed. 

### 3. External USB Host Module (CH9350 / Raspberry Pi Pico)
Instead of running a USB Host stack on the FPGA, you can use a cheap external micro-module that acts as a USB Host for your keyboard and outputs standard **CH9350 UART serial frames** (115200 baud, 8N1) containing raw USB HID reports.

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



## USB HID Keyboard (Requires resistors)

Connect a USB-A female connector and add **15 kΩ pull-down resistors** from D− and D+ to GND.

### Wiring

```
USB-A female socket (looking into socket)
 ┌──────────────────────────┐
 │   1    2    3    4       │
 │  [5V] [D-] [D+] [GND]   │
 └──────────────────────────┘
    │     │    │    │
    │     │    │    └─────── GND (GPIO header)
    │     │    │
    │     │    ├──── 15 kΩ ── GND
    │     │    └──────────── FPGA pin 53  (D+, IOR38B)
    │     │
    │     ├──── 15 kΩ ── GND
    │     └──────────── FPGA pin 49  (D−, IOR49A)
    │
    └───────────────── VBUS 5 V (powers the keyboard)
```

> The 15 kΩ pull-downs are **mandatory**. Without them the USB host cannot detect device
> connection. A low-speed device has a 1.5 kΩ pull-up on D−; the host detects it when
> this pull-up overcomes the 15 kΩ pull-down.

### Key mapping (USB HID)

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
| Arrow keys | Atari cursor keys |
| `[ ]` | Cursor up / down |
| `\ '` | Cursor right / left |
| Grave / Num Lock | Break |
| Left/Right Shift | Shift |
| Left/Right Ctrl | Control |
| Right Alt | Inverse Video |
| Caps Lock | Caps Lock |

---

## Atari DB9 Joystick

Standard Atari/Commodore DB9 joystick. No resistors needed — internal FPGA pull-ups are used.

### Wiring

```
DB9 male plug (pin face, looking at solder side of plug)
 ┌───────────────────────┐
 │  1   2   3   4   5   │    Joystick 1     Joystick 2
 │    6   7   8   9     │    (joy1_n)       (joy2_n)
 └───────────────────────┘
   │   │   │   │           FPGA pin       FPGA pin
   │   │   │   └── GND ─── GND header     GND header
   │   │   └────── Left ── pin 71         pin 76
   │   └────────── Down ── pin 70         pin 75
   └────────────── Up ──── pin 69         pin 74

DB9 pin 3  Left  → joy1_n[2] pin 71 / joy2_n[2] pin 76
DB9 pin 4  Right → joy1_n[3] pin 72 / joy2_n[3] pin 77
DB9 pin 6  Fire  → joy1_n[4] pin 73 / joy2_n[4] pin 79
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

> **This baseline carries DIAGNOSTIC signals on the LEDs**, not the normal status set, while the
> SIO disk revival is in progress (`tang_top.sv`):
>
> | Pin | Physical LED | Signal | Meaning |
> |-----|------|--------|---------|
> | 17 | LED2 | `sio_command` | ON (active low) while the Atari asserts the SIO command line |
> | 18 | LED3 | `sio_rx_data_in` | flashes when the emulated drive transmits to the Atari |
> | 19 | LED4 | `sio_txd` | flashes when the Atari transmits to the drive |
> | 20 | LED5 | heartbeat (~6 Hz blink) | FPGA running |
>
> Normal good state: the ~6 Hz heartbeat (pin 20) blinks; the SIO LEDs flicker during disk
> access. If the machine fails to boot with only the heartbeat blinking, the Atari core isn't
> running (a timing/placement issue), not a firmware hang.

If the Atari does not boot to BASIC, check:
- SD card is FAT32 formatted, fully inserted
- `ATARIXL.ROM` (16384 B) and `BASIC.ROM` (8192 B) are in the root directory

---

## OSD Menu

The Atari auto-boots first. Press **S2** (or **F12**) to open/close the menu:

```
=== Tang Atari 800 ===

Mounted: None

1) Select ATR Disk Image
2) Boot to OS (No BASIC)
3) Boot to BASIC
4) Soft Reset
5) Hard Reset
6) Options
7) Return to Atari (F12)
```

- **Select ATR Disk Image** — browse SD card for `.atr` files, select to mount
- **Boot to OS / Boot to BASIC** — load ROMs and (re)boot the Atari
- **Soft / Hard Reset** — warm or cold restart
- **Options** — emulator options (OSD hotkey, keyboard type)
- **Return to Atari** — close the OSD (also via S2 / F12), with or without a disk mounted

### Booting a disk image

1. Copy your `.atr` disk images anywhere on the SD card (root or subfolders).
2. Power on (Atari boots to BASIC), then press **S2** / **F12** to open the OSD.
3. Choose **1) Select ATR Disk Image**, browse to your `.atr`, press **Fire**/**Enter** to mount it.
4. Choose **5) Hard Reset** (cold boot) — the Atari now boots from the mounted disk (e.g. into DOS).

The mounted image shows on the `Mounted:` line. Most DOS disks and bootable games work; the
emulated drive responds as **D1:**.

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
| USB D+ (HID keyboard) | 53 | IOR38B | inout |
| USB D− (HID keyboard) | 49 | IOR49A | inout |
| Joy1 Up/Dn/Lt/Rt/Fire | 69–73 | IOT50A…IOT40A | in |
| Joy2 Up/Dn/Lt/Rt/Fire | 74–79 | IOT34B…IOT27B | in |

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
│   ├── baremetal.ld           # linker: single 64 KB BSRAM region from 0
│   └── Makefile
├── rtl/                       # Upstream Atari core VHDL
│   └── common/a8core/         # 6502, ANTIC, GTIA, POKEY, PIA, SIO
└── src/                       # Tang Nano-specific SystemVerilog / Verilog
    ├── tang_top.sv            # Top-level module
    ├── gw2ar_sdram.sv         # Custom GW2AR-18 embedded SDRAM controller
    ├── iosys_picorv32.v       # PicoRV32 IO subsystem (OSD, SD); firmware in BSRAM
    ├── fw_bram.v              # 64 KB byte-laned BSRAM firmware boot RAM
    ├── fw_lane{0..3}.hex      # firmware BSRAM init (generated by bin2bram.py)
    ├── hdmi_audio_out.sv      # HDMI wrapper (hdl-util/hdmi library)
    ├── scale720p.sv           # Atari → 720p scaler (genlocked to 54 MHz)
    ├── usb_to_atari800.sv     # USB HID → Atari keyboard matrix
    ├── uart_kbd_ch9350.sv     # Hardware CH9350/UART keyboard decoder
    ├── simplespimaster.v      # SPI master (SD card)
    ├── simpleuart.v           # UART (UART keyboard RX + debug TX)
    ├── picorv32.v             # PicoRV32 RISC-V softcore
    └── hdmi2/                 # hdl-util/hdmi library (720p TMDS)
```

---

## Known Limitations / Roadmap

- **SIO disk emulation** — ✅ working; cartridge (`.car`/`.rom`) loading still planned
- **Atari speed** — currently runs slightly fast; timing tuning pending
- **clk_core timing margin** — `clk_core` (54 MHz) is modestly above the tool's reported Fmax;
  boots reliably in practice, proper critical-path fix tracked
- **Joystick paddles** — analogue pot inputs not implemented
- **Cartridge images** — `.car` / `.rom` cartridge loading not yet implemented
- **Machine is NTSC** (`PAL=0`); runtime PAL/NTSC switch planned

---

## Credits & Licences

- **Atari 800 core** — [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) by Mark Watson (GPL)
- **HDMI library** — [hdl-util/hdmi](https://github.com/hdl-util/hdmi) (MIT)
- **USB HID host** — [nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host) (Apache 2.0)
- **PicoRV32** — [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) (ISC)
- **IO subsystem** — adapted from [nand2mario/nestang](https://github.com/nand2mario/nestang)

This Tang Nano 20K port: see upstream projects for their respective licence terms.
