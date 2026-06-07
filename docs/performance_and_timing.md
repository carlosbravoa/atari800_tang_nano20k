# Why the Atari runs ~6% slow (and the speed/reliability tradeoff)

**Last updated:** 2026-06-07
**TL;DR:** The Atari core is *not* the hard part. Our single root bottleneck is the **SDRAM
controller**: it takes ~20 core-clock steps per access, which forces a high core clock (54 MHz),
which makes the 6502's critical path marginal on the Gowin fabric → ~6% slow *and* occasional
graphical corruption. The same board runs SNES and Atari ST at full speed, so this is an
**optimization gap in our port, not a device limit.**

---

## The chain of constraints

1. The Atari 800XL has 64 KB RAM. The fastest home for it is on-chip **BRAM** (single-cycle).
   Our GW2AR-18 has only ~103 KB BRAM and the **PicoRV32 firmware already uses ~51–64 KB** of it,
   so the Atari RAM can't fit in BRAM → it lives in the **embedded SDRAM** behind a multi-cycle
   controller.
2. Our SDRAM access takes **~20 core-clock steps** (`gw2ar_sdram.sv`, closed-page: activate →
   tRCD → read/write → CAS → precharge → tRP every time). It must complete inside one Atari
   machine cycle. The rule that falls out: **`cycle_length` must exceed the step count (~20)**.
3. `cycle_length` must be a **power of two** (`shared_enable.vhdl` indexes `cycle_length/2^i`).
   Powers of two > 20 → only **32**. (16 is too few steps — that was the original video-garble bug.)
4. With `cycle_length = 32`:
   - **Exact NTSC speed** ⇒ `clk_core = 32 × 1.79 MHz = 57.4 MHz`.
   - The GW2AR-18 fabric tops out at **~53–54 MHz** for the 6502 logic (critical path = the
     opcode-decode `opcInfo` net, ~18.7 ns).
   - 57.4 > 54 → impossible. So we run **54 MHz (≈6% slow)** — and even that is right on the edge
     (path slack ≈ −0.2 ns), which is why some games show **occasional garbled frames / corrupt
     sprites** (ANTIC/GTIA latching bad data when the path just misses).

We're boxed in: `cycle_length=16` is too few steps for the SDRAM; `cycle_length=32` needs a clock
the fabric can't reach at full speed; nothing in between (power-of-two only).

**Key realisation:** the 6502 critical path is only a problem *because we run at 54 MHz*, which is
only forced *by the slow SDRAM*. At the exact-speed-with-fast-SDRAM target (`cycle_length=16` →
~28.6 MHz) the 6502 path (18.7 ns) fits a 35 ns period with huge margin. **So the single root
cause is the SDRAM controller's cycle count.** Fix that and everything else falls into place.

---

## Follow-up Q&A

### 1. SNES and Atari ST run at perfect speed on this *same* Tang Nano 20K — so it's not the device
Correct, and this is the decisive point. snestang (3.58 MHz 65816 + 128 KB WRAM + ROM) and
MiSTeryNano (8 MHz 68000 + RAM) both run full-speed on the GW2AR-18 — CPUs *more* demanding than
our 1.79 MHz 6502. The device is plenty capable.

The difference is that those are **native Gowin designs with efficient, purpose-written SDRAM
controllers** (open-page/burst, often a faster dedicated SDRAM clock). Ours is a **port of the
Atari800_MiSTer core** (designed for Altera Cyclone V) onto Gowin, paired with a **modest
from-scratch SDRAM controller**. Neither the core's critical paths nor the memory path were
re-optimised for Gowin. So our limit is *our implementation choices*, not the silicon — which
means exact speed is achievable here too, with the right engineering.

### 2. Moving RAM to BRAM would kill 128 KB (130XE) support
Right — and that's a strong reason **not** to go the BRAM route. 128 KB (130XE) does not fit in
~103 KB of BRAM even with no firmware. BRAM-for-RAM caps us at the 64 KB machines (800XL/65XE) and
forecloses the 130XE. The **SDRAM-controller speedup is the better fix** because it keeps the
128 KB machine *and* unlocks speed.

### 3. Is speeding up the SDRAM controller "overclocking"?
**No.** The SDRAM has fixed timing specs in nanoseconds (tRCD, tRC, tRP, CAS). Our ~20-step access
is *conservative/inefficient*, not at the SDRAM's limit. Two in-spec ways to go faster:
- **Run the controller more efficiently** (open-page: keep the active row open and skip
  activate+precharge on row hits — the Atari's accesses are highly sequential, so hit rate is
  high; burst reads for ANTIC DMA; pipeline precharge under the next activate). Same SDRAM, fewer
  wasted cycles.
- **Clock the SDRAM faster than the core** (e.g. 108–135 MHz on a dedicated clock). The embedded
  SDRAM is rated well above our 54 MHz — we're using a fraction of its capability. An access then
  completes in far less *core* time. (Costs a clock-domain crossing.)
Both stay within the vendor's spec. The SDRAM is fast; our controller is the slow part.

### 4. Why is it "real surgery"? What's involved + tradeoffs
The SDRAM controller is the most **correctness- and timing-critical** block in the design — a bug
there corrupts memory and the machine simply doesn't work (worse than today's occasional glitch).
We already spent weeks fighting this area (the `cycle_length` saga, the two-client arbiter, a
cache-tag aliasing bug). What a speedup touches:
- **Access policy rewrite** — closed-page → open-page (track the open row, handle row conflicts).
- **Refresh** — must be correctly interleaved with the new policy (miss it → data loss).
- **The arbiter** — two clients (ANTIC/CPU + firmware/iosys) must coordinate with the new timing.
- **A second clock domain** (if running SDRAM faster) → a CDC between SDRAM and core, more timing
  risk.
- **Cache interaction** — the existing read cache/tag logic must stay coherent.
- **Verification is hard** — failures are intermittent (exactly like the corruption we're chasing),
  so it's easy to "look fine" and still be subtly broken.
High value (exact speed + reliability + keeps 128 KB) but multi-day and high-risk. That's why it's
parked behind lower-risk work.

---

## The options on the table (today)

| Option | Speed | Reliability | Effort | Keeps 130XE? |
|---|---|---|---|---|
| **Stay 54 MHz** (today) | 6% slow | marginal (occasional corruption) | none | yes |
| **Back off to ~52.6 MHz** | ~8% slow | reliable (positive slack) | tiny (1 PLL param) | yes |
| **Optimise the 6502 critical path** | 6% slow (could push toward exact) | reliable | hours, uncertain (upstream core) | yes |
| **Faster SDRAM controller** (the real cure) | **exact** | reliable | days, high-risk | **yes** |
| **RAM in BRAM** | exact | reliable | days (shrink firmware first) | **no (kills 128 KB)** |

**Recommendation:** the cheap reliable fix is the ~52.6 MHz back-off. The *proper* cure is the
SDRAM-controller speedup — it's the one change that fixes speed, reliability, and keeps the 128 KB
machine. The BRAM route is appealing but disqualified by the 130XE target.

---

## Candidate replacement SDRAM controllers (evaluated 2026-06-07)

We don't have to write a faster controller from scratch — two existing Tang Nano 20K controllers
were evaluated as a base. Our controller is `src/gw2ar_sdram.sv` (single 32-bit port:
`req`+`read_en`/`write_en` → `req_complete`, `addr[24:0]`, `rdata`/`wdata[31:0]`, `wmask[3:0]`,
`refresh`; ~20-cycle closed-page access).

### ❌ snestang `sdram_snes` (`../snestang/src/nano20k/sdram_nano.v`, ~2-cycle) — not usable
Heavily SNES-specific: dedicated multi-ports (CPU bank0/1, BSRAM, ARAM bank2, VRAM1, VRAM2,
RISC-V), **16-bit**, multi-clock (SDRAM `fclk` ≈ 86 MHz = 4× the 21.5 MHz `mclk`, plus `clkref`).
Excellent latency but the architecture is nothing like ours — adopting it = a major rewrite with
all the SNES bank logic stripped out. Skip.

### ✅ nestang `sdram` (`../sdram-tang-nano-20k/src/sdram.v`, ~5-cycle) — strong base
Generic, built for our exact device (used in NESTang):
- Single port, parameterized **`DATA_WIDTH=32`**; 4 banks × 2048 rows × 256 cols × 32-bit =
  **8 MB — matches our SDRAM geometry exactly**.
- **~5-cycle** latency; runs up to **66.7 MHz** (chip supports up to ~166 MHz with tighter params).
- Signals: `rd`/`wr`/`refresh`, `addr[22:0]` (byte), `din[7:0]`, `dout32[31:0]`, `busy`, `data_ready`.

**Not a literal drop-in** (interface differs), but reusable behind a thin adapter:

| | ours (`gw2ar_sdram`) | nestang `sdram` |
|---|---|---|
| handshake | `req` + `read_en`/`write_en` → `req_complete` | `rd`/`wr` pulse → `busy` / `data_ready` |
| write | `wdata[31:0]` + `wmask[3:0]` | `din[7:0]` (byte) |
| address | `[24:0]` (top 2 ignored) | `[22:0]` (8 MB) |

Plan: keep the core + two-client arbiter untouched; write a **~50–100-line adapter wrapper** named
`gw2ar_sdram` that exposes our existing ports while driving nestang's `rd/wr/busy/data_ready` and
mapping the byte write (the 6502 writes one byte at a time anyway). The proven controller is reused
as-is — this is what de-risks the rewrite.

### Why this unlocks exact speed
At ~5 cycles, an access fits `cycle_length = 16` with huge margin. Then:
- `cycle_length = 16` + `clk_core ≈ 28.6 MHz` → **exact NTSC speed** (16 × 1.79 MHz).
- 28.6 MHz is far under the fabric Fmax → **comfortable timing, no corruption**.
- RAM stays in SDRAM → **keeps 128 KB / 130XE**.
- At 28.6 MHz a 5-cycle access fits on a **single clock** → likely no separate fast SDRAM clock /
  CDC needed (simpler than snestang's 4× scheme).

So: exact speed + reliable + 128 KB, by reusing working code.

**Remaining work / risks:** the adapter wrapper; the phase-shifted `clk_sdram` the controller wants
(clk + 180°, easy from the PLL); re-verifying refresh and the two-client arbiter against the new
timing; and the usual hard-to-catch intermittent-SDRAM verification. Multi-day, but grounded on a
proven controller rather than a blank page. **This is the recommended route for the eventual fix.**
