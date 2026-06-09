# Path B — decouple the SDRAM bus from the Atari core clock (CDC)

**Goal:** give the frame-buffer writer (and later reader) room on the SDRAM bus **without**
slowing or speeding the Atari core — by running the SDRAM controller + arbiter on a faster,
dedicated clock and crossing the Atari↔SDRAM interface between domains.

This is the only path left after the cl/clock wall (see "Why Path A is dead" below). It is also
the architecture that yields **exact NTSC speed for free** — so it collapses the old Stage 4
("exact-speed clock") into the same change.

---

## Why Path A is dead (measured, 2026-06-08)

1. **cl=16 has no bus room.** One Atari SDRAM access (~6–7 `clk_core` cycles incl. wrapper)
   nearly fills the 16-cycle machine-cycle window. A second (writer) access pushes the Atari
   past its budget → ANTIC/6502 corrupt on the first frames → **black from power-on** (confirmed
   on HW: OSD works, ROMs load, but the running core never paints a frame).
2. **cl=32 would give room, but the core can't be clocked fast enough.** cl=32 needs
   ~54 MHz `clk_core`; the Atari core's internal logic (`pokey_mixer`, `pokey` keyboard scanner,
   `mmu`, `cpu6502`, `gtia` — all in `rtl/`, which we must not modify) tops out at **Fmax ≈ 45 MHz**
   (build at 54 MHz: 85 setup violations, worst path `pokey_mixer_both → keyboard_scanner/irq_reg`,
   slack −3.67 ns).
3. **No intermediate `cycle_length` exists.** `shared_enable.vhdl:112` indexes
   `speed_shift_temp(cycle_length/(2**i)-1)`; for any non-power-of-2 (e.g. 24, 30) the top loop
   index goes to −1 → elaboration error. **Only cl ∈ {16, 32} are legal.**

⇒ The core's 45 MHz ceiling sits *between* cl=16's needs (27–29 MHz, fine but no room) and
cl=32's needs (54 MHz, unreachable). You **cannot** widen the bus window from the core side.
The SDRAM speed must be decoupled from the core speed.

---

## Core idea

Two phase-related clocks from the existing core PLL (`rpll_108m`, FOUT = 114.75 MHz on the exact
branch):

| Clock | Freq | Derivation | Drives |
|---|---|---|---|
| `clk_core` | **28.6875 MHz** | 114.75 ÷ 4 (CLKDIV) | Atari core (cl=16 → **1.7898 MHz, exact NTSC**) |
| `clk_mem` | **57.375 MHz** | 114.75 ÷ 2 | SDRAM controller + arbiter + FB writer drain |

`clk_mem = 2 × clk_core`, both divided from the same 114.75 MHz source ⇒ **edge-aligned 2:1
synchronous** (every `clk_core` edge coincides with every other `clk_mem` edge). This is the key
simplification: the domain crossing is **synchronous (related clocks)**, not async — no
metastability, just disciplined enable/handshake crossing with a known phase.

### Why this gives room
At `clk_mem` = 57.375 MHz a NESTang access is ~7 cycles ≈ **122 ns**. The Atari machine-cycle
window (cl=16 @ 28.6875 MHz) is **558 ns**. So per window:
- Atari access + CDC round-trip ≈ 2·(1/57)+7/57+2/(1/28.69) ≈ **~230 ns**
- one writer access ≈ **~122 ns**
- refresh headroom ≈ **~122 ns**
- **total ≈ 470 ns < 558 ns** ✓ (and the writer only needs ~0.8 access/window on average)

### Why this is also exact speed
`clk_core` stays at 28.6875 MHz / cl=16 = **1.7898 MHz = exact NTSC**. The core never has to run
faster — it runs at the speed it already closes timing at (28.69 ≪ 45 MHz Fmax). The faster clock
is *only* on the SDRAM side. So Path B delivers exact speed **and** writer bandwidth in one move;
there is no separate "Stage 4" anymore.

---

## What has to change

### 1. Clock generation
- Keep `rpll_108m` at **114.75 MHz** (revert the Path-A 216 MHz experiment).
- Derive `clk_core` = ÷4 (existing CLKDIV) and **add `clk_mem` = ÷2**.
- ⚠️ **HCLKIN-sharing risk:** two CLKDIV primitives may not share one HCLKIN net cleanly (the
  `wip/61mhz-sdram-cdc` branch hit this and used a PLL `CLKOUTD` instead). Resolution options, in
  order of preference:
  1. Two CLKDIVs (÷2, ÷4) on `clk_108m` if the tool allows the shared HCLKIN.
  2. `clk_mem` from `rpll_108m` `CLKOUTD` (SDIV=2 → 57.375) + `clk_core` from CLKDIV÷4. But
     `CLKOUTD` currently makes `clk_usb` (12 MHz, SDIV=18) — `clk_usb` would have to move (e.g. to
     a CLKDIV off `clk_mem`, 57.375÷5≈11.5 or a divider chain). Allocate PLL outputs carefully.
  3. Worst case, accept a 3rd PLL output / restructure. (Device has 2 rPLLs, both already used;
     work within `rpll_108m`'s four outputs + CLKDIVs.)
- Add `clk_mem` to the SDC with `set_clock_groups` relating it to `clk_core` (they are
  **synchronous** — do *not* mark them asynchronous to each other; let the tool analyse the 2:1
  crossing, or use `set_multicycle_path` where appropriate).

### 2. Move the SDRAM controller + arbiter to `clk_mem`
- `gw2ar_sdram` (+ `sdram_nestang`) clocked by `clk_mem`. Update `FREQ` to 57_375_000 (init
  delay). Re-check `T_RCD`/`T_RP` (=1 → 17.4 ns at 57 MHz; just above the embedded SDRAM's tRCD —
  bump to 2 for margin if HW or timing demands, it costs only 1 cycle/access and there is room).
- The 3-client arbiter FSM (already written: Atari > FBwriter > PicoRV32) moves to `clk_mem`.

### 3. CDC the three clients into the `clk_mem` arbiter
- **Atari (clk_core → clk_mem), NEW.** Today the Atari is same-domain with the arbiter; Path B
  makes it a crossed client. Cross:
  - `core_sdram_req` (1-cycle clk_core pulse → 2 clk_mem cycles wide, sample on clk_mem),
    `addr/read_en/write_en/wdata/wmask/refresh` (stable for the whole window — sample after req
    seen), and back: `req_complete` (clk_mem→clk_core) + **latched `rdata`** held until the core
    samples it (mirror the existing `rv_rdata_hold` trick so a later access can't clobber it).
  - Because it's 2:1 **synchronous**, prefer a clean enable-based handshake over async 2-FF where
    possible; keep a toggle-sync for the completion pulse (clk_mem pulse is half a clk_core cycle
    — too narrow to catch directly).
  - **Deadline:** the Atari must see `req_complete` within its 558 ns window. Budget above shows
    ~230 ns — safe, but this is the make-or-break path; verify in sim/HW.
- **PicoRV32 (sys_clk 27 → clk_mem), MODIFY.** Already CDC'd to `clk_core`; re-target the existing
  `rv_valid` 2-FF / `rv_ready` toggle-sync / `rv_rdata_hold` machinery to `clk_mem`. sys_clk and
  clk_mem are asynchronous → keep the true 2-FF/toggle synchronizers (this part stays async CDC).
- **FB writer.** Capture stays on `clk_core` (video `pixce/de/vs` are clk_core). Make its small
  FIFO a **2-clock FIFO**: write side `clk_core` (pixel packing), read/drain side `clk_mem`
  (arbiter). With 2:1 synchronous this is straightforward; `fbw_ack` is a clk_mem pop.

### 4. Keep the Atari core, video, HDMI, OSD untouched
- Core stays `clk_core` 28.6875 / cl=16. Video out (`video_*`) stays clk_core. Scaler/HDMI
  unchanged. OSD/keyboard unchanged. Only the SDRAM path is re-clocked + crossed.

---

## Implementation stages (each independently verifiable)

- **B0 — clocks.** Add `clk_mem` 57.375 MHz, resolve the HCLKIN/PLL-output allocation, constrain
  it, confirm it locks and both clocks come up (LED/UART proof). No functional change yet.
- **B1 — re-clock SDRAM + CDC the Atari only** (drop the writer + freeze PicoRV32 as today).
  Arbiter on `clk_mem`, Atari crossed in. **Pass = the Atari boots and runs exactly as the
  current exact build** (this validates the Atari↔SDRAM CDC in isolation — the riskiest piece).
- **B2 — re-target PicoRV32 CDC to clk_mem.** Pass = ROM load + OSD + keyboard all work again.
- **B3 — add the FB writer as 3rd client** (the 2-clock FIFO). Pass = Atari **still** boots/runs
  normally with the writer active (the thing that failed under Path A — now there is bus room).
- **B4 — reader** (frame_buffer_plan.md Stage 2): free-running 720p60 read side. First visible
  result.
- **B5 — double-buffer + swap** (Stage 3). Tearing gone.

Exact speed is already in place from B0 — no separate exact-speed stage.

---

## Risks / open questions (ranked)

1. **Atari↔SDRAM CDC deadline (B1)** — the core must get `req_complete`+`rdata` back inside its
   558 ns window across the crossing. Budget says ~230 ns; thin enough to demand sim + careful HW
   bring-up. This is the single make-or-break item.
2. **Clock-output allocation (B0)** — fitting `clk_core` + `clk_mem` + `clk_usb` out of one rPLL
   given the CLKDIV HCLKIN-sharing wrinkle. Known-hard; `wip/61mhz-sdram-cdc` shows the CLKOUTD
   workaround.
3. **SDRAM timing at 57 MHz** — `T_RCD/T_RP=1` ≈ 17.4 ns vs the embedded SDRAM's tRCD. Likely OK
   (NESTang default design point is ~54 MHz); bump to 2 cycles if marginal.
4. **Arbiter/controller timing closure at 57 MHz** — simple logic, not the core's POKEY path;
   expected to close, but unverified (the 45 MHz ceiling was a *core* path, not this).

## What this retires
Once B3 passes, the cl/clock wall is gone for good: the Atari runs exact at a clock it closes
easily, and the SDRAM has bandwidth for the writer + reader. The dual-build split (smooth vs
exact) is no longer forced by speed — exact comes for free.
