# SIO Disk Emulation — Investigation Log & Current Theory

**Last updated:** 2026-06-05
**Status:** SIO disk read still fails. Root cause **narrowed to the handler's TRANSMIT
serializer** (drive→Atari path): the handler puts `0xFF` on the response line instead of
the bytes the firmware writes (e.g. the ACK `0x41`). RX (Atari→handler) is **proven working**.
Next step proposed: replace the 256-deep TX FIFO + p2s with a minimal byte serializer.

This supersedes the original pre-debug analysis. The signal path and FIFO references below
are current.

---

## TL;DR of where we are

```
Atari (POKEY) --command frame--> handler RX   : WORKS  (handler decodes 31 53 cleanly, C:53)
Atari (POKEY) <----ACK/data----- handler TX   : BROKEN (handler transmits 0xFF, not 0x41)
```

- The whole problem is the **drive→Atari (TX / response) path** inside `sio_handler.vhdl`.
- Everything else is verified good: command framing, RX decode, baud, firmware register
  writes, the Atari's own POKEY transmit.

---

## Signal path (current wiring)

```
Atari core (clk_core 54MHz)                  sio_handler (sys_clk 27MHz)        PicoRV32 (sys_clk)
  SIO_TXD  (computer->drive) ──2FF sync──► SIO_DATA_OUT ─► s2p ─► RX FIFO ─► reg_sio_rx (0x88)
  SIO_COMMAND (low in cmd)   ──2FF sync──► SIO_COMMAND
  ENABLE_179_EARLY ─toggle-sync(54→27)──► POKEY_ENABLE  (RX + TX baud counters tick on this)
  SIO_RXD  (drive->computer) ◄─────────── SIO_DATA_IN ◄─ p2s ◄─ TX FIFO ◄─ reg_sio_tx (0x80)
```

- Handler instance: `tang_top.sv:923` (`sio_handler sio_inst`). CPU_DATA_IN←sio_reg_wdata,
  WR_EN←sio_reg_wr, EN←sio_reg_en, ADDR←sio_reg_addr, DATA_OUT→sio_reg_rdata.
- iosys register glue: `iosys_picorv32.v:214-218`. `sio_reg_sel` for 0x02000080..9F,
  `sio_reg_addr = mem_addr[6:2]`, `sio_reg_wdata = mem_wdata[7:0]`, one-cycle `sio_reg_wr`.
- Register map (handler ADDR = `mem_addr[6:2]`): 0x80 addr0 = TX FIFO, 0x84 addr1 = TX stat,
  0x88 addr2 = RX data, 0x8c addr3 = RX stat, 0x90 addr4 = divisor (r/w),
  0x98 addr6 = RX diag, 0x9c addr7 = TX diag (now repurposed, see below).
- `SIO_DATA_IN <= p2s_transmit_reg` (`sio_handler.vhdl:555`), idles `'1'` (correct mark level).
- TX/RX FIFOs are `src/fifo_transmit.vhd` / `src/fifo_receive.vhd` (Gowin behavioral, FWFT
  `q <= ram(rd_ptr)`), **not** the Altera `rtl/common/sioemu/*` versions. build.tcl:66-67.

---

## Detour first solved: the machine ran 6× then ~1× too slow

Before SIO could be debugged, the machine speed was wrong:
- `THROTTLE_COUNT_6502` was `6'd31` → CPU ran **6×** too fast (stopwatch: 3.84 s vs real 23.16 s).
  Fixed to `6'd0` (tang_top.sv ~944). Now ~24.7 s ≈ real → correct 1× speed.
- Residual: `clk_core` is 54 MHz / `cycle_length=32` → `enable_179 = 1.6875 MHz` vs true NTSC
  1.7898 MHz, so the machine (and the SIO baud) runs ~5.7% slow. **This is fine** — the drive
  auto-bauds and both sides share `enable_179`, so it self-tracks. Measured bit period on the
  wire = **1504 sys_clk cycles ≈ 94 `enable_179` ticks**; handler divisor = 93. ~1% skew,
  within tolerance.
- Also merged to `main`: removed the menu-overlay CPU HALT, ROM-load retry loop, OSD fixes.

NOTE: `4F 40 00 00 8F` seen at boot is the **standard XL cold-start peripheral poll**, not a
disk command and not corruption (checksum `4F+40 = 8F` is self-consistent). Normal behaviour.

---

## What has been PROVEN (with the in-FPGA diagnostics built for this)

Diagnostics added (all in `sys_clk`, tapping real signals, independent of the handler's own
registers). iosys regs 0x68 (capture word select 0..4) / 0x6c (read), firmware OSD rows 21-24:

1. **POKEY transmits.** A start-bit-triggered capture counter (`Cap:N`) incremented (84, 168…)
   even with no disk → the Atari is really putting command frames on `SIO_TXD`.
2. **The command bytes are clean and the handler RX decodes them.** Forcing a known STATUS via
   a 6502 stub (see below) gave **`C:53`** in the firmware — device `0x31`, cmd `0x53`, valid
   checksum, i.e. the handler received the command perfectly. **RX is not the bug.**
3. **Baud is correct.** A bit-period meter measured `bit lo = 1504` cycles ≈ 1 bit at ~18.1 kBaud.
4. **The Atari sends a real `$31` STATUS when asked**, and gets **error 139 (`$8B` DNACK)** —
   *not* a timeout (138). So the Atari sent the command, a response came back, but the byte read
   where the ACK (`0x41`) belongs was **not `0x41`**.
5. **The response line carries `0xFF`.** A response-line meter + async byte decoder on
   `sio_rx_data_in` (handler→Atari) reads the first 4 response bytes as **`Resp: FF FF FF FF`**,
   with `bit lo:1504 hi:13536` (13536 = 9 bit-times = the all-ones `0xFF` signature). So the
   handler transmits `0xFF`, the Atari reads `0xFF ≠ 0x41` → 139. **This is the bug.**
6. **Firmware writes the right value and writes do reach the handler.** `sio_tx_byte(0x41)`
   writes `0x41`. The divisor register write/read-back test returned **`DIV rd:55`** (wrote 0x55,
   read 0x55) → the firmware→handler register-WRITE path works. (Baud being right is NOT proof of
   this on its own, because `divisor_reg` resets to `0x5D`=93 by default.)
7. **OS ROM is intact.** `PEEK(58457..)` = `76 51 201` = `JMP $C933` (SIOV is a real JMP), NMI
   vector `$C018`. So the SIO routine code loaded correctly; the `0xFF` is not blank ROM.

### The forced-STATUS test harness (no disk needed)
Firmware installs a 6502 stub at `$0600` whenever the OSD menu draws
(`install_sio_test_stub()`, firmware.c). It fills the DCB for a D1: STATUS and calls SIOV, so
the test is just **`X=USR(1536)`** in BASIC. STATUS is answered by the handler unconditionally
(no ATR mount required), so it isolates the command→ACK handshake from the disk/SD/ATR path.

---

## The contradiction at the FIFO probe

To see what the FIFO actually stores, addr7 (TX diag, `reg_sio_txdiag` 0x9c) was repurposed to
return `{fifo_tx_count[15:8], fifo_tx_data[7:0]}`. The firmware writes `0x41` to the TX FIFO and
immediately reads it back. Result:

```
DIV rd:55   FIFO d:55 c:00
```

- `c:00` → FIFO reports **empty** right after a write (the `0x41` write didn't increment count).
- `d:55` → FIFO data output is **`0x55`** — the value written to the *divisor* register two
  writes earlier, which should never reach the TX FIFO RAM (different address, addr4 vs addr0).

This is internally inconsistent with the (combinational, verified-correct)
`complete_address_decoder` and with the RX FIFO working using identical logic. Reads are NOT
stale (RX command decode would have failed otherwise). So the TX FIFO write/storage/count is
genuinely misbehaving on this Gowin port even though the VHDL reads correctly by inspection.

---

## Current theory (ranked)

### 🔴 T-A — Gowin synthesis defect in the TX FIFO (most likely)
The 256×8 behavioral FIFO (`src/fifo_transmit.vhd`: async `q <= ram(rd_ptr)` + a count/empty
process that handles simultaneous write(firmware)/read(p2s)) mis-synthesizes on Gowin **for the
TX usage pattern** (hardware-paced read by the p2s, possibly simultaneous with firmware writes),
even though the *identical* RX FIFO works (firmware-paced read, reads/writes far apart in time).
Symptoms that fit: write doesn't stick (`c:00`), stale/leaked data in the RAM (`d:55`), and the
p2s draining an apparently-non-empty-but-actually-garbage FIFO → continuous `0xFF`
(the response meter saw ~29 back-to-back `0xFF` bytes filling the 16 ms window = the p2s
shifting its fill-with-`1` pattern, i.e. shifting **without a valid load**).

### 🟠 T-B — p2s load/timing relative to `transmit_enable` / `pokey_enable` CDC
The p2s advances one state per `transmit_enable` (every `divisor`=93 `pokey_enable` ticks).
`pokey_enable` is the 54→27 MHz toggle-synced `enable_179_early`. If the p2s ever enters
`SHIFT_0` without the WAIT-state load taking effect, it outputs the shift-register fill (`1`s)
= `0xFF`. RX uses the same `pokey_enable` and works, but RX *samples* (tolerant) whereas TX
*generates* bit widths (sensitive). Less likely than T-A given the FIFO probe, but coupled to it.

### ⚪ Ruled out
- RX / command decode (proven: `C:53`).
- Baud / divisor (measured 1504; divisor write works).
- Register-write path (divisor `rd:55`).
- OS ROM load / SIO routine code (PEEK shows valid JMP/vectors).
- Warm-start / not-transmitting / ROM-loader theories (all disproven earlier).
- Idle level of `SIO_DATA_IN` (idles `'1'` correctly).
- `0xFF` = blank ROM or open-bus read by the CPU (CPU writes the right value; it's the
  handler that corrupts it).

---

## Proposed fix (next step)

**Rip out the 256-deep TX FIFO + the suspect count/empty logic and replace the transmit path
with a minimal, synthesis-robust byte serializer** in `sio_handler.vhdl`:
- A single 8-bit holding register + "byte pending" flag, loaded on an addr0 write.
- Feed the existing p2s shift FSM from that register (start bit, 8 LSB-first data bits, stop).
- `fifo_tx_empty`/`full` become trivial 1-byte flags; the firmware already writes byte-by-byte
  with `sio_wait_tx_empty()`, and sector reads (128 B) self-pace through it (~7 ms, fine).
This removes the entire class of defect (deep async-read RAM, simultaneous r/w count) instead of
hunting one elusive line. Validate by re-running `X=USR(1536)` and reading the `Resp:` decoder —
expect it to flip from `FF FF FF FF` to `41 43 10 FF …`.

---

## Diagnostic infrastructure currently in the tree (so it can be reused/removed)

- `tang_top.sv`: SIO response-line meter + async byte decoder on `sio_rx_data_in`
  (`RESP_WINDOW`, `bd_*` regs), packed into `sio_cap_buf`/`sio_cap_meta`, wired to iosys as
  `{sio_cap_meta, sio_cap_buf}` (160-bit). Earlier command-side meter was replaced by this.
- `iosys_picorv32.v`: regs 0x68 (`sio_cap_idx`, word select 0..4) / 0x6c (`sio_cap_data`).
- `sio_handler.vhdl`: addr7 TX diag repurposed to `{fifo_tx_count, fifo_tx_data}`.
- `firmware.c`: OSD rows 21-24 (RespN/ACKlat, bit lo/hi, `Resp:` bytes, `DIV rd` + `FIFO d/c`),
  `install_sio_test_stub()`, `sio_txdiag_sample()` exists but is **not called** (so the old
  "TX PE/LineHi/Femp/St" row 17 was always uninitialised zeros — ignore it).
- Test harness: `X=USR(1536)` after opening the OSD once (stub installed on menu draw).

## File index
- Handler: `rtl/common/sioemu/sio_handler.vhdl` (p2s FSM ~369-417; transmit_enable 292-304;
  FIFO write decode 214-228; addr7 diag ~282-286; `SIO_DATA_IN` 555).
- TX FIFO: `src/fifo_transmit.vhd` (FWFT behavioral, the suspect).
- CDC + meter + handler instance: `src/tang_top.sv` (`POKEY_ENABLE` sync ~793-808, meter block,
  handler `sio_inst` ~923).
- Firmware SIO engine: `firmware/firmware.c` `sio_process_command()` (~796), `sio_tx_byte()`
  (~742), `sio_init()` (~683), OSD diag block (~1330+).
