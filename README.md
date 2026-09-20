# Atari 800 — Tang Nano 20K Port

> This project started as a vibe-coding experiment with no shame. But now we have a full Atari800XL/130XE running with full NTSC Atari speed, low-latency jitter-free HDMI (a genlocked line-buffer, with optional CRT scanlines), keyboard, joysticks, ATR disks (four drives, MyDOS-ready, with an always-mounted hard-drive image), cartridges and `.xex` executables — plus a PC Link over the USB-C cable (send files, boot builds, type remotely, share an H: folder between the Atari and the PC, even print from AtariWriter to a PDF) — all on this really small device. It's a blast to play with. Enjoy it (because I am)!

<img width="400" height="400" alt="Eureka! Atari running Montezuma from an ATR Disk" src="https://github.com/user-attachments/assets/20121280-905e-4c15-8795-352eec9abf01" />

_Eureka! Atari running Montezuma from an ATR Disk_

FPGA emulation of the Atari 800/800XL/65XE/130XE on the
[Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
(GW2AR-LV18QN88PC8/I7). Based on the [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer)
core by Mark Watson, adapted for the Gowin FPGA toolchain.

> 📖 **User manual: [carlosbravoa.github.io/atari800_tang_nano20k](https://carlosbravoa.github.io/atari800_tang_nano20k/)**
> — hardware setup and wiring, the OSD, disks, cartridges, `.xex`, keyboard, video, audio, RAM,
> PC Link, troubleshooting. This README covers what only the repository can: getting a
> release onto the board, building from source, pins, and licences.

---

## ⚡ Minimum to get running

1. A **Sipeed Tang Nano 20K**.
2. A **FAT32 micro-SD** with `ATARIXL.ROM` (16384 B) and `BASIC.ROM` (8192 B) in the root
   (**you supply these ROMs**). Drop your `.atr` disks and `.car`/`.rom` cartridges on it too.
3. **Flash the bitstream** (the firmware is baked in — nothing else to flash). Grab the zip from
   the [latest release](https://github.com/carlosbravoa/atari800_tang_nano20k/releases/latest)
   (or build it yourself, see [Build](#build)):
   ```bash
   openFPGALoader -b tangnano20k -f atari800_tn20k.fs
   ```
4. Plug in **HDMI** and the **SD card**, then **power on** → it auto-boots to **BASIC**.
5. Press **S2** (onboard button) to open the OSD. A **DB9 joystick on port 1** alone can drive it.
   To boot a disk: OSD → *D1:* → *Attach* → pick → *Hard Reset*. To run a cartridge:
   OSD → *Cart:* → *Attach cartridge* → pick (boots immediately).

For a keyboard, the simplest is a **CH9350 USB-host board**: 5V, GND and its TX to **pin 53**
([manual: Hardware setup](https://carlosbravoa.github.io/atari800_tang_nano20k/02-hardware.html)).

---

## Features

- **Atari 800 / 800XL / 65XE / 130XE** (6502, ANTIC, GTIA, POKEY, PIA) at **exact NTSC speed** —
  passes **ACID800 57/57** on hardware
- **RAM 128 KB (130XE) / 320 / 576 / 1088 KB** (RAMBO), OSD selector, persisted
- **HDMI video, genlocked, no frame buffer** — 1056×720 (integer 3×) frequency-locked to the
  core: no jitter, no tear, ~1–2 scanlines of latency. **CRT scanlines** and **H position** live
  in the OSD. NTSC only
- **HDMI audio** 48 kHz stereo; **dual-POKEY stereo** (POKEY2 at `$D210`), OSD toggle, default mono
- **OSD** (v3.0 look: dimmed panel, title/footer bars, selection bar) — driven by keyboard and/or
  a DB9 joystick; the Atari keeps running behind it
- **Keyboard** via a CH9350 or Raspberry Pi Pico USB-host adapter (3 wires), decoded in hardware,
  Atari-positional mapping or an optional **US-PC symbolic layout** (OSD option, v3.1); **F9** soft reset, **F11** arrows↔joystick, **F12** OSD
- **Two DB9 joysticks** on header pins (passive, no +5V); **arrow keys as joystick** option
- **Disks:** `.atr` / `.xfd`, SD/ED/DD (both DD layouts), **D1:–D4:**, live mount/swap, reliable
  writes, DOS FORMAT, new blank disk from the OSD, read-only handling, `/HDD.ATR` auto-mounted on
  D4: as a permanent hard drive
- **Cartridges:** `.car` (52 mapper types, up to 4 MB — MegaCart 4 MB verified) and raw `.rom`
  2/4/8/16 KB. **Hard Reset power-cycles the cartridge** (multicart menus come back); F9 is the
  real RESET key and behaves like one
- **`.xex` executables** booted from the SD card (or pushed from the PC)
- **PC Link over the same USB-C cable:** send files, push-and-boot `.xex`, paste text as
  keystrokes, live remote keyboard, reset/eject, logs, `status`/`screen`/`peek`/`poke`
  telemetry, **P: printer → PC** (text / paper / 5×7 dot-matrix PDF), **H: shared folder**,
  desktop app for Linux/Windows. Prototypes in the tree: **N:** network device, **R:** 850 modem
  (opt-in) for BobTerm
- Long filenames, folders, 24-entry pages in the file browser

Every item above is documented for users in the
[manual](https://carlosbravoa.github.io/atari800_tang_nano20k/). Open problems and limitations:
[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) and
[manual §15](https://carlosbravoa.github.io/atari800_tang_nano20k/15-known-issues.html).

> ⚠️ **Display compatibility:** jitter-free video needs a **non-standard timing** (1056×720
> declared as 720p). Most TVs and monitors accept it directly; some strict/older displays and
> pass-through gear (splitters, AV receivers, capture cards) may reject it. If yours does, flash the
> CEA-standard **[v1.1 release](https://github.com/carlosbravoa/atari800_tang_nano20k/releases/tag/v1.1)**
> (higher latency). Details: [manual §10](https://carlosbravoa.github.io/atari800_tang_nano20k/10-video.html).

---

## Hardware Required

| Item | Notes |
|------|-------|
| Sipeed Tang Nano 20K | GW2AR-LV18 FPGA |
| MicroSD / TF card | FAT32, ≤ 32 GB |
| HDMI cable + display | HDMI 1.3+; see the compatibility note above |
| Keyboard (recommended) | USB keyboard + CH9350 USB-host board or Raspberry Pi Pico → 5V, GND, TX → **pin 53** |
| DB9 joystick(s) | Standard Atari/Commodore digital sticks, wired to header pins (no DB9 connector on the board) |
| Dupont jumper wires | To wire the keyboard adapter and joysticks |

Wiring, DIP-switch settings, the Pico frame format and LED meanings:
[manual §2](https://carlosbravoa.github.io/atari800_tang_nano20k/02-hardware.html).

---

## SD Card Setup

Format a MicroSD card as **FAT32**. Place these files in the root directory:

```
/
├── ATARIXL.ROM   ← Atari XL/XE OS ROM, exactly 16384 bytes
├── BASIC.ROM     ← Atari BASIC ROM, exactly 8192 bytes
├── HDD.ATR       ← optional: auto-mounts on D4: at every boot (your "hard drive")
├── HDD/          ← optional: the H: device's folder, shared with the PC link
├── games/        ← your .atr disks and .car/.rom cartridges, any folders,
└── ...              long filenames fine
```

File names are matched case-insensitively. You must supply your own ROM images — they are not
included in this repository. `atari.ini` (the saved OSD options) is created in the root by the
firmware.

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

Close any PC Link session (`atari.py log`/`kbd`, the desktop app) before flashing.

---

## PC Link (serial bridge over the USB-C)

The same USB-C cable that powers/flashes the board carries a serial port (the onboard BL616
bridges it to the FPGA). `pip install pyserial`, then:

```bash
python3 tools/atari.py ping                 # A8OK = the machine answers
python3 tools/atari.py send GAME.ATR        # -> /PC/GAME.ATR on the SD card
python3 tools/atari.py run  build/demo.xex  # push + boot (the make-run dev loop)
python3 tools/atari.py type listing.bas     # paste as keystrokes
python3 tools/atari.py screen               # text dump of the Atari's screen
python3 tools/atari_gui.py                  # the desktop app
```

All 16 commands, the app, printer capture, the H: folder, the D4: hard drive and remote
debugging: [manual §13](https://carlosbravoa.github.io/atari800_tang_nano20k/13-pc-link.html)
and [`docs/pc_link_guide.md`](docs/pc_link_guide.md). Linux: `sudo modprobe ftdi_sio` if no
`/dev/ttyUSB*` appears.

---

## Pin Reference

Pins from `constraints/tang_nano_20k.cst` (the authority if this table and the code ever differ).

| Function | FPGA pin | IO name | Dir |
|----------|----------|---------|-----|
| System clock (27 MHz) | 4 | LPLL1_T_in | in |
| Reset button S1 | 88 | — | in |
| OSD button S2 | 87 | — | in |
| LEDs LED2–LED5 (SIO data, booted, SIO cmd, heartbeat) | 17–20 | IOL49A–IOL51B | out |
| HDMI TMDS CLK +/− | 33, 34 | IOB24A/B | out |
| HDMI TMDS D0 +/− | 35, 36 | IOB30A/B | out |
| HDMI TMDS D1 +/− | 37, 38 | IOB34A/B | out |
| HDMI TMDS D2 +/− | 39, 40 | IOB40A/B | out |
| SD CLK / MOSI / MISO / CS | 83 / 82 / 84 / 81 | — | out/out/in/out |
| Keyboard UART RX (CH9350/Pico TX) | 53 | IOR38B | in |
| PC Link TX (→ BL616 → USB-C serial) | 69 | IOT44B | out |
| PC Link RX (← BL616) | 70 | IOT50A | in |
| Joystick 1 Up / Down / Left / Right / Fire | 27 / 28 / 25 / 26 / 29 | IOB8A / IOB8B / IOB6A / IOB6B / IOB14A | in |
| Joystick 2 Up / Down / Left / Right / Fire | 42 / 41 / 56 / 54 / 48 | IOB42B / IOB43A / IOR36A / IOR38A / IOR49B | in |

Never wire user inputs to pins **69–76/79** (BL616 UART/HSPI, WS2812 — the always-on BL616 drives
them) or **51** (PLL clock input). Analogue GPIO audio was removed; pins 25/26 now carry Joystick 1
Left/Right. HDMI audio is the audio output.

---

## Directory Structure

```
atari800_tang_nano20k_parallel/
├── build.tcl                  # Gowin build script (synthesis + P&R + bitstream)
├── constraints/
│   └── tang_nano_20k.cst      # Physical pin constraints
├── firmware/
│   ├── firmware.c             # PicoRV32 firmware (OSD, ROM loader, SIO, PC link)
│   ├── bin2bram.py            # firmware.bin → BSRAM init hex (4 byte lanes)
│   ├── baremetal.ld           # linker: 64 KB BSRAM region + stack-headroom guard
│   └── Makefile
├── manual/                    # the user manual (plain HTML; published to GitHub Pages)
├── rtl/                       # Upstream Atari core VHDL
│   └── common/a8core/         # 6502, ANTIC, GTIA, POKEY, PIA, SIO
├── tools/                     # PC Link (USB-C serial): CLI, desktop app, PDF typesetter
│   ├── atari.py               # CLI: send/run/type/kbd/reset/status/screen/peek/poke/log…
│   ├── atari_link.py          # protocol library (shared by CLI + app)
│   ├── atari_gui.py           # desktop app (Tkinter, Linux/Windows)
│   └── dotmatrix_pdf.py       # 820-style 5×7 dot-matrix PDF renderer
├── test/
│   └── fatfs_host/            # host-side FatFs volume-safety suite (run before HW disk tests)
├── docs/                      # design notes and specs
└── src/                       # Tang Nano-specific SystemVerilog / Verilog
    ├── tang_top.sv            # Top-level module (arbiter, clocks, input masking, OSD mix)
    ├── gw2ar_sdram.sv         # SDRAM handshake adapter (clk_core <-> clk_mem)
    ├── sdram_nestang.v        # Low-latency SDRAM controller (NESTang-derived)
    ├── scandoubler_480p.sv    # Genlocked line-buffer scandoubler (Atari video → 1056×720, 3×, scanlines)
    ├── rpll_287m.v            # Cascaded PLL: 114.75 → 286.875 MHz (HDMI 5×, pixel = 2× core)
    ├── iosys_picorv32.v       # PicoRV32 IO subsystem (OSD, SD); firmware in BSRAM
    ├── textdisp.v             # OSD text renderer (panel, bars, selection row)
    ├── fw_bram.v              # 64 KB byte-laned BSRAM firmware boot RAM
    ├── fw_lane{0..3}.hex      # firmware BSRAM init (generated by bin2bram.py)
    ├── hdmi_audio_out.sv      # HDMI wrapper (hdl-util/hdmi library)
    ├── usb_to_atari800.sv     # HID codes → Atari keyboard matrix / console keys
    ├── uart_kbd_ch9350.sv     # Hardware CH9350/UART keyboard decoder
    ├── simplespimaster.v      # SPI master (SD card)
    ├── simpleuart.v           # UART (keyboard RX + PC-Link TX)
    ├── picorv32.v             # PicoRV32 RISC-V softcore
    └── hdmi2/                 # hdl-util/hdmi library (720p TMDS)
```

---

## Known Limitations / Roadmap

- **NTSC only** (`PAL=0`); some PAL-timed titles glitch (see `KNOWN_ISSUES.md`). A runtime switch is planned
- **`.xex` loader** lives in page `$0600–$07FF`; a program that loads there can clash with it
- **N:** network device — working prototype, not release-grade under sustained load
- **R:** 850 modem — work in progress, opt-in (default OFF, zero effect when off)
- **Paddles** — analogue pot inputs not implemented
- **The!Cart 32/64/128 MB** cannot fit the 8 MB SDRAM; unsupported `.car` types show their id
- **F12** can be unresponsive while a PC serial session is engaged — S2 always works

---

## Credits & Licences

> **Non-commercial project.** The Atari core this port is built on is offered by its
> author for non-commercial use only, so the repository and the released `.fs`
> bitstreams may be used and shared for **non-commercial purposes only**. Commercial
> use needs explicit permission from Mark Watson (`scrameta@gmail.com`) — and from the
> other copyright holders whose licences don't already allow it.
> **[`LICENSE`](LICENSE) is the authoritative, per-component map.**

| Component | Author | Terms |
|---|---|---|
| **Atari 8-bit core** — [Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer) / atari800core (`rtl/`, ~45 files) | Mark Watson | Custom **non-commercial** notice ([text](LICENSES/Mark-Watson-NonCommercial.txt)) |
| **6502 core** — FPGA 64 `cpu_65xx.vhd` | Peter Wendrich | "All Rights Reserved" header, reaches us via the core above |
| **Cart bank switching / PBI ROM** | Matthias Reichl, Wojciech Mostowski | LGPL v2-or-later |
| **IO subsystem** (PicoRV32 host, OSD text display, SPI/UART) — adapted from [nestang](https://github.com/nand2mario/nestang) | nand2mario | **GPL-3.0** |
| **Firmware base** (`firmware/`) — [firmware-picorv32](https://github.com/nand2mario/firmware-picorv32) | nand2mario | No licence file upstream; ships in NESTang under GPL-3.0 and is treated as such here |
| **PicoRV32** — [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) | Claire Xenia Wolf | ISC |
| **FatFs** (`firmware/fatfs/`) | ChaN | 1-clause BSD |
| **USB HID host** — [nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host) | nand2mario | Apache 2.0 |
| **Low-latency SDRAM controller** — [sdram-tang-nano-20k](https://github.com/nand2mario/sdram-tang-nano-20k) | nand2mario | Apache 2.0 |
| **HDMI library** — [hdl-util/hdmi](https://github.com/hdl-util/hdmi) | Sameer Puri | MIT **or** Apache 2.0 |
| **SD-card reader** (in tree, not built) — [FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader) | WangXuan95 | GPL-3.0 |
| **This Tang Nano 20K port** — everything else | Carlos Bravo | **CC BY-NC-SA 4.0 _or_ GPL-3.0-or-later**, your choice ([`LICENSE-PORT`](LICENSE-PORT)) |

Our `sdram_nestang.v` is nand2mario's controller with a 32-bit masked-write path and
half-rate BL2 burst reads added — huge thanks, this is what made the low-latency,
corruption-free core possible. `rtl/common/a8core/antic.vhdl` also carries our own
one-line fix to an upstream ANTIC bug (mode-8 HSCROL); as a derived work it stays
under Mark Watson's terms.

Full licence texts live in [`LICENSES/`](LICENSES/). Every source file's own header
notice is authoritative for that file — please keep them intact.
