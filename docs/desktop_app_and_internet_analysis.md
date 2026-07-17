# Investigation: desktop app for the PC Link + internet for the Atari (BobTerm)

*2026-07-16 — analysis. Both build on the v2.5 serial bridge.*
*Status 2026-07-17: Feature 1 (desktop app) IMPLEMENTED (`tools/atari_gui.py`).
Feature 2 (internet/850) is SPEC-ONLY by decision — no strong use case beyond
novelty; this document is the spec if it's ever picked up.*

---

## Feature 1 — Desktop app (Linux + Windows) for the USB umbilical

### Verdict: easy, low-risk, pure PC-side. No firmware/RTL changes at all.

The protocol is done and proven (`tools/atari.py`, 9 commands). A desktop app is a GUI
over the same wire format.

### Recommended stack: Python + Tkinter, packaged with PyInstaller

| Option | Weight | Cross-platform | Fit |
|---|---|---|---|
| **Tkinter (stdlib)** | ~0 new deps (pyserial only) | yes | **Recommended** — the UI is buttons + a log pane; stdlib ships with Python |
| PySide6/Qt | ~1 GB toolchain, 80 MB bundles | yes | Prettier, unjustified for this scope |
| Tauri/Electron | web stack + Rust/Node | yes | Way overweight for a serial utility |
| Native (Rust/Go) | rewrite the protocol | yes | Duplicates proven code for no user benefit |

**Structure:** refactor `tools/atari.py` into `tools/atari_link.py` (protocol library:
`AtariLink` class with `ping/send/run/type_text/kbd/reset/eject`, callback for progress
and log lines) + thin CLI (existing commands) + `tools/atari_gui.py` (Tkinter). One
protocol implementation, three consumers. The refactor also makes the protocol unit-
testable against a mock serial.

**MVP window (a day of work):**
- Port picker (auto-pick logic already exists) + connect/status indicator (`ping`)
- "Send file…" / "Run .xex…" buttons with progress bar (protocol already acks per chunk
  — progress is free); destination folder field defaulting to `/PC`
- Reset / Warm / Eject buttons
- Live log pane (the `log` stream) with save-to-file
- Paste box → `type` (multiline text widget + "Type it" button)

**Phase 2 (another day):**
- Live keyboard mode: a "focus here to type on the Atari" capture widget
  (Tkinter `<KeyPress>` events → per-key protocol; Esc-equivalent to release focus)
- Drag-and-drop onto the window (needs the small `tkinterdnd2` dep — optional)
- `.xex` header validation + recent-files list; auto-`run` on drop of a `.xex`

**Packaging:**
- `pyinstaller --onefile` → single executable per OS. Linux: one binary. Windows: one
  `.exe`, no Python install needed.
- **Windows serial notes** (the actual platform work, ~an afternoon of testing):
  the BL616 enumerates as an FT2232 pair; Windows gets the FTDI VCP driver
  automatically via Windows Update (and the Gowin tools install it anyway) → two COM
  ports; the auto-pick "second port of the same-VID pair" logic carries over.
  No `modprobe` equivalent needed. Only risk: a Windows box that never saw FTDI
  hardware and has Windows Update disabled — document the FTDI VCP download link.
- CI idea (later): GitHub Actions matrix builds the two binaries per release tag.

**Risks:** essentially none to the device — the app can't do anything the CLI can't.
Effort total: **~2 days incl. Windows testing**; ship MVP first.

---

## Feature 2 — Internet for the Atari (BobTerm & friends)

### How Atari comms software expects the world to look

BobTerm (and Ice-T, AMODEM, …) talk to a modem through the **R: device**, provided by
the **Atari 850 interface** (or compatible). Two-layer protocol:

1. **Command phase** — R: handler sends SIO command frames to device `0x50` (R1:):
   OPEN/CLOSE, STATUS, WRITE (short blocks), BAUD/config. Same shape as our disk
   emulation — our firmware already dispatches SIO command frames; adding device 0x50
   is the established pattern.
2. **Concurrent mode** — the interesting part. For terminal use the handler issues a
   "start concurrent mode" command, after which the SIO bus stops carrying command
   frames and becomes a **raw full-duplex serial line** between POKEY (reprogrammed to
   the session baud, 300–19200) and the modem — until the handler drops back out.
   Terminal programs live in this mode almost the whole session.
3. **Handler loading** — R: isn't in the OS ROM. A real 850 *serves its handler to the
   OS at boot* over SIO (the type-3/4 poll bootstrap). We can implement the same
   bootstrap so R: appears with zero user setup — but the classic 850 handler binary is
   Atari IP (same situation as OS ROMs: user supplies the file, e.g. on the SD card),
   or we ship an open-source handler (candidates exist in the FujiNet ecosystem —
   license check needed). Fallback that always works: user loads a handler from disk
   (AUTORUN.SYS on their BobTerm disk, standard practice back in the day).

### Option A — 850-in-firmware + PC as the modem (RECOMMENDED lean path)

The firmware emulates the 850 (command phase + concurrent mode); the modem itself is
the PC: `atari.py modem` (or the desktop app) implements a **Hayes AT emulator bridged
to TCP** — `ATDT bbs.fozztexx.com:23` → TCP connect, bytes flow both ways. This is
exactly the architecture of `tcpser` (the standard retro-modem-to-telnet tool) — we
can even document "use tcpser via a pty" as an alternative front end.

What it takes:
1. **Firmware: 850 command set for device 0x50** (~6 commands + status bytes) — same
   dispatch table as the disks. *Firmware-only.*
2. **Firmware: concurrent mode + channel mux — the hard 30%.** In concurrent mode the
   firmware must shovel raw bytes between the SIO side and the PC link. Two sub-problems:
   - **SIO side at session baud**: our `sio_handler` UART divisors are firmware-set
     (the TX divisor is already a register; RX divisor likewise). Needs verification
     that both directions can run at 1200–19200 cleanly — flagged as the primary
     technical risk, but the hardware regs exist.
   - **PC-link mux**: the bridge channel carries protocol acks + logs today. A raw
     modem stream needs framing — e.g. `0xA5`-prefixed packets: `[0xA5, MODEM_DATA,
     len, bytes…]` vs plain protocol bytes, with an escape for literal 0xA5. Modest,
     contained change; logs stay mutable via `bridge_quiet`.
3. **Firmware: handler bootstrap** (serve a user-supplied/open handler file from SD at
   the OS poll) — or skip in v1 and document disk-loaded handlers.
4. **PC: the modem** — AT command parser (ATDT/ATA/ATH/ATO + S-registers people
   actually use), TCP client, optional telnet IAC negotiation (BBSes want it),
   optional listening mode (incoming "calls"). tcpser is the reference; a useful
   subset is a few hundred lines of Python.

**Effort:** 2–4 sessions. 1 = command phase + loopback test; 2 = concurrent mode +
mux (the risk item); 3 = PC modem + BobTerm live test; 4 = polish (handler bootstrap,
desktop-app integration). Everything firmware-side is **firmware-only builds** (no
placement risk); the fatfs suite is untouched (no new disk writes).

**Payoff:** BobTerm dialing BBSes over your USB cable, no new hardware, fully in the
lean/self-contained spirit — the PC is only a modem, exactly like the real 1985 setup
except the phone line is TCP.

### Option B — FujiNet (ESP32) — the hardware endgame

Already analyzed (`docs/fujinet_esp32_bridge.md`). Gives R: *and* N: (native TCP for
FujiNet-aware software) *and* WiFi with **no PC tethered**. Real hardware + pins +
coexistence work. Option A doesn't compete with it — A is "my PC is my modem", B is
"the Atari is on WiFi". Both can exist; A first is the fast, zero-hardware win, and
its 850 learnings (concurrent mode, handler bootstrap) transfer directly.

### Options considered and set aside

- **BL616 reflash** (WiFi on the onboard chip): loses the flasher/bridge, against the
  self-contained principle for the *programmer* function. No.
- **RespeQt/APE PC servers**: RespeQt has no modem emulation; APE's is proprietary.
  Our own R: over the existing bridge is less work than adapting either.

---

## Recommendation summary

| | What | Risk | Effort | Prereqs |
|---|---|---|---|---|
| 1 | Desktop app (Tkinter + PyInstaller, shared protocol lib) | ~zero | ~2 days | none — start anytime |
| 2 | 850/R: in firmware + PC Hayes-TCP modem | concurrent-mode baud + mux (verifiable early) | 2–4 sessions | none (hardware-wise); handler-image sourcing decision |

Natural order: **refactor `atari.py` into the shared library first** (the app needs it,
and the modem's PC side plugs into the same place). Then either feature independently;
they don't conflict. If BobTerm-over-USB lands, the desktop app grows a "Modem" tab
(status, dial log) for free.
