# PC Link & Storage — user guide

Everything you can do over the board's **USB-C cable** (the same one that powers
and flashes it), plus the two "extra drive" features on the SD card. No added
hardware: the onboard BL616 bridges a serial port to the firmware.

- **`tools/atari.py`** — command-line tool (send files, boot builds, type,
  remote keyboard, reset, telemetry).
- **`tools/atari_gui.py`** — the same things in a desktop window.
- **D4: hard drive** — an always-mounted disk image on the SD (`HDD.ATR`).
- **H: device** — a folder on the SD shared between the Atari and the PC.

---

## 1. One-time setup

```bash
pip install pyserial
sudo apt install python3-tk     # desktop app only (Windows python.org has Tk)
sudo modprobe ftdi_sio          # Linux, if no /dev/ttyUSB* appears
```

The board enumerates as a **pair** of serial ports; the tools auto-pick the
right one (the second of the pair). If autodetect ever guesses wrong, pass
`-p /dev/ttyUSB1` (or `COM5`, etc.). Check the link:

```bash
python3 tools/atari.py ping        # -> "A8OK — bridge is alive"
python3 tools/atari.py ports       # list candidate ports
```

> The Atari has separate power, so it keeps running no matter what the PC does;
> a failed command is always safe to retry.

---

## 2. `atari.py` — command reference

| Command | What it does |
|---|---|
| `ping` | Is the bridge alive? → `A8OK` |
| `ports` | List candidate serial ports |
| `log` | Tail live firmware logs (Ctrl-C to stop) |
| `send FILE [NAME]` | Copy `FILE` to the SD. Default lands in `/PC/<file>`; `NAME` may include folders (`GAMES/X.ATR`, `HDD/NOTES.TXT`) |
| `send FILE NAME --text` | Same, but convert `\n` line endings to ATASCII `$9B` — use for **text** you'll read from BASIC (`ENTER`, `INPUT`) |
| `run FILE.XEX` | Send **and boot** a `.xex` — the edit-compile-run loop for cross-development |
| `type FILE` \| `type -` | Paste text as keystrokes (~18 chars/s). `-` reads stdin. **Close the OSD first.** |
| `kbd` | Live remote keyboard: what you type on the PC lands on the Atari. `Ctrl-]` exits; F12 on the Atari's own keyboard hands control back |
| `eject` | Pop the virtual `.xex` off D1: |
| `reset [--warm] [--keep]` | Eject + cold boot. `--warm` = warm start; `--keep` = don't eject first |
| `status` | One-line telemetry: boot stage, mounted drives, SIO counters, stack canary |
| `screen` | Text dump of the Atari's screen (GRAPHICS 0), read from its own memory |
| `peek ADDR [LEN]` | Hex-dump Atari memory (`peek 0x12 3` = the jiffy clock) |
| `poke ADDR B [B…]` | Write bytes into Atari memory (`poke 0x2C8 0x35` = pink border) |
| `hdd-install` | Install the **H:** device handler (see §5) |
| `fwpeek ADDR [LEN]` | Hex-dump the **firmware's** memory (debugging aid) |

Every command takes `-p PORT`.

---

## 3. `atari_gui.py` — the desktop app

```bash
python3 tools/atari_gui.py
```

Same protocol as the CLI, in a window:

- **Connect** (top) — port auto-detected; shows `A8OK` when the Atari answers.
- **Left column** — *Send file…*, *Run .xex…* (with a **Destination folder**
  field, default `PC`), *Eject*, *Warm start*, *Cold boot*, *Ping*. Text files
  (`.txt`/`.lst`/`.bas`) sent here are auto-converted to ATASCII line endings.
- **Log tab** — live firmware output; *Clear* / *Save…*.
- **Type tab** — write or load a BASIC listing, then *Type it on the Atari*
  (line-by-line, self-healing across USB hiccups).
- **Printer tab** — anything the Atari prints (see §6) collects here;
  *Save as .txt*, *Save as PDF* (820-style 5×7 dot matrix), *Print…* (your
  system printer), *Clear*.
- **Live Keys tab** — click the box and type straight onto the Atari.

---

## 4. The D4: "hard drive" — `HDD.ATR`

An always-present extra drive, no PC needed once it's set up.

1. Put a disk image named **exactly `HDD.ATR`** in the **root of the SD card**
   (case-insensitive). Any `.atr` works; a **MyDOS**-formatted image is ideal
   because MyDOS can address images up to 16 MB — a genuinely big hard disk.
2. Power on. The firmware auto-mounts it on **D4:** at every boot — `status`
   shows `m:…1` and the log says `boot: hdd mounted on D4`.
3. From your DOS, D4: is just there: directory it, save/load files, and it all
   survives reboots.

Ways to create/fill `HDD.ATR`:

- **From the PC:** copy any big MyDOS ATR to the SD as `HDD.ATR` — over the
  cable it's `python3 tools/atari.py send mydos_big.atr HDD.ATR`, then power-
  cycle so the automount picks it up (the automount runs once at firmware
  start).
- **From the Atari:** OSD → a drive → *New blank disk* makes a 90K ATR; rename
  it to `HDD.ATR` later, or just keep using the classic D1:/D2: mounts.

> **Backup is trivial:** `HDD.ATR` is one file. Keep a copy on the PC; if the
> disk ever gets scrambled, `send` the copy back and power-cycle. The PC-side
> copy *is* your backup.

### What if there's no `HDD.ATR`, or the wrong kind?

The automount is **fail-safe and opt-in** — it can never break your boot:

- **No `HDD.ATR` on the card:** nothing happens. D4: simply isn't there, the
  machine boots normally, and a DOS that asks for D4: just gets "drive not
  present." (Same for a corrupt or non-ATR file named `HDD.ATR` — the firmware
  checks the ATR header and quietly declines to mount it.)
- **A valid image, but formatted for a *different DOS* than the one you boot:**
  D4: **does** mount — the firmware serves its sectors faithfully, exactly like
  a floppy in a real drive — but your **running DOS may not read it**. Typical
  symptoms: a garbled directory, "not a DOS disk," or `0000 FREE SECTORS`.
  Common mismatches:
  - a big **MyDOS** image while you booted **DOS 2.5** — DOS 2.5 caps at
    90K/130K and can't address the extra space, and by default it only polls
    D1:/D2: (you'd need `POKE 1802,15` for it to even see D4:);
  - an image in a filesystem your DOS doesn't understand (e.g. SpartaDOS read
    by MyDOS, or vice-versa).

  **The cure:** format `HDD.ATR` with the *same* DOS you boot. **MyDOS 4.5x is
  the recommended pairing** — format the image with MyDOS and boot MyDOS, and
  its full capacity is usable.

---

## 5. The H: device — a folder shared with the PC

H: is a **CIO device** (a peer of P:, E:, K:), not a disk — DOS doesn't list it
and doesn't need to. Files written to H: land as **plain files in `/HDD`** on
the SD's FAT filesystem: the same folder the PC writes into. That makes H: the
seamless bridge for **text and data files** between the two worlds.

**Install it first (from the PC):**

```bash
python3 tools/atari.py hdd-install
# -> "H: installed at $0900-$0CB2 (above MEMLO), MEMLO raised to $0D00."
```

The installer reads **MEMLO** and places the handler just above it (with a
resident DOS booted it simply lands higher — no collision), then raises MEMLO
past its end. The handler lives in Atari RAM and is **session-scoped**: a
RESET clears it — re-run `hdd-install` to restore.

> ⚠️ **Type `NEW` in BASIC right after installing.** BASIC only re-reads the
> raised MEMLO on `NEW`; until then its program area still overlaps the
> handler, so install first, `NEW`, *then* `ENTER`/type your program.

**Use it from BASIC:**

```basic
REM --- write ---
OPEN #1,8,0,"H:NOTES.TXT"
PRINT #1;"WRITTEN FROM BASIC"
CLOSE #1

REM --- read back ---
OPEN #1,4,0,"H:NOTES.TXT"
DIM A$(40):INPUT #1,A$:PRINT A$
CLOSE #1

REM --- store/recall a program (plain ATASCII, PC-readable) ---
LIST "H:PROG.LST"
ENTER "H:PROG.LST"

REM --- directory with sizes ---
OPEN #1,6,0,"H:"
DIM D$(40)
FOR I=1 TO 999:INPUT #1,D$:PRINT D$:NEXT I
CLOSE #1

REM --- delete ---
XIO 33,#1,0,0,"H:NOTES.TXT"
```

OPEN modes: `4` = read, `8` = write, `9` = append, `6` = directory, `12` = update.

---

## 6. Recipes

### Paste a short BASIC program from the PC → Atari
Keystroke injection — works with or without DOS. **Close the OSD first.**

```bash
python3 tools/atari.py type mygame.bas
```

Or from your editor via a pipe:

```bash
cat mygame.bas | python3 tools/atari.py type -
```

Then on the Atari: `RUN` (and `SAVE "D4:MYGAME.BAS"` if a DOS is booted).

### Load a long program PC → Atari without the typing
Typing thousands of characters is slow and stresses the link. Instead push the
listing as a file and `ENTER` it (needs H: installed — so a BASIC session):

```bash
python3 tools/atari.py send --text mygame.lst HDD/MYGAME.LST
```
```basic
ENTER "H:MYGAME.LST"
RUN
```

### Push-and-run a compiled program (cross-dev loop)
```bash
python3 tools/atari.py run build/demo.xex     # sends + cold-boots into it
```
A remotely-run `.xex` shows up on the OSD's D1: line; `atari.py eject` removes it.

### Get a program's listing from the Atari → PC
There's no file *download* over the bridge yet, but the Atari can **print** to
the PC. List your program to the printer device and capture it:

```basic
LIST "P:"
```
On the PC it arrives as text — `python3 tools/atari.py log` shows it live, or
the desktop app's **Printer tab** collects it (then *Save as .txt*). The same
path captures `LPRINT` and AtariWriter's print function.

### Share data files both ways
- PC → Atari: `python3 tools/atari.py send --text data.txt HDD/DATA.TXT`, then
  `OPEN #1,4,0,"H:DATA.TXT"` on the Atari.
- Atari → PC: write to H: from BASIC (`OPEN #1,8,0,"H:OUT.TXT"` …). The file is
  now `/HDD/OUT.TXT` on the SD; the PC sees it directly the next time it can
  read the card, and any later `send` to the same folder sits beside it. (A
  bridge "get" command to pull H: files straight back to the PC is planned.)

### Remote debugging / "AI eyes"
```bash
python3 tools/atari.py status                 # boot stage, mounts, SIO health
python3 tools/atari.py screen                 # what's on the Atari screen now
python3 tools/atari.py peek 0x12 3            # jiffy clock (is it alive?)
python3 tools/atari.py poke 0x2C8 0x35        # tint the border pink
```

---

## 7. Limitations to know

- **H: install is session-scoped**: RESET clears it (re-run `hdd-install`).
  It installs above MEMLO (coexists with a resident DOS — bug #19 fixed), but
  BASIC only picks up the raised MEMLO on `NEW` — install first, then `NEW`,
  then load your program.
- **No file download from the SD over the bridge yet** — Atari→PC text goes via
  the printer path (`LIST "P:"` / `LPRINT`); a `get` command is planned.
- **The `HDD.ATR` automount runs once at firmware start** — after you `send` a
  new one, power-cycle the board for it to take effect.
- **`type` needs the OSD closed** (an open menu eats keystrokes).
- **Long `type` sessions** can occasionally drop the USB link; the tools
  self-heal and retry, but the H:+`ENTER` route (above) avoids the issue for
  big programs.
