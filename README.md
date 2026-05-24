# Atari 800 — Tang Nano 20K Port

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
- **SD card ROM loader** — reads `OS.ROM` (16 KB) and `BASIC.ROM` (8 KB) at boot
- **On-Screen Display (OSD)** — file browser, disk image selection, options menu (navigable via DB9 Joystick + S2 button!)
- **OSD Keyboard-less Navigation** — toggle OSD via onboard S2 button; navigate and select files using physical DB9 Joystick 1
- **USB HID keyboard** — low-speed USB (requires 15 kΩ pull-down resistors, see below)
- **Atari DB9 joystick ports × 2** — active-low GPIO, no resistors needed
- **SIO disk emulation** — mount `.atr` disk images from the SD card

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
├── OS.ROM      ← Atari XL/XE OS ROM, exactly 16384 bytes
└── BASIC.ROM   ← Atari BASIC ROM, exactly 8192 bytes
```

> You must supply your own ROM images — they are not included in this repository.

The PicoRV32 firmware loads both ROMs into SDRAM on every boot before releasing the Atari core from reset.

---

## Quick Start

1. Flash the FPGA bitstream (see [Build](#build) or use a pre-built `.fs`)
2. Flash the firmware (see below)
3. Insert SD card with `OS.ROM` and `BASIC.ROM`
4. Connect HDMI
5. Connect a DB9 Joystick to port 1
6. Power on — the OSD menu appears within ~2 seconds (press the S2 button on the Tang Nano 20K to open/close, and use Joystick 1 to navigate and select files)

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

Output: `firmware/firmware.bin`

### Flash

**Flash the bitstream:**
```bash
openFPGALoader -b tangnano20k -f impl/atari800_tn20k/impl/pnr/atari800_tn20k.fs
```

**Flash the firmware** (stored in SPI flash at offset 5 MB):
```bash
openFPGALoader -b tangnano20k -f -o 0x500000 firmware/firmware.bin
```

Both must be flashed for the system to work. The bitstream loads first; the PicoRV32 inside then reads the firmware from the SPI flash.

---

## Keyboard-less OSD Navigation

By default, the OSD menu can be operated completely using your **DB9 Joystick 1** and the onboard **S2 button** on the Tang Nano 20K:
- **Toggle OSD Menu:** Press the onboard **S2** button (the rightmost button on the Tang Nano).
- **Move Cursor Up/Down:** Move **Joystick 1 Up/Down**.
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

The Tang Nano 20K has 4 active-low LEDs on pins 17–20:

| LED | FPGA pin | Signal | Meaning |
|-----|----------|--------|---------|
| LED 1 | 17 | `sdram_ready` | SDRAM initialised |
| LED 2 | 18 | `pll_locked` | Main PLL locked |
| LED 3 | 19 | `roms_loaded` | ROMs loaded from SD card |
| LED 4 | 20 | heartbeat (~6 Hz blink) | FPGA running |

**Normal boot sequence:**
1. LED 4 blinks immediately (FPGA running, 27 MHz clock OK)
2. LED 1 turns ON (~200 µs — SDRAM initialised)
3. LED 2 turns ON (~1 ms — PLL locked)
4. LED 3 turns ON (~2 s — ROMs loaded from SD card)
5. Atari core releases from reset → OSD menu appears

If LED 3 never turns on, check:
- SD card is FAT32 formatted
- `OS.ROM` and `BASIC.ROM` are in the root directory (correct filenames, correct sizes)
- SD card is fully inserted

---

## OSD Menu

Press the joystick fire button (or navigate with Up/Down on joystick) to open the menu:

```
=== Atari800Tang ===

Mounted: None

1) Select ATR Disk Image
2) Boot / Reset Atari
3) Return to game
4) Options
```

- **Select ATR Disk Image** — browse SD card for `.atr` files, select to mount
- **Boot / Reset Atari** — reset the Atari 800 core
- **Return to game** — close the OSD
- **Options** — emulator options (PAL/NTSC, joystick swap, etc.)

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
│   ├── firmware.bin           # Compiled firmware binary
│   └── Makefile
├── rtl/                       # Upstream Atari core VHDL
│   └── common/a8core/         # 6502, ANTIC, GTIA, POKEY, PIA, SIO
└── src/                       # Tang Nano-specific SystemVerilog / Verilog
    ├── tang_top.sv            # Top-level module
    ├── gw2ar_sdram.sv         # Custom GW2AR-18 embedded SDRAM controller
    ├── iosys_picorv32.v       # PicoRV32 IO subsystem (OSD, SD, SPI flash)
    ├── hdmi_audio_out.sv      # HDMI wrapper (hdl-util/hdmi library)
    ├── scale720p.sv           # Atari → 720p scaler
    ├── usb_to_atari800.sv     # USB HID → Atari keyboard matrix
    ├── sd_rom_loader.sv       # FAT32 ROM loader
    ├── simplespimaster.v      # SPI master (SD card)
    ├── simpleuart.v           # UART (UART keyboard RX + debug TX)
    ├── picorv32.v             # PicoRV32 RISC-V softcore
    └── hdmi2/                 # hdl-util/hdmi library (720p TMDS)
```

---

## Known Limitations / Roadmap

- **Joystick paddles** — analogue pot inputs not implemented
- **Cartridge images** — `.car` / `.rom` cartridge loading not yet implemented
- **PAL/NTSC switch** — currently PAL; runtime switch planned

---

## Credits & Licences

- **Atari 800 core** — [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) by Mark Watson (GPL)
- **HDMI library** — [hdl-util/hdmi](https://github.com/hdl-util/hdmi) (MIT)
- **USB HID host** — [nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host) (Apache 2.0)
- **PicoRV32** — [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) (ISC)
- **IO subsystem** — adapted from [nand2mario/nestang](https://github.com/nand2mario/nestang)

This Tang Nano 20K port: see upstream projects for their respective licence terms.
