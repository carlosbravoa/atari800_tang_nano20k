# PC↔Atari serial bridge over the onboard USB-C (BL616 UART) — plan

*2026-07-16 — planning doc. Prerequisite: the 64 KB BSRAM milestone
(`feature/bsram-64k`) confirmed rock-solid on hardware.*

## Goal

A seamless PC↔firmware channel over the **existing USB-C cable** (no extra hardware):
push files to the SD card, push-and-boot `.xex` builds, inject keystrokes (paste BASIC),
and stream firmware logs to the PC. Foundation for later folder-virtual-disk or
RespeQt/SIO2PC modes.

## Why this channel

The onboard BL616 exposes a USB CDC serial port to the PC and its UART runs to FPGA
pins **69 (BL616 TX → FPGA RX)** and **70 (FPGA TX → BL616 RX)**. The iosys already
contains a `simpleuart` (the firmware sets `reg_uart_clkdiv = 234` = 115200 @ 27 MHz)
whose TX is unconnected and whose RX is currently pointed at the keyboard line — i.e.
the FPGA/firmware side is 90% built and idle.

## Phase 0 — bench verification (BEFORE any RTL), one session

1. **BL616 CDC bridging**: confirm the stock BL616 firmware presents a serial port on
   the PC and forwards it to pins 69/70 (loopback: jumper nothing — drive pin 70 from a
   test bitstream, watch the PC port; then PC→69). Determine usable baud (115200 first;
   probe 921600).
2. **Pin directions** against the Tang_Nano_20K_3921 schematic (authority rule).
3. **Flashing interference** (the user's flagged question):
   - Gowin programming goes over **JTAG** via the BL616 — different pins/interface than
     the UART, so no direct conflict is expected, **but verify**: flash + SRAM-program
     with a bitstream that actively drives pin 70.
   - **BL616 boot-strap risk**: BL60x-family chips can enter UART bootloader mode at
     reset. If the FPGA holds pin 70 (BL616's RX) in a state the boot ROM interprets as
     a download attempt, the BL616 could fail to start its bridge firmware → the board
     looks unprogrammable. Mitigation to test: UART idle = mark = HIGH (same as
     pulled-up idle, indistinguishable from no driver); confirm a full cold power-on
     with the FPGA image auto-loading from flash still enumerates the programmer.
   - **Port contention**: our PC tool holding the CDC port open while the Gowin
     programmer runs — verify they're separate USB interfaces; document "close the
     tool before flashing" if not.

## Phase B — minimal bridge (netlist change #2, small)

- RTL: route iosys `uart_rx` ← pin 69, `uart_tx` → pin 70 (CST + 2 top-level wires).
  Keyboard stays on its own dedicated decoder (pin 53) — no sharing.
- Firmware: keep `uart_printf` as-is (it instantly becomes live log streaming — the
  observability gap closes), add a tiny RX poll in the main loops + packet protocol v1:
  - `PING`/version, `PUT <path>` (chunked, CRC per chunk, written via FatFs),
    `LS <dir>`, `DEL <path>`.
  - Frame: `0xA5 cmd len16 payload crc16`; firmware replies `ack/err(code)`.
  - FS safety: every new firmware FS call gets a scenario in `test/fatfs_host/`
    BEFORE hardware (hard rule since the SD incident).
- PC tool: python+pyserial `atari.py` — `atari send <file> [/dest]`, `atari ls`,
  `atari log` (tail firmware output).
- Verify protocol: HDMI canary re-check (netlist change), then HW test round (user).

## Phase C — the dev-loop features

- `RUN <file.xex>`: PUT + firmware mounts it via the existing attach-auto-boot path
  (`mount_xex` + `cold_boot_xex`) → `make && atari run build/game.xex` ≈ 5 s cycle.
- `KEY <text>`: inject keystrokes via the existing `reg_virt_kbd_*` registers with
  pacing (paste BASIC listings, drive menus remotely, scripted testing).
- Nice-to-haves: `GET` (pull a file/ATR back to the PC), `STATUS` (debug-line values
  over serial — remote triage without reading the screen).

## Phase D — candidates after that (pick by appetite)

- **Folder-as-virtual-disk**: firmware synthesizes a DOS 2.5 filesystem from an SD
  folder (D3:). Composes with PUT: push a .BAS, Atari sees it on a disk.
- **RespeQt/SIO2PC bridge mode**: forward raw SIO over the serial link; mature PC
  tooling (folder images, printers) for free. CDC latency vs SIO ACK windows is the
  open question — measure in Phase 0.
- FujiNet (separate analysis: `docs/fujinet_esp32_bridge.md`) remains the networking
  endgame; independent channel, no conflict.

## Sizing (post-64 KB there is room)

Protocol v1 firmware ≈ 2–4 KB text + a 256–512 B RX buffer — trivial inside the
~16 KB code + ~20 KB stack headroom the 64 KB layout provides.

## Sequencing rule (user-set, hard)

One netlist change per test round: (1) BSRAM 64 KB ← current branch, soak it;
(2) UART pins + protocol v1; (3) each later phase separately. No new builds while a
round is under test; every build quoted by payload md5.
