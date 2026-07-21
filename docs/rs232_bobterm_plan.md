# R: / modem emulation for BobTerm — research + design (2026-07-20)

Target: **BobTerm dials a telnet BBS** through the board's USB-C serial bridge.
Primary sources: FujiNet firmware `lib/device/sio/modem.cpp` (the proven
"BobTerm works against this" implementation, read in full) + its
`fujiCommandID.h` opcode table. This replaces the weather app as the flagship
N-round target — its traffic profile (keystrokes out, modem-paced text in)
matches our ring/relay architecture, unlike bulk JSON bodies (INVESTIGATE #16).

## Device + command surface (SIO device 0x50 = R1:)

| Cmd | Name | Semantics (from FujiNet, HW-proven against BobTerm) |
|---|---|---|
| 0x42 'B' | CONFIGURE | AUX1[3:0] baud code (0x8=300 … **0xF=19200**), [5:4] word size, [7] stop bits; AUX2 bits = watch DSR/CTS/CRX. **Complete-only ack**, remember baud. |
| 0x41 'A' | CONTROL | AUX1 bit pairs: [7:6] DTR enable/state, [5:4] RTS, [1:0] XMT. **DTR drop while connected = hang up.** Complete-only. |
| 0x53 'S' | STATUS | 2-byte payload: `{error bits, handshake bits}`; handshake = DSR[7:6] CTS[5:4] CRX[3:2] pairs (00 stayed-low … 11 stayed-high) + RCV[0]. FujiNet reports connected → DSR=CTS=11, CRX=11, RCV=data-available. |
| 0x57 'W' | WRITE | Block write (64-byte frame, AUX=len). Used by OS-R:-handler apps, NOT by BobTerm's built-in driver. v2. |
| 0x58 'X' | STREAM | **Concurrent mode entry.** Response payload = **9 bytes of POKEY register values** ($D200–$D208 AUDF/AUDC/SKCTL) that the Atari programs to set ITS receive baud; then the modem side switches to the configured baud and the bus becomes a raw full-duplex UART. |
| 0x3F/0x21/0x26 | POLL/RELOCATOR/HANDLER | Bootstrap that serves a 6502 R: handler to the OS. Only for OS-handler apps (Ice-T AT versions, BASIC `OPEN #1,"R:"`). **BobTerm does not need it** — its built-in 850 driver speaks the commands above directly. v2. |

### Concurrent mode lifecycle (the crux — FujiNet's model, `sio.cpp` service loop)

- **Enter:** 'X' → send the 9-byte POKEY table → `modemActive=true`, switch baud.
- **Run:** while no command frame: shuttle bytes both ways (their
  `sio_handle_modem()`), plus the Hayes personality (below) on the same stream.
- **Exit:** ANY command-frame assertion clears `modemActive` and resets to SIO
  baud, then the frame is processed normally. BobTerm re-issues 'X' when it
  wants the stream back (e.g. after disk ops). **Clean natural arbitration —
  disk I/O and the modem stream never overlap**; incoming BBS bytes during a
  disk op simply buffer (our ring + PC pending + TCP backpressure = the flow
  control answer; the real 850 used hardware handshake lines for this).
- **19200 concurrent uses the SAME line rate as SIO command frames** (POKEY
  table entry 0x28/0x00 = the standard divisor) → our existing sio_tx_byte /
  reg_sio_rx hardware path moves concurrent bytes UNCHANGED at 19200. The RX
  FIFO already captures continuously (strays are drained today). v1 supports
  19200 only; 'B' asking for less is logged (bench decides if it matters).

### AT command handling — happens INSIDE the stream

BobTerm enters concurrent immediately; the user literally types `ATDT
bbs.fozztexx.com:23` down the raw stream. FujiNet's parser (in-stream, CR/LF
or ATASCII EOL terminated): ATDT host[:port] (default 23), ATA, ATH, ATZ, ATE,
`+++` (1 s guard) → back to command mode, RING/CONNECT/OK/NO CARRIER
responses (word or numeric). Telnet IAC negotiation via libtelnet (we need a
minimal IAC responder — BBSes send negotiation bytes that would garbage the
screen raw; FujiNet exposes ATNET0/1 to toggle).

## Mapping onto our architecture

- **Firmware `sio_rs232()`** (device 0x50): B/A/S handlers (tiny) + X →
  9-byte response, then a dedicated `rs232_stream_loop()`: `reg_sio_rx` →
  event to PC; ring → `sio_tx_byte`; `bridge_poll()` each pass; exit when the
  hardware command-frame capture fires. Reuses the N: ring + 0x0B/0x0E ops.
  While in the loop there is NO other SIO duty (concurrent owns the bus) —
  the #16 combined-load hazard is structurally absent, EXCEPT bridge-RX byte
  loss, which the #16 FIFO/framing round fixes for everything at once.
- **PC `atari_net.py`**: add a `Modem` personality beside `Processor` —
  cmdMode/AT parser, telnet IAC minimal responder, socket = existing code.
  CONNECT → sync state; DTR-drop / +++ATH → hangup.
- **BobTerm delivery**: as .xex over the bridge (`atari.py run BOBTERM.XEX`) —
  the user's own originally-stated use case; no disk needed for rung 1.

## Build order (composes with INVESTIGATE #16 — do #16 items first)

1. #16 foundations: bridge RX FIFO (netlist) + framed/CRC/NAK PC protocol.
   Sized with concurrent mode as the design load (19200 sustained = 1.9 KB/s,
   6× headroom on the 115200 uplink).
2. Firmware R1: (B/A/S/X + stream loop) + PC Modem personality.
3. Sim: scripted-BBS loopback (AT dance, IAC negotiation, +++/DTR hangup,
   stream across a simulated CMD interruption).
4. Bench: BobTerm xex, 19200, fozztexx or similar living BBS. Weather app
   stays as the N: regression.

## Open items

- Verify BobTerm's exact per-command usage on the bench (which of B/A/S it
  sends and when) — log-first approach, same as the FujiNet round.
- Non-19200 bauds: needs an SIO divisor register (small netlist change) —
  only if bench shows apps genuinely running slower rates.
- OS R: handler bootstrap (poll/relocator/handler) → enables BASIC `R:` and
  handler-based terminals — v2, pairs with the boot-poll persistence item.
