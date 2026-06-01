# Hardware Keyboard Decoupling — Design & Implementation Plan

Status: **PLANNED** (no code written yet). Branch for work: `baseline-test` (do not commit there
without explicit instruction — it is the known-good fallback).

Last updated: 2026-05-31.

---

## 1. Why this exists (context — read before touching the keyboard path)

### 1.1 The symptom

For a long time this port has had a hard either/or: **either the keyboard works, or the Atari
boots/keeps correct timing — never reliably both at once.** The keyboard, when it works, works
every time. Tuning the SDRAM arbiter ("the governor") has never resolved the conflict; it only
moves the failure around.

### 1.2 The real root cause (confirmed)

The keyboard's liveness is **coupled to the SDRAM bus**, and it should not be.

Pipeline today:

```
Pi Pico (flashed as a CH9350-compatible HID→UART bridge)
  → UART RX on pin 51 (usb_dp)
    → simpleuart inside iosys_picorv32 (PicoRV32 softcore)
      → firmware uart_keyboard_poll() parses CH9350 frames     [firmware.c:1147]
        → writes reg_virt_kbd_0 / reg_virt_kbd_1 (MMIO 0x020000a0/a4)
          → virt_kbd_* wires
            → combined with USB-HID keys
              → usb_to_atari800.sv  (matrix impersonation)
                → core KEYBOARD_SCAN/RESPONSE → POKEY scanner → KBCODE/IRQ → 6502
```

The matrix end of this (usb_to_atari800 + POKEY scanner in the core) is already exactly the
"right way" described in `../Atari800/keyboard_emulation_reference.md`: we do **not** inject
keystrokes into the CPU; we impersonate the keyboard matrix and let POKEY's own scanner discover
the press. That part is correct and stays.

The problem is **Stage 1** (turning the wire into a held-key state). We do it in firmware running
on the PicoRV32 softcore. And the softcore executes **from SDRAM**:

- `firmware/baremetal.ld` places `.text`/`.data`/`.bss`/stack in the low region that maps to
  SDRAM (the section labelled `FLASH` is SDRAM origin `0x0`, not real flash). So **every
  instruction fetch is an SDRAM transaction.**
- Those fetches go through the same two-client SA_IDLE/SA_BUSY arbiter in `tang_top.sv` that the
  Atari core uses for all of its memory and ANTIC DMA.
- The code comment already says it (`tang_top.sv:308–310`):
  *"Atari's continuous requests starve PicoRV32 instruction fetches and the UART keyboard / menu
  becomes unresponsive."*

So `uart_keyboard_poll()` only runs — and `virt_kbd_*` only updates — when the arbiter spares the
softcore enough SDRAM slots. To make the Atari boot cleanly and keep ANTIC DMA timing correct,
the governor must give the Atari priority, which starves the softcore, which freezes the keyboard.
**That is the either/or, and it is structural, not a tuning bug.**

This is precisely the situation the Atlas reference is engineered to avoid. Its central rule:

> "The keyboard never arbitrates for the memory bus; its only bus contact is the IRQ handler's
> `LDA KBCODE`, an ordinary CPU read."

In the reference, Stage 1 is pure hardware (a PS/2 framer), paced only by the keyboard itself,
with zero involvement from any CPU/softcore or the memory system.

### 1.3 Approaches already ruled out

- **Tune the governor harder** (rv_slot, CDC hold window, moving iosys to clk_core 54 MHz):
  exhausted. Cannot simultaneously give the Atari full SDRAM priority and keep a softcore-driven
  keyboard alive.
- **Run firmware from BSRAM** so fetches leave the SDRAM bus: blocked by Gowin synthesis. Gowin
  constant-folds the `flash_loaded` reset gate and prunes the BSRAM; `$readmemh` init causes a
  DFF explosion. The only escape is hand-instantiated `SDPB` primitives with baked-in INIT —
  high effort, previously deferred. See memory note `project-iosys-bsram-investigation`.

### 1.4 The fix (this document)

**Move Stage 1 into hardware.** Decode the CH9350/UART byte stream in a small RTL module that
taps the same UART RX wire, holds the current key state, and drives `usb_to_atari800` directly —
with **no PicoRV32 and no SDRAM in the path.**

Consequences:
- Keyboard liveness becomes **completely independent of the SDRAM arbiter.** We can then set the
  governor to give the Atari whatever priority correct boot/timing requires, without losing the
  keyboard. This is what breaks the either/or.
- The firmware is **not removed.** It still owns SD access, ROM loading, the OSD menu, SIO disk
  emulation, and options. Only its keyboard-polling responsibility is superseded.
- OSD navigation actually improves: the OSD reads the same key wires (via `rv_joy1`), which are
  now alive even while the softcore is busy with SD/SIO.
- Reuses the **existing, known-working Pi-Pico CH9350-over-UART input.** No new pins, no new
  cable, no swap to PS/2.

---

## 2. Verified facts the design relies on

| Fact | Source | Note |
|---|---|---|
| UART RX = pin 51 = `usb_dp`, used only as a plain input by `simpleuart` | `tang_top.sv:549`, `iosys_picorv32.v:288` | The "pin 53" comment at `tang_top.sv:548` is stale. Pin is shared with USB-HID D+ but in UART mode USB host is held in reset. |
| UART is 115200 8N1; divider 234 on the 27 MHz `sys_clk` | `firmware.c:930` (`reg_uart_clkdiv = 234`) | `27_000_000 / 115200 ≈ 234`. |
| `simpleuart` RX samples with a half-bit-centered FSM (start→center, then 8 data LSB-first) | `simpleuart.v:66–105` | The new module mirrors this exactly so timing matches the proven receiver. |
| CH9350 frame format | `firmware.c:1147–1207` (`uart_keyboard_poll`) | `0x57 0xAB <cmd> <len> <data[len]>` where `data[len-1]` is an 8-bit additive checksum over `data[0..len-2]`. |
| Keyboard report extraction | `firmware.c:1192–1200` | When `(cmd==0x88 \|\| cmd==0x83)` and `data[0]==0x10`: `modifier=data[1]`, `key1=data[3]`, `key2=data[4]`, `key3=data[5]`, `key4=data[6]` (data[2] reserved). |
| Safety timeout clears keys after 1 s of no packet | `firmware.c:1210–1215` | Replicated in hardware so a dropped "key-up" frame cannot stick a key down forever. |
| Matrix stage `usb_to_atari800` is purely combinational | `usb_to_atari800.sv` (clk/reset_n present but unused) | So CDC into the core domain is just a 2-FF sync of the slow held bytes. |
| Held key bytes change at human/USB-poll rate (≤1 kHz), far slower than any clock | — | Multi-bit CDC of the 5 bytes is safe with simple 2-FF synchronizers; no handshake needed. |
| `combined_key*` merges virtual-kbd and USB-HID keys; OSD nav + `rv_joy1` derive from `combined_key*` | `tang_top.sv:441–480` | Insertion point: feed the new hardware bytes into this merge. |

---

## 3. Design

### 3.1 Block diagram (target)

```
pin 51 (usb_dp / uart_rx)
   ├─────────────────────────────► simpleuart (inside iosys)      [UNCHANGED: firmware TX/console still works]
   │
   └──► uart_kbd_ch9350.sv  (NEW, runs on sys_clk 27 MHz)
            UART RX FSM  ──► byte stream
            CH9350 frame FSM (0x57 0xAB cmd len data… checksum)
            report extract + 1 s watchdog
            held regs:  hk_mod, hk_key1..hk_key4   (sys_clk domain)
                         │
                         ▼  2-FF CDC sync to clk_core
            hk_mod_s, hk_key1_s..hk_key4_s         (clk_core domain)
                         │
                         ▼
   merge in tang_top:  hw_kbd  →  combined_key*  →  usb_to_atari800.sv  →  core matrix
                                                  └► OSD nav / rv_joy1 (also benefits)
```

The UART RX wire simply fans out to two readers. Both are inputs; no contention.

### 3.2 New module — `src/uart_kbd_ch9350.sv`

Single-clock module on `sys_clk` (27 MHz) so it reuses the proven 115200 timing. CDC to
`clk_core` happens in `tang_top`, not inside this module (keeps the module clock-domain-pure).

```
module uart_kbd_ch9350 #(
    parameter CLK_HZ          = 27_000_000,
    parameter BAUD            = 115200,
    parameter TIMEOUT_MS      = 1000          // clear keys if no packet for this long
)(
    input  wire       clk,                    // sys_clk 27 MHz
    input  wire       reset_n,
    input  wire       uart_rx,                // shared pin 51, raw async input

    output reg  [7:0] kbd_mod,                // held: modifier byte (HID modifier bitmap)
    output reg  [7:0] kbd_key1,
    output reg  [7:0] kbd_key2,
    output reg  [7:0] kbd_key3,
    output reg  [7:0] kbd_key4
);
```

Internal stages:

1. **Synchronize** `uart_rx` with 2 FFs (async input → `clk`).
2. **UART RX FSM** — mirror `simpleuart.v:66–105`:
   - `localparam DIV = CLK_HZ/BAUD;`  (≈234)
   - idle until start bit (`rx==0`); wait half a bit (`2*cnt > DIV`) to land in the center;
     then shift in 8 data bits LSB-first at full-bit spacing; emit `rx_byte` + `rx_strobe`.
   - No parity, 1 stop bit (8N1), matching the firmware/Pico configuration.
3. **CH9350 frame FSM** — mirror `firmware.c:1156–1206` exactly:
   - States: IDLE → AB → CMD → LEN → DATA.
   - IDLE: wait for `0x57`. AB: expect `0xAB` (stay if another `0x57`, else back to IDLE).
     CMD: latch `cmd`. LEN: latch `len` (accept `1..16`, else IDLE). DATA: collect `len` bytes.
   - On final byte: additive checksum of `data[0..len-2]` must equal `data[len-1]`.
   - If valid AND `(cmd==0x88 || cmd==0x83)` AND `data[0]==0x10`: update held registers
     `kbd_mod=data[1]; kbd_key1=data[3]; kbd_key2=data[4]; kbd_key3=data[5]; kbd_key4=data[6]`,
     and reload the watchdog. (Same byte positions as firmware.)
4. **Watchdog** — a millisecond tick counter; if no valid keyboard report for `TIMEOUT_MS`,
   clear all five held registers to `0x00`. Prevents a lost release frame from sticking a key.

Notes:
- This module contains **no** `usb_host_enable` / mode bit. Mode selection (UART vs USB-HID)
  stays in firmware/`tang_top` exactly as today (Section 4.3).
- ~50–70 lines. No SDRAM, no memory interface, no dependence on PicoRV32 state.

### 3.3 CDC (in `tang_top.sv`)

The five held bytes change far slower than any clock edge, so a flat 2-FF synchronizer per bit
is sufficient (no Gray/handshake needed — bytes are quasi-static between updates):

```
// sys_clk domain outputs from uart_kbd_ch9350: hk_mod, hk_key1..hk_key4
// 2-FF sync into clk_core (the domain feeding usb_to_atari800 / core)
reg [7:0] hk_mod_m,  hk_mod_s;
reg [7:0] hk_k1_m,   hk_k1_s;   // ... k2,k3,k4 likewise
always_ff @(posedge clk_core) begin
    {hk_mod_s,  hk_mod_m}  <= {hk_mod_m,  hk_mod};
    {hk_k1_s,   hk_k1_m}   <= {hk_k1_m,   hk_key1};
    // k2,k3,k4 ...
end
```

(Acceptable transient: during a byte change the 5 bytes may cross asynchronously and the matrix
could see a 1-cycle intermediate combo. POKEY rescans every scanline and the OS debounces, so a
single-scanline glitch is invisible — the reference relies on the same scanline-rate rescan.)

Confirm which clock domain `usb_to_atari800`/the merge actually runs in before finalizing the
sync target (the instance ports clk but the logic is combinational; the consumers — core matrix —
are on `clk_core`). Sync to `clk_core`.

### 3.4 Merge point (in `tang_top.sv`, ~lines 434–445)

Today:
```
combined_key1 = (virt_kbd_key1 != 0) ? virt_kbd_key1 : effective_usb_key1;   // etc.
```

Plan: introduce the hardware keyboard as the primary source, keeping `virt_kbd_*` available as a
fallback / firmware-injection channel (the firmware still uses `reg_virt_kbd_0` to pulse OPTION on
"Boot to OS", `firmware.c:1075`, so we must not break that injection):

```
// Hardware-decoded keys take precedence; virt_kbd_* still usable for firmware key injection
// (e.g. holding OPTION during boot); USB-HID remains the lowest-priority fallback.
wire [7:0] hw_or_virt_key1 = (hk_k1_s != 0) ? hk_k1_s : virt_kbd_key1;
// ... k2,k3,k4, and mod = hk_mod_s | virt_kbd_mod
combined_key1 = (hw_or_virt_key1 != 0) ? hw_or_virt_key1 : effective_usb_key1;
```

Exact precedence (hardware-vs-virt-vs-USB, and how OPTION injection coexists) to be finalized in
the implementation step; the constraint is: **(a)** hardware keyboard drives the matrix without
the softcore, and **(b)** firmware OPTION-hold injection during boot still reaches the matrix.

### 3.5 Governor / timing — what changes after decoupling

Nothing in this module touches the arbiter. But **the point** of the change is that, once the
keyboard no longer needs the softcore to be SDRAM-serviced in real time, we are free to:

- give the Atari core stronger/exclusive SDRAM priority for correct boot and ANTIC DMA timing,
- and separately revisit the machine-clock accuracy issue (`cycle_length=32` @ 54 MHz →
  1.6875 MHz, ~6% slow vs NTSC 1.7897 MHz; the intended `cycle_length=30` hit a non-power-of-2
  synthesis index error).

Those governor/timing changes are a **separate stage** (see Section 6) and are *enabled* by this
one, not part of it.

---

## 4. What stays the same (explicit non-goals)

1. **Firmware is kept.** SD access, ROM load, OSD menu, SIO disk emulation, options file — all
   unchanged. This change does not remove `iosys_picorv32` or any firmware feature.
2. **`simpleuart` keeps reading the same RX pin.** Firmware console/printf and any future
   firmware UART use are unaffected (the wire just fans out to a second reader).
3. **Upstream `rtl/` is untouched.** The matrix contract (`KEYBOARD_SCAN`/`KEYBOARD_RESPONSE`)
   and POKEY scanner are the reference design already; we only change who produces the held-key
   state feeding `usb_to_atari800`.
4. **USB-HID path stays** as a lower-priority fallback, gated by `usb_host_enable` as today.

### 4.3 Mode selection

`option_keyboard_type` (UART vs USB) and `usb_host_enable` logic remain in firmware/`tang_top`.
The hardware decoder is always listening on the UART; if the user selects USB mode, the firmware
behavior is unchanged and the USB-HID keys win via the existing precedence. (We may later let the
hardware decoder be the unconditional UART source and simplify `uart_keyboard_poll`, but that is
optional cleanup, not required for the fix.)

---

## 5. Implementation steps (ordered, each independently testable)

1. **Add `src/uart_kbd_ch9350.sv`** (Section 3.2). Self-contained; compiles standalone.
2. **Register it in `build.tcl`** in the Stage-3 section (near the other `src/` SV modules).
3. **Instantiate in `tang_top.sv`**: feed `.uart_rx(usb_dp)`, `.clk(sys_clk)`,
   `.reset_n(hw_reset_n)`; expose `hk_mod, hk_key1..hk_key4`.
4. **Add the 2-FF CDC** to `clk_core` (Section 3.3).
5. **Rewire the merge** (Section 3.4) so the hardware keys feed `combined_key*` while preserving
   firmware OPTION injection via `virt_kbd_*`.
6. **Build** (`QT_QPA_PLATFORM=offscreen gw_sh.sh build.tcl`); fix any synthesis issues.
7. **Bench test keyboard alone** (Atari may still be timing-imperfect): confirm keystrokes from
   the Pi-Pico reach the emulator with the governor set to Atari-priority — i.e. demonstrate the
   either/or is broken.
8. **Then** proceed to the separate governor/timing stage (Section 6).

Firmware rebuild is **not required** for this change (no firmware edits). Note for future LLM
sessions: firmware is built with `make` in `firmware/` and flashed separately with
`./flash_it.sh` to SPI flash `0x500000`; the `.bin/.hex` are build artifacts — never hand-edit or
rely on a stale prebuilt binary. The `.c` sources ARE git-tracked.

---

## 6. Follow-on stages (out of scope here, enabled by this change)

- **Governor rebalance:** give the Atari core SDRAM priority sufficient for clean boot + ANTIC
  DMA, now that keyboard liveness no longer depends on softcore SDRAM slots.
- **Machine-clock accuracy:** resolve `cycle_length` so the NTSC machine runs ~1.7897 MHz without
  the non-power-of-2 synthesis index error (currently 32 → 1.6875 MHz, ~6% slow).
- **Optional firmware cleanup:** retire `uart_keyboard_poll()` once the hardware path is proven,
  keeping only firmware OPTION/key injection if still wanted.

---

## 7. Risk / rollback

- Branch `baseline-test` is the known-good fallback; do not commit experimental work there.
- The change is additive (new module + a fan-out + a merge edit). If the hardware path
  misbehaves, reverting the merge edit restores the firmware-driven path exactly.
- Main residual risk is CH9350 frame-FSM fidelity — mitigated by mirroring `firmware.c` byte-for-
  byte (same cmd/offset/checksum rules), and by the 1 s watchdog preventing stuck keys.
