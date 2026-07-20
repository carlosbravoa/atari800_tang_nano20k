# Bench test plan — H: hard drive + N: network (feature/hdd-net branch)

*Everything below was built unattended and validated in simulation only:
host FatFs suite (12 scenarios), py65 CIO matrix (14 checks), and a full
N: loopback sim. This plan is the first hardware contact. Branch:
`feature/hdd-net`; flash the archived build whose md5 matches the flash-window
message. Roll back anytime: `releases/atari800_tn20k_v2.7.1` = last release.*

## What's in the build

| Piece | State |
|---|---|
| Four drive slots (D1:–D4:), `/HDD.ATR` auto-mounts on D4: at boot | sim-tested |
| H: file device (SIO `$72` → `/HDD` folder on SD) | host-suite green |
| H: CIO handler (`$0900`, installed by `atari.py hdd-install`) | py65 green |
| N: network device (SIO `$71` ↔ `tools/atari_net.py`) | loopback green |
| STATUS line gains `hd:XY nt:S,avail` | — |

## Phase 0 — regression guard (5 min, do first)

1. Flash; cold boot → BASIC `READY` (telemetry: `status` shows `bs:4 rom:0`).
2. `atari.py screen` / `ping` / `run` a rainbow — the v2.7.1 feature set intact.
3. Mount a game disk on D1:, play a minute; `LPRINT "STILL WORKS"`.
4. Debug line: no `!` (canary), `m:` shows four digits now.

**Anything off here → stop, report, reflash v2.7.1.** The new devices are
dormant without their triggers, so phase 0 failing means an integration
mistake, not a device bug.

## Phase 1 — rung-1 hard drive (5 min)

1. Copy any big MyDOS-formatted ATR to the SD as `/HDD.ATR` (or create with
   New-blank-disk + rename via PC: `atari.py send blank.atr HDD.ATR`).
2. Cold boot → `status` shows `m:1001`-style (D4 mounted); boot log line
   `boot: hdd mounted on D4`.
3. From DOS: directory of `D4:` works; save/load a file; survives reboot.

## Phase 2 — H: device (15 min, the centerpiece)

1. Boot to BASIC. From the PC: `python3 tools/atari.py hdd-install`
   (expect: "installed at $0900-… MEMLO raised").
2. On the Atari (or via `atari.py type -`):
   ```basic
   OPEN #1,8,0,"H:HELLO.TXT"
   PRINT #1;"WRITTEN FROM BASIC"
   CLOSE #1
   ```
3. On the PC: `atari.py status` → `hd:` flags used a channel; the file exists:
   check `/HDD/HELLO.TXT` appears (eject SD later, or trust step 4).
4. Read it back on the Atari:
   ```basic
   OPEN #1,4,0,"H:HELLO.TXT"
   GET #1,A : PRINT CHR$(A);   (or INPUT #1,A$ : PRINT A$)
   CLOSE #1
   ```
5. Directory: `OPEN #1,6,0,"H:"` + GET loop → listing with sizes.
6. `LIST "H:PROG.LST"` and `ENTER "H:PROG.LST"` — the classic workflow.
7. PC-side round trip: `atari.py send notes.txt HDD/NOTES.TXT` on the PC,
   then read `H:NOTES.TXT` from BASIC — **files shared between both worlds.**
8. XIO: `XIO 33,#1,0,0,"H:HELLO.TXT"` deletes; confirm via directory.
9. RESET → H: gone (expected, session-scoped) → `hdd-install` again → works.
10. Telemetry note for any failure: `status` (`hd:` + SIO fields), `log`
    during the op, and the OSD debug line.

## Phase 3 — N: plumbing (10 min; protocol-level — no 6502 handler yet)

*No CIO handler on the Atari yet, so this phase drives the SIO layer from
BASIC via a direct SIOV call, proving firmware + PC processor + real TCP.*

1. On the PC: `python3 tools/atari_net.py` (leave running; it's also your log).
2. Second terminal: `nc -l 12345` (a local "BBS").
3. On the Atari, the test one-liner (via `atari.py type -` before starting
   atari_net, or typed by hand): a small BASIC program POKEs the DCB for
   device `$71` OPEN with spec `N:TCP://<PC-IP>:12345/` and calls SIOV via
   `USR(58459+2)`-style stub — **the exact listing is in
   `tools/net_basic_test.txt`** (generated; `atari.py type` it).
4. Expect: atari_net prints `OPEN`/`connected`; `nc` shows sent bytes;
   typing into `nc` → `status` shows `nt:1,<avail>` growing; the BASIC
   read-back loop prints what you typed.
5. Failure telemetry: atari_net's console (it logs every event frame),
   `status` `nt:` field, firmware log.

## Phase 4 — soak & interaction (10 min)

- H: write loop (100 records) while a D1: game disk is mounted and read.
- `atari.py screen` + `send` during an open H: channel (bridge + SIO coexist).
- Cold boot ×3: auto-mount comes back, no boot regressions, canary clean.

## Known limitations going in (not bugs)

- H:/N: handler install is session-scoped (RESET clears HATABS; re-run
  `hdd-install`). Boot-poll persistence is the next round.
- N: has no CIO handler yet — BASIC `OPEN #1,...,"N:..."` comes with it.
- One N: connection; 128-byte SIO chunks; ~11 KB/s link ceiling shared.
- H: filenames: 8.3 upper, one dot; `/HDD` root only (H1:–H4: subfolders later).
