# Spec: PC-symbolic keyboard layout option ("Keyboard: ATARI / PC")

Status: **IMPLEMENTED in v3.1 (2026-09-19)** as specified, plus a 2-FF synchroniser on the key slots ahead of the press-time latch. Originally written 2026-08-16 in response to the feature
request for mapping the keyboard by what's printed on a real PC keyboard instead of by
Atari key position.

## 1. Goal

Add a runtime OSD option `Keyboard: ATARI / PC` (default **ATARI**, persisted in
`atari.ini`):

- **ATARI (default, unchanged):** the current positional mapping — the PC keyboard *is*
  an Atari keyboard by position/legend. `usb_to_atari800.sv` behavior today, bit-exact.
- **PC (new):** symbolic mapping — pressing the key combination that produces a symbol
  on a US PC keyboard produces the same symbol on the Atari. `Shift+2` types `@`,
  `Shift+'` types `"`, `[` types `[`, etc. The translator remaps both the matrix key
  *and* the shift state seen by the core.

### Non-goals

- User-editable mapping tables / mapping files on SD (tier 2 — out of scope).
- Non-US host layouts (ISO/AZERTY/etc.). The PC mode is US-ANSI symbolic.
- Any change to hotkeys (F9/F11/F12), console keys (F6/F7/F8 = Start/Select/Option),
  F1–F5, Break, arrows, OSD navigation, or the joystick path. These are identical in
  both modes.

## 2. Why this is more than a second lookup table

Letters and digits already match by label. The differences are the symbols, and most of
them **differ in shift state** between the two keyboards (Atari: `"`=Sh+2, `@`=Sh+8,
`^`=Sh+*, `&`=Sh+6, `'`=Sh+7, `:`=Sh+;, `[`=Sh+,, `]`=Sh+., `\`=Sh++, `|`=Sh+=, and
dedicated `+ * < >` keys). So PC mode must translate:

```
(PC HID key, physical Shift)  →  (Atari matrix code, required Atari Shift)
```

where the required shift often contradicts the physical shift (e.g. PC `Shift+8` = `*`
→ Atari `*` key with shift **suppressed**; PC `'` unshifted → Atari `7` with shift
**forced**).

The matrix protocol supports this: `keyboard_response[1]` answers the shift row
(`keyboard_scan[5:4]==2'b10`) from module-computed state, and POKEY samples shift
consistently with the key during its scan/debounce window. We answer the shift row with
an **effective shift** derived from the held keys' requirements instead of the raw
modifier.

## 3. RTL changes

### 3.1 `src/usb_to_atari800.sv` — the bulk of the work

New input: `pc_layout` (1 bit, already synchronized — see 3.3).

**a) Extend the lookup.** Replace `hid2atari`'s 7-bit result with a record:

```
{valid, code[5:0], smode[1:0]}   // smode: PASS / FORCE0 / FORCE1
```

- `hid2atari_pos(hid)` — today's table verbatim, all entries `smode=PASS`.
- `hid2atari_pc(hid, phys_shift)` — the PC table (section 4); indexed by the physical
  shift because the same PC key maps to different Atari keys shifted vs. unshifted.
- Mode mux selects which function feeds each key slot.

**b) Per-slot press-time latch (required, see section 5).** The mapping of a held key
must NOT change while it is held — otherwise releasing Shift before the key (normal
typing dynamics: `Shift+2`=`@`, shift up first) morphs the held key's matrix code
(`8`→`2`), which POKEY registers as a *new* keypress → stray character. Therefore:

- Add a small clocked process (the module already has `clk`/`reset_n` ports, currently
  unused): for each of the 4 key slots, when the HID code transitions 0→nonzero, latch
  that slot's lookup result (`{valid, code, smode}`); hold it until the slot returns
  to 0 or changes HID code. `atari_keyboard` and the shift logic use the latched
  values. Keys are slow; any of the available clocks is fine — use the one the module
  already receives.
- Known (accepted) quirk this creates: pressing the key *first* and Shift *after*
  resolves at keydown — same behavior as a PC OS, and POKEY has latched the code
  anyway. Document, don't fight.

**c) Effective shift.**

```
force1 = any latched valid slot with smode==FORCE1
force0 = any latched valid slot with smode==FORCE0
eff_shift = force1 ? 1'b1 : force0 ? 1'b0 : shift_pressed;
```

`keyboard_response[1]`'s shift term uses `eff_shift`. With no key held, `eff_shift`
falls back to the physical shift, so shift-only presses (games poll SKSTAT) still work.
Conflict rule when two held keys disagree: FORCE1 wins — same quirk class as rollover
on the real keyboard; single-key typing (the actual use case) is unambiguous.

In ATARI mode every entry is PASS, so `eff_shift == shift_pressed` and behavior is
provably identical to today (regression argument: mode bit = 0 reduces to the current
equations).

**d) Ctrl is untouched.** `control_pressed` (physical Ctrl + implied-Ctrl arrows) stays
as-is in both modes. Ctrl+key graphics combinations remain positional — that's correct:
CHR$ graphics have no PC-legend equivalent.

**e) Unchanged specials:** Break (`` ` ``/NumLock), console F6–F8, F1–F5, Insert→Help,
arrows (incl. implied Ctrl), Caps, Right-Alt→Inverse. Identical in both modes.

### 3.2 `src/iosys_picorv32.v` — one bit

`video_opts_reg` bit **[3]** = `pc_layout` (bits [1:0] scanlines, [2] stereo already
used). New output `kbd_pc_layout_out = video_opts_reg[3];`. Register 0x0200_00b4,
existing write path — no new address decode.

### 3.3 `src/tang_top.sv` — wiring + CDC

2-FF synchronize `kbd_pc_layout_out` (sys_clk domain) into the clock that
`usb_to_atari800` runs its latch process on, following the existing
`reg_ram_select`→`ram_select_core` pattern. Feed `.pc_layout()` on the `keyboard`
instance. Note the tang_top forward-reference gotcha (EX3638): declare the wires
explicitly.

## 4. The PC-mode mapping table

Atari matrix codes below are the existing `hid2atari` numbering (POKEY scan codes).
Reference Atari shift pairs: number row `1! 2" 3# 4$ 5% 6& 7' 8@ 9( 0)`, then
`-`/`_`(14), `=`/`|`(15), `+`/`\`(6), `*`/`^`(7), `;`/`:`(2), `,`/`[`(32), `.`/`]`(34),
`/`/`?`(38), dedicated `<`(54) and `>`(55).

**Pass-through group** (same Atari key both modes, `smode=PASS`): all letters, digits
`1 3 4 5 9 0` (their shifted symbols `! # $ % ( )` already agree), `; , . /` (shifted
`: < > ?` handled below where they differ), Space, Enter, Esc, Tab, Backspace, Caps,
and every key listed in 3.1e.

**Delta entries** (the actual PC table; ⊘ = FORCE0, ⊕ = FORCE1):

| PC keystroke | Symbol | Atari keystroke | code | smode |
|---|---|---|---|---|
| `2` | `2` | `2` | 30 | PASS |
| `Sh+2` | `@` | `Sh+8` | 53 | ⊕ |
| `6` | `6` | `6` | 27 | PASS |
| `Sh+6` | `^` | `Sh+*` | 7 | ⊕ |
| `7` | `7` | `7` | 51 | PASS |
| `Sh+7` | `&` | `Sh+6` | 27 | ⊕ |
| `8` | `8` | `8` | 53 | PASS |
| `Sh+8` | `*` | `*` key | 7 | ⊘ |
| `-` | `-` | `-` key | 14 | ⊘ |
| `Sh+-` | `_` | `Sh+-` | 14 | ⊕ |
| `=` | `=` | `=` key | 15 | ⊘ |
| `Sh+=` | `+` | `+` key | 6 | ⊘ |
| `[` | `[` | `Sh+,` | 32 | ⊕ |
| `]` | `]` | `Sh+.` | 34 | ⊕ |
| `\` | `\` | `Sh++` | 6 | ⊕ |
| `Sh+\` | `\|` | `Sh+=` | 15 | ⊕ |
| `'` | `'` | `Sh+7` | 51 | ⊕ |
| `Sh+'` | `"` | `Sh+2` | 30 | ⊕ |
| `Sh+,` | `<` | `<` key | 54 | ⊘ |
| `Sh+.` | `>` | `>` key | 55 | ⊘ |
| `Sh+[` `{` / `Sh+]` `}` / `` ` `` `~` | — | *unmapped* (no ATASCII equivalent) | 7F | — |

(`Sh+;`=`:` and `Sh+/`=`?` agree between layouts → pass-through.)

Consequences worth stating in the README when this ships:

- In PC mode the `[ ] \ '` **cursor-key aliases disappear** (they type their symbols);
  the dedicated arrow keys still move the cursor — that's the whole point of the mode.
- `` ` `` stays **Break** in both modes (backtick/tilde/braces don't exist in ATASCII).
- The reference for "what should this key type" is a US-ANSI keyboard; other physical
  layouts get whatever US-symbolic gives them (non-goal).

**Optional extras (Phase 2, cheap once smode exists but NOT in the base scope):** PC
Home→`Sh+<` (Clear), PC Insert→`Sh+>` (insert char), PC Delete→`Ctrl+Bksp` (delete
char). The last one needs a `cmode` (ctrl-override) field symmetric to `smode`; decide
after the base mode is proven.

## 5. Firmware changes (all small, established patterns)

1. `option_kbd_layout` (0=ATARI, 1=PC), default 0.
2. `apply_video_options()`: `| ((option_kbd_layout & 1) << 3)` into `reg_video_opts`.
   Applies live — no cold boot.
3. Options submenu: new item `Keyboard: ATARI / PC` (Left/Right or Enter toggles, like
   Stereo). Bump `joy_choice(12, 8, ...)` → 9 items and re-check the submenu fits the
   OSD window.
4. `atari.ini`: load/save key `kbdlayout=` (0/1), alongside `stereo=`/`ram=`.
5. **PC-Link TYPE/paste consistency (required, not optional):** the bridge injects HID
   codes via `reg_virt_kbd_*` which merge *before* `usb_to_atari800` — so in PC mode
   the remap applies to injected keys too, and the current Atari-positional `ascii2hid`
   would garble every symbol. Fix: add a US-PC `ascii2hid_pc[95]` table (it's the
   *simpler* standard US encoding) and have the injection path select by
   `option_kbd_layout`. The OPTION-hold boot injection (F8, 0x41) and all
   hotkey/console codes are layout-invariant — untouched.

Firmware growth: one 95-byte table + a menu line + an ini key — trivial against the
64 KB BSRAM; no BRAM_DEPTH interaction.

## 6. Cost / risk assessment

- **Netlist footprint:** ~100-entry second case function + per-slot latches
  (4 × ~9 bits) + eff_shift mux — a few hundred LUTs of slow logic, no new clocks, no
  BSRAM, nowhere near the video path. Same risk class as the v2.2 stereo/RAM options.
- **HDMI canary:** any netlist change can perturb placement — mandatory
  build-verification per CLAUDE.md (grep errors, TNS, `video_data_*` SETUP slack
  ≥ ~0.5 ns) before flashing. If the canary degrades, iterate `-place_option` per
  protocol; the feature itself has no intrinsic reason to squeeze clk_pix.
- **Behavioral risk in ATARI mode: none by construction** — mode 0 selects the original
  table with PASS everywhere, reducing to today's equations. The only shared new logic
  is the press-time latch; it must be shown to be transparent (same one-hot bits, one
  clock later — POKEY's scan/debounce makes a 1-cycle latch delay invisible).
- **Known quirks to document (not bugs):** two simultaneously-held symbol keys needing
  opposite shift states → FORCE1 wins (single-key typing unambiguous; every emulator
  with a symbolic mode shares this); symbol resolved at keydown (shift pressed *after*
  a held key doesn't re-resolve it).
- **Interaction check:** OSD navigation reads `combined_key*` HID codes upstream of
  this module — unaffected. Joystick-mode arrow suppression and overlay masking happen
  upstream — unaffected.

## 7. Verification plan

The PC-Link bridge makes most of this **remotely self-verifiable**: `atari.py kbd`
(or `type` once `ascii2hid_pc` is in) + `atari.py screen` readback.

1. **Regression (ATARI mode, before anything else):** flash, leave mode at default,
   type the full symbol sweep in BASIC, screen-dump, diff against the same sweep on the
   previous release build. Must be identical. Also: OSD nav, F9/F11/F12, console keys,
   a game that reads Shift/Ctrl.
2. **PC mode symbol sweep:** toggle the option, type every printable ASCII 0x20–0x7E
   at the BASIC prompt (real keyboard for the physical-shift path; scripted `kbd`
   session for repeatability), screen-dump, compare against expected ATASCII. The delta
   table in section 4 is the oracle.
3. **Shift-dynamics torture:** `@` with shift released before/after the digit; rapid
   `"hello"` (shift held across the quote and letters); shift-only tap in a game.
4. **TYPE/paste in both modes:** paste a symbol-heavy BASIC program via the bridge in
   each mode; RUN it.
5. **Persistence:** set PC mode, Save changes, power-cycle, confirm `kbdlayout=1`
   survives and the mode is active at boot.
6. **Build verification protocol** (errors / TNS / canary) before every flash, as
   always. Respect the hold-builds-during-HW-test rule; quote payload md5.

## 8. Estimate

RTL + firmware ≈ one sitting each; the long pole is the two hardware sweep passes
(regression + PC mode). No dependencies on other open work; does not touch SIO, SDRAM,
video, or boot paths.
