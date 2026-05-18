# Atari 800 — Tang Nano 20K Port

FPGA emulation of the Atari 800/800XL/65XE/130XE on the [Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html) board (GW2AR-LV18QN88PC8/I7).

Based on the [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) core by Mark Watson, adapted for the Gowin FPGA toolchain.

## Features

- Atari 800 / 800XL / 65XE / 130XE emulation (6502, ANTIC, GTIA, POKEY, PIA)
- HDMI video output (27 MHz pixel clock, TMDS differential)
- On-chip SDRAM (GW2AR-18 embedded 64 Mbit)
- SD card ROM loader: reads `OS.ROM` (16 KB) and `BASIC.ROM` (8 KB) at boot
- USB HID keyboard via [nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host) (low-speed USB)
- Atari DB9 joystick ports × 2 (active-low GPIO)
- 6 status LEDs

## Hardware Required

- Sipeed Tang Nano 20K
- MicroSD / TF card with ROM files
- USB-A female connector + two 15 kΩ resistors (USB keyboard)
- Optional: DB9 connectors for Atari joysticks

## Directory Structure

```
atari800_tang_nano20k/
├── build.tcl              # Gowin build script (synthesis + P&R + bitstream)
├── constraints/
│   └── tang_nano_20k.cst  # Physical pin constraints (QFN88P numeric indices)
├── rtl/                   # Upstream Atari core VHDL (common/a8core, sioemu, etc.)
└── src/                   # Tang Nano-specific SystemVerilog / Verilog
    ├── tang_top.sv        # Top-level module
    ├── rpll_135m.v        # PLL: 27 MHz → 135 MHz (HDMI serialiser)
    ├── rpll_12m.v         # PLL: 27 MHz → 12 MHz (USB HID host)
    ├── hdmi_out.sv        # TMDS encoder + ELVDS output buffers
    ├── tmds_encoder.sv    # TMDS 8b10b encoder
    ├── sd_rom_loader.sv   # SD card FAT32 reader → SDRAM ROM loader
    ├── sd_card.sv         # SD SPI driver
    ├── fat_reader.sv      # FAT32 file reader
    ├── spi_master.sv      # Generic SPI master
    ├── usb_hid_host.v     # USB low-speed HID host (nand2mario)
    ├── usb_hid_host_rom.v # USB host microcode ROM
    ├── usb_hid_host_rom.hex
    ├── usb_to_atari800.sv # HID keycode → Atari matrix translator
    ├── sdram_statemachine.vhdl  # SDRAM access state machine
    └── ...
```

## Build

### Prerequisites

- [Gowin EDA IDE](https://www.gowinsemi.com/en/support/download_eda/) — tested with V1.9.x
- Shell wrapper `gw_sh.sh` (in `<gowin_install>/IDE/bin/`)

### Synthesise and generate bitstream

```bash
cd /path/to/atari800_tang_nano20k
/path/to/gowin/IDE/bin/gw_sh.sh build.tcl 2>&1 | tee build.log
```

Output bitstream: `impl/atari800_tn20k/atari800_tn20k.fs`

### Flash to board

```bash
/path/to/gowin/Programmer/bin/programmer_cli \
    --device GW2AR-LV18QN88PC8/I7 \
    --operation_index 1 \
    --fsFile impl/atari800_tn20k/atari800_tn20k.fs
```

Or use the Gowin Programmer GUI: open the `.fs` file and click Program/Configure.

## SD Card Setup

Format a MicroSD card as FAT32. Place these files in the root:

```
/
├── OS.ROM      — Atari XL/XE OS ROM (16384 bytes)
└── BASIC.ROM   — Atari BASIC ROM (8192 bytes)
```

The ROM loader reads both files at startup before releasing the Atari core from reset.
The `roms_loaded` LED (LED 3) turns on when loading is complete.

> You must supply your own ROM images. They are not included in this repository.

## GPIO Header Pin Assignments

The Tang Nano 20K exposes two 20-pin headers (left and right sides).
All non-HDMI peripheral connections use these headers.

```
Tang Nano 20K — GPIO header pinout (top view, USB side up)
===========================================================

LEFT HEADER (J2)                    RIGHT HEADER (J3)
  ┌────────────────────┐               ┌────────────────────┐
  │ 1  GND  │ 2  3.3V  │               │ 1  GND  │ 2  3.3V  │
  │ 3  5V   │ 4  IOx   │               │ 3  5V   │ 4  IOx   │
  │ ...     │ ...      │               │ ...     │ ...      │
  └────────────────────┘               └────────────────────┘

Note: Use the Sipeed Tang Nano 20K schematic to cross-reference
FPGA pin numbers to physical header positions.
```

### Functional pin table

| Function         | FPGA pin | IO name   | Direction | Note                          |
|-----------------|----------|-----------|-----------|-------------------------------|
| USB D−          | 49       | IOR49A    | inout     | 15 kΩ pull-down to GND       |
| USB D+          | 51       | IOR45A    | inout     | 15 kΩ pull-down to GND       |
| Joy1 Up         | 69       | IOT50A    | input     | active low, 33 kΩ pull-up    |
| Joy1 Down       | 70       | IOT44B    | input     | active low, 33 kΩ pull-up    |
| Joy1 Left       | 71       | IOT44A    | input     | active low, 33 kΩ pull-up    |
| Joy1 Right      | 72       | IOT40B    | input     | active low, 33 kΩ pull-up    |
| Joy1 Fire       | 73       | IOT40A    | input     | active low, 33 kΩ pull-up    |
| Joy2 Up         | 74       | IOT34B    | input     | active low, 33 kΩ pull-up    |
| Joy2 Down       | 75       | IOT34A    | input     | active low, 33 kΩ pull-up    |
| Joy2 Left       | 76       | IOT30B    | input     | active low, 33 kΩ pull-up    |
| Joy2 Right      | 77       | IOT30A    | input     | active low, 33 kΩ pull-up    |
| Joy2 Fire       | 79       | IOT27B    | input     | active low, 33 kΩ pull-up    |
| Button (reset)  | 63       | IOB29A    | input     | onboard S1, active low        |
| Button (spare)  | 48       | IOR49B    | input     | onboard S2, active low        |

Onboard (no wiring needed):

| Function   | FPGA pin(s)      | Note                                  |
|-----------|-----------------|---------------------------------------|
| HDMI CLK  | 25 (P), 26 (N)  | TMDS differential, onboard connector  |
| HDMI D[2] | 31 (P), 32 (N)  |                                       |
| HDMI D[1] | 29 (P), 30 (N)  |                                       |
| HDMI D[0] | 27 (P), 28 (N)  |                                       |
| SD CLK    | 36              | onboard TF card slot                  |
| SD MOSI   | 37              | onboard TF card slot                  |
| SD MISO   | 39              | onboard TF card slot                  |
| SD CS     | 42              | onboard TF card slot — do not move    |
| LEDs      | 16–20, 11       | active low, see LED table below       |

## USB Keyboard Wiring

Connect a USB-A female connector to the GPIO header.
Add 15 kΩ resistors from D− and D+ to GND (required for USB low-speed enumeration).

```
USB-A female connector (looking into socket)
┌──────────────────────┐
│  1   2   3   4       │
│ [+5V][D-][D+][GND]   │
└──────────────────────┘
  │     │    │    │
  │     │    │    └─── GND
  │     │    │
  │     │    ├──────── 15 kΩ ──── GND
  │     │    └──────── FPGA pin 51  (D+, USB_DP)
  │     │
  │     ├────────────── 15 kΩ ──── GND
  │     └────────────── FPGA pin 49  (D−, USB_DM)
  │
  └──────────────────── VBUS 5V (power the keyboard)
```

> The 15 kΩ pull-downs are mandatory. Without them the USB host will not detect
> device connection. Standard USB devices have internal 1.5 kΩ pull-up on D+ (full-speed)
> or D− (low-speed); the host detects a device when this pull-up overcomes the pull-down.

### Key mapping

| USB key       | Atari key / function   |
|--------------|------------------------|
| A–Z          | A–Z                    |
| 0–9          | 0–9                    |
| F1–F4        | F1–F4                  |
| F5 / Insert  | Help                   |
| F6           | Start (console)        |
| F7           | Select (console)       |
| F8           | Option (console)       |
| Escape       | Escape (Break)         |
| Backspace    | Delete                 |
| Arrow keys   | Atari cursor keys      |
| [ ]          | Atari cursor up/down   |
| \\ '         | Atari cursor right/left|
| Grave / Num Lock | Break              |
| Left/Right Shift | Shift              |
| Left/Right Ctrl  | Control            |
| Right Alt    | Inverse Video (bit 39) |
| Caps Lock    | Caps Lock              |

## Atari Joystick Wiring

Standard Atari DB9 joystick, wired to GPIO header. The FPGA uses internal pull-ups;
pressing a direction or fire connects that pin to GND through the joystick.

```
DB9 male plug (pins face down)        Tang Nano 20K GPIO
 ┌─────────────────────┐
 │  1   2   3   4   5  │              Joystick 1    Joystick 2
 │   6   7   8   9     │
 └─────────────────────┘
   │   │   │   │   │
   │   │   │   │   └── pin 9 (unused — pot/paddle)
   │   │   │   └────── pin 8  GND
   │   │   └────────── pin 7  +5V (not connected for passive sticks)
   │   └────────────── pin 6  Fire     → joy1_n[4] (pin 73) / joy2_n[4] (pin 79)
   └────────────────── pin 5  (unused)

   DB9 pin 1  Up     → joy1_n[0] (pin 69) / joy2_n[0] (pin 74)
   DB9 pin 2  Down   → joy1_n[1] (pin 70) / joy2_n[1] (pin 75)
   DB9 pin 3  Left   → joy1_n[2] (pin 71) / joy2_n[2] (pin 76)
   DB9 pin 4  Right  → joy1_n[3] (pin 72) / joy2_n[3] (pin 77)
   DB9 pin 6  Fire   → joy1_n[4] (pin 73) / joy2_n[4] (pin 79)
   DB9 pin 8  GND    → GND on GPIO header
```

All joystick signals are active low with internal FPGA pull-ups. No external resistors needed.

## Status LEDs

The six onboard LEDs (active low, left side of board):

| LED index | FPGA pin | Signal        | On when…                        |
|-----------|----------|---------------|---------------------------------|
| LED 0     | 16       | sdram_ready   | SDRAM controller initialised    |
| LED 1     | 17       | video_hs      | HDMI horizontal sync active     |
| LED 2     | 18       | video_vs      | HDMI vertical sync active       |
| LED 3     | 19       | roms_loaded   | SD card ROM load complete       |
| LED 4     | 20       | pll_locked    | Main 135 MHz PLL locked         |
| LED 5     | 11       | always on     | Power / bitstream present       |

Normal boot sequence: LED 5 lights immediately (bitstream loaded), LED 4 after ~1 ms (PLL locks),
LED 0 after ~100 µs (SDRAM init), LED 3 after OS.ROM + BASIC.ROM are read from SD card.
The Atari core starts running once LED 3 is on.

## Known Limitations / Roadmap

- **Audio**: POKEY audio output not yet connected (Stage 5 — PWM/sigma-delta DAC)
- **SIO disk**: No disk drive emulation yet (Stage 6)
- **OSD menu**: No on-screen display (Stage 7)
- **Joystick paddles**: Analog pot inputs not implemented
- **Cartridges**: No cartridge loading from SD card yet

## License

This port is derived from the Atari800_MiSTer project. See upstream for licence terms.
The USB HID host core is © nand2mario, Apache 2.0 licence.
