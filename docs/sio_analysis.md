# SIO Disk Emulation — Failure Analysis & Theories

**Date:** 2026-06-03
**State analyzed:** `main` working tree (uncommitted SIO WIP, same lineage as branch `sio-cdc-wip`).
**Status:** SIO disk read has never worked. The WIP changes also left the machine unstable
(frequently appears not to boot).

This doc records *why* it likely doesn't work and a bisection path to fix it methodically.
**Key fact established with the user:** clean command bytes (e.g. `31 53 00 00 84`) reaching
the firmware have **never been independently confirmed**. Everything below the command parser
is therefore unverified — prove RX before touching the response side.

## Signal path (for reference)

```
Atari core (clk_core 54MHz)                     sio_handler (sys_clk 27MHz)        PicoRV32 (sys_clk)
  SIO_TXD   (computer->drive data) ─┐
  SIO_COMMAND (low during cmd)      ├─ 2-FF sync ─► SIO_DATA_OUT / SIO_COMMAND ──► RX FIFO ──► reg_sio_rx (0x88)
  SIO_CLOCK                         ┘                                              (bit8 = command_active)
  ENABLE_179_EARLY ── toggle-sync ────────────► POKEY_ENABLE (RX baud counter ticks)
  SIO_RXD   (drive->computer data) ◄──────────── SIO_DATA_IN ◄── TX FIFO ◄── reg_sio_tx (0x80)
```
- Register decode: iosys_picorv32.v:203-207 (`mem_addr[6:2]` → handler ADDR). 0x80=tx, 0x84=tx stat,
  0x88=rx, 0x8c=rx stat, 0x90=divisor, 0x98=diag (ADDR 6).
- CDC + handler wiring: tang_top.sv:746-801.
- RX FIFO depth = 256 (fifo_receive.vhd:102) — no overflow risk for 5-byte command frames.
- Firmware image = 48,824 B of 64 KB BSRAM (firmware/Makefile:29) → **not** a BSRAM-overflow problem;
  `bin2bram.py` would fail the build if over budget.

## Theories, ranked by confidence

### 🔴 T1 — WIP sends COMPLETE *after* the data frame (definitely wrong for reads)

WIP READ handler order (firmware.c, READ case): `ACK → data → checksum → COMPLETE`.
Atari OS SIO read routine expects: `ACK → COMPLETE('C') → data + checksum`. All reference
peripherals (RespeQt, SDrive, SIO2SD) send **ACK → COMPLETE → DATA**. Committed `main` had the
correct order; the WIP reversed it.

Effect: the OS is still waiting for `'C'` while the drive transmits 128 data bytes; the bytes are
mis-framed and the late `'C'` is read as Complete, after which the OS waits for a data frame that
never arrives → timeout. **Reads cannot work in this state.** STATUS handler has the same reversal.

Fix: restore main's `ACK → COMPLETE → DATA` ordering for STATUS and READ.

### 🟠 T2 — auto-baud reads the wrong register and can corrupt the TX divisor

`sio_process_command()` does `measured = reg_sio_divisor; if (10..120) reg_sio_divisor = measured-1`.
But handler ADDR 4 is two different registers:
- **write** → `pending_divisor → divisor_reg` = TX baud (sio_handler.vhdl:214,225)
- **read**  → `receive_divisor_reg` = a measured value (sio_handler.vhdl:256)

So the firmware writes 94 then reads back something else and feeds it into the TX divisor. The
measured value comes from the now-**vestigial** `receive_enable`/`receive_detect`/`SIO_CLK_OUT`
path (sio_handler.vhdl:285-314), which the RX rewrite no longer uses for sampling. If `SIO_CLK_OUT`
doesn't toggle cleanly at the bit rate, that value is garbage; when it lands in [10,120] it silently
de-tunes the TX baud → Atari sees corrupted ACK/Complete/data.

Fix: delete the auto-baud block; hardcode TX divisor 94. Later, cleanly separate (or remove) the
measured-divisor read.

### 🟠 T3 — POKEY_ENABLE CDC can distort the baud clock

RX baud counter counts `POKEY_ENABLE` ticks; `POKEY_ENABLE` is `enable_179_early` toggle-synced
54MHz→27MHz (tang_top.sv:749-764). The toggle preserves pulse count only if `enable_179_early` is a
clean single-`clk_core`-cycle pulse. If ever asserted ≥2 consecutive core cycles, the toggle flips
twice and the XOR edge detector doubles/cancels pulses → skewed bit period. Even when correct on
average, 54→27 jitter is ~±1% on a 94-tick bit — thinner margin than MiSTer's single-domain design.
Action: confirm `ENABLE_179_EARLY` pulse width in the core.

### 🟡 T4 — instability/"not booting" is most likely firmware busy-looping in SIO

Not a BSRAM overflow (see budget above). Once an ATR is mounted, the Atari polls D1: continuously;
each (possibly mis-detected) frame runs `sio_process_command()`, which blocks on many
`delay_us(1000)` + `sio_wait_tx_empty()` + ~66 ms serializing a 128-byte frame. Meanwhile the menu /
USB / `uart_keyboard_poll` are starved, so the box *looks* hung even though the Atari core is
independent hardware. Bisect: compare boot with ATR mounted vs not mounted.

### 🟡 T5 — root cause that predates the WIP: RX framing is unverified

`main` had the correct response order yet disk still never worked → the real blocker is upstream of
the response. Suspects: the 7-bit-shift + live-bit byte assembly (sio_handler.vhdl:427), or the new
`sio_poll` frame-start heuristic (`sio_cmd_idx==0` / 50 ms gap, firmware.c) replacing the old
positional byte count, or commands never being recognized as device `0x31`. The WIP's own
`dbg_cmd_history`/`dbg_rx_buf` instrumentation exists precisely because clean command bytes were
never confirmed. **Verify this first.**

## Recommended path (untangle regression / foot-gun / diagnostics)

1. **Revert response ordering** to main's `ACK → COMPLETE → DATA` (STATUS + READ).
   **Delete the auto-baud block** (hardcode divisor 94). Keep `sio_wait_tx_empty()` and the debug
   counters/buffers.
2. **Prove RX in isolation.** Mount an ATR, open OSD, read `dbg_cmd_history` + the `R:` byte dump.
   Expect `31 53 00 00 84` (STATUS) or `31 52 <lo> <hi> <cksum>` (READ) with `command_active=1`
   and matching checksum. If garbled → bug is handler RX (T3/T5); no response tuning will help.
3. Only once command frames are clean, scope `SIO_DATA_IN` (drive→Atari) to validate ACK timing and
   baud.
4. Resolve the ADDR-4 read/write register ambiguity in the handler (or drop the measurement; the RX
   sampler no longer needs it).

## File index

- Handler: `rtl/common/sioemu/sio_handler.vhdl` (RX rewrite: baud counter ~lines 437-473;
  byte assembly ~427; vestigial measure path 285-314).
- CDC + wiring: `src/tang_top.sv:746-801`.
- Register decode: `src/iosys_picorv32.v:203-207, 274`.
- Firmware command engine: `firmware/firmware.c` `sio_process_command()`, `sio_poll()`, `sio_init()`.
- RX FIFO: `rtl/common/sioemu/fifo_receive.vhd` (depth 256).
