# Serial-bridge test plan — build `cf5d1740` (branch `feature/serial-bridge`)

Step-by-step bench protocol. It verifies, in this order: flashing is unaffected → the
BL616 boots normally with our pins wired → logs flow (FPGA→PC) → ping works (PC→FPGA)
→ reflash still works → no Atari regressions. **Stop at the first failing step and
report the step number + what you saw** — each step isolates one question, so partial
results are already diagnostic.

## 0 — Prerequisites (one-time)

- [ ] Bitstream: `releases/test_serialbridge_cf5d1740.fs` (or `impl/.../atari800_tn20k.fs`,
      same payload `cf5d1740`).
- [ ] PC: `pip install pyserial` (any OS; on Linux make sure your user is in the
      `dialout` group or use `sudo` for the tool).
- [ ] Note your baseline: with the board running the OLD build, run
      `python3 tools/atari.py ports` and note which serial ports exist — so you
      recognize them later. (The BL616 typically shows 1–2 ports; they exist already
      today, we're just going to make one of them talk.)
- [ ] Close anything that might hold serial ports open.

## Part A — flashing + boot safety (your main question)

**A1. Flash the bridge build** with the Gowin programmer exactly as always
(external flash mode).
- Expected: programming completes normally.
- If it fails → STOP, report. (Would mean the programmer itself objects — nothing is
  bricked; the old bitstream is still flashable.)

**A2. Cold power cycle** — unplug USB-C fully, wait 5 s, replug.
- Expected: board powers, Atari auto-boots to BASIC as always, HDMI stable.
- This is the BL616 boot-strap test: the BL616 boots *before* the FPGA configures,
  and again our TX idles high once configured — both moments must leave it healthy.
- Repeat the cold cycle **3×** (the strap question deserves more than one sample).
- If the board is dead / won't enumerate → STOP, report. Recovery: hold BOOT? No —
  first just power cycle again; the BL616 is not reprogrammed by anything we did.

**A3. Verify the programmer still sees the board** (don't flash, just open the
programmer and scan/detect the cable+device).
- Expected: device detected as always.

## Part B — bridge functionality

**B1. List ports:** `python3 tools/atari.py ports`
- Expected: the same port(s) as your baseline. Note which one is which.

**B2. Logs (FPGA→PC):** `python3 tools/atari.py log` (add `-p PORT` if auto-pick
complains), then **power-cycle or press S1 reset** so the firmware boots while you
watch.
- Expected: firmware boot chatter appears — SD/ROM load messages like
  `ATR D1 ... ss 128`, xex/mount lines, etc. This is `uart_printf` finally live.
- If NOTHING appears on any port while the Atari boots fine → the stock BL616
  firmware doesn't bridge CDC↔UART (or wrong port/baud). Not a failure of the
  board — report and we reassess (the pins are inert). Try the other port first.

**B3. Ping (PC→FPGA):** with the Atari **booted** (BASIC running, OSD closed),
run `python3 tools/atari.py ping`.
- Expected: `A8OK — bridge is alive (both directions)`.
- Also try it with the **OSD menu open** — it should still reply (both loops poll).
- If B2 worked but ping times out → RX direction issue (pin 69 or receiver);
  report — logs still make half the feature real.

**B4. Log noise check:** leave `atari.py log` running ~2 minutes during normal
Atari use (type in BASIC, open/close the menu, mount a disk).
- Expected: only legitimate firmware messages (SIO/mount chatter); no garbage
  floods. (A byte storm would mean line noise — hasn't been a risk with the BL616
  driving the line, but confirm.)

## Part C — reflash safety

**C1. Close the log tool** (Ctrl-C — port must be free).

**C2. Re-flash the same bitstream** while the bridge build is running.
- Expected: programming works exactly as in A1. This is the "can I still flash
  after enabling serial" proof, under the worst realistic conditions.

**C3. (Optional, only if C2 failed with the tool open in another terminal):**
retry with every serial program closed — that would confirm a port-contention rule
rather than a real conflict.

## Part D — regression sanity (10 minutes)

- [ ] D1. Keyboard works: type in BASIC (the keyboard shares UART *infrastructure*
      but not the pins — this proves the separation).
- [ ] D2. OSD menu: open (F12/S2), navigate, close. Debug line normal, no `!`.
- [ ] D3. Disk round-trip: mount a DOS disk, `SAVE` a file, reboot from it.
- [ ] D4. A game loads and plays (any .atr/.xex you like).
- [ ] D5. One more cold power cycle at the end; HDMI stable.

## Report back

For the record, ideally: which steps passed (A1–D5), the port name that carried the
logs, one sample log line, and — if anything failed — the step number and symptom.

## Rollback

Any failure that matters: re-flash `releases/test_build7_91a4fa62.fs` (v2.4) or the
64 K build (`test_bsram64k_1e9bc4c9.fs`) — both known-good. Nothing in this test can
permanently affect the board: the BL616's own firmware is untouched, and JTAG
programming is independent of everything we added.
