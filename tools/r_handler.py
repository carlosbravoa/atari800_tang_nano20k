#!/usr/bin/env python3
"""r_handler.py — assemble the R: (850 modem) CIO handler for SIO device $50.

FIRST-CUT / OBSERVATION build. Goal: get BobTerm past "No modem handler!" (it
requires an R: entry in HATABS) and let us watch, from the firmware + atari_net
logs, exactly which CIO/SIO calls BobTerm makes — then flesh this out to match.

A classic relocatable Atari CIO handler (same machinery as hdd_handler.py), using
only official interfaces: ZIOCB ($20-$2F), HATABS (installer), DVSTAT, the SIO DCB
+ SIOV. It bridges CIO to the firmware's device-$50 850 command set:

  OPEN            -> CONFIGURE ($42, default 19200)              [logs a session]
  CLOSE           -> CONTROL   ($41, drop DTR = hang up)
  STATUS          -> STATUS    ($53) -> DVSTAT {err, handshake}
  XIO 36/38 baud  -> CONFIGURE ($42, AUX1 baud code)
  XIO 40 start    -> STREAM    ($58): read the 9-byte POKEY table and program
                     $D200-$D208 + SKCTL for concurrent mode (BobTerm then drives
                     POKEY directly; the firmware relay carries the raw stream).
  GET / PUT       -> SAFE STUBS for now (concurrent mode does byte I/O via POKEY,
                     not through the handler; if the bench shows BobTerm calling
                     these, we implement real block/interrupt I/O next).

Install (session-scoped) is done by atari_link.r_install() / `atari.py r-install`
/ automatically by `atari_net.py --modem`. RESET clears HATABS — re-run.

Outputs: tools/build/r_handler.bin + .lst. Tests: tools/test_r_handler.py.
"""
import os

LOAD   = 0x0900
SIOV   = 0xE459
DVSTAT = 0x02EA
DDEVIC, DUNIT, DCOMND, DSTATS = 0x0300, 0x0301, 0x0302, 0x0303
DBUFLO, DBUFHI, DTIMLO        = 0x0304, 0x0305, 0x0306
DBYTLO, DBYTHI, DAUX1, DAUX2  = 0x0308, 0x0309, 0x030A, 0x030B
ICCOMZ, ICBALZ, ICAX1Z        = 0x22, 0x24, 0x2A
DEVICE   = 0x50
AUDF1    = 0xD200        # POKEY audio/serial regs $D200-$D208 (9-byte table)
SKCTL    = 0xD20F        # POKEY serial/keyboard control
SSKCTL   = 0x0232        # SKCTL OS shadow
SKCTL_CONCURRENT = 0x73  # async two-way serial (bench-tune)
DEFAULT_BAUD = 0x0F      # CONFIGURE code 0xF = 19200

OPC = {
 ('LDA','imm'):0xA9, ('LDA','zp'):0xA5, ('LDA','abs'):0xAD, ('LDA','absx'):0xBD,
 ('LDA','indy'):0xB1,
 ('STA','abs'):0x8D, ('STA','absx'):0x9D, ('STA','absy'):0x99, ('STA','zp'):0x85,
 ('LDX','imm'):0xA2, ('LDX','abs'):0xAE, ('STX','abs'):0x8E,
 ('LDY','imm'):0xA0, ('LDY','abs'):0xAC, ('STY','abs'):0x8C,
 ('TAX','imp'):0xAA, ('TXA','imp'):0x8A, ('TAY','imp'):0xA8, ('TYA','imp'):0x98,
 ('INX','imp'):0xE8, ('INY','imp'):0xC8, ('DEX','imp'):0xCA,
 ('INC','abs'):0xEE, ('DEC','abs'):0xCE,
 ('LSR','acc'):0x4A,
 ('PHA','imp'):0x48, ('PLA','imp'):0x68,
 ('ADC','imm'):0x69,
 ('CMP','imm'):0xC9, ('CMP','abs'):0xCD, ('CMP','absx'):0xDD,
 ('CPX','imm'):0xE0, ('CPY','imm'):0xC0,
 ('AND','imm'):0x29, ('ORA','abs'):0x0D,
 ('SEC','imp'):0x38, ('CLC','imp'):0x18,
 ('BNE','rel'):0xD0, ('BEQ','rel'):0xF0, ('BCC','rel'):0x90, ('BCS','rel'):0xB0,
 ('BMI','rel'):0x30, ('BPL','rel'):0x10,
 ('JMP','abs'):0x4C, ('JSR','abs'):0x20, ('RTS','imp'):0x60,
}
SIZE = {'imp':1,'acc':1,'imm':2,'zp':2,'indy':2,'abs':3,'absx':3,'absy':3,
        'rel':2,'byte':1,'word':2}


def assemble(prog, org, resolve_hash=None):
    labels, pc = {}, org
    for it in prog:
        if it[0] == 'label':
            labels[it[1]] = pc
        elif it[1] == 'space':
            pc += it[2]
        else:
            pc += SIZE[it[1]]

    def v(o):
        if isinstance(o, str):
            if o.startswith('#'):
                if resolve_hash is None:
                    return 0
                expr = o[1:]
                lo = expr[0] == '<'
                name = expr[1:]
                val = labels[name] if name in labels else int(name)
                return val & 0xFF if lo else (val >> 8) & 0xFF
            if '+' in o:
                b_, off = o.split('+')
                return labels[b_] + int(off)
            if o.endswith('-1'):
                return labels[o[:-2]] - 1
            return labels[o]
        return o

    out, pc = bytearray(), org
    for it in prog:
        if it[0] == 'label':
            continue
        mnem, mode = it[0], it[1]
        opnd = it[2] if len(it) > 2 else None
        if mode == 'byte':
            out.append(v(opnd) & 0xFF); pc += 1; continue
        if mode == 'word':
            x = v(opnd); out += bytes([x & 0xFF, (x >> 8) & 0xFF]); pc += 2; continue
        if mode == 'space':
            out += bytes(opnd); pc += opnd; continue
        op = OPC[(mnem, mode)]
        if mode in ('imp', 'acc'):
            out.append(op)
        elif mode in ('imm', 'zp', 'indy'):
            out += bytes([op, v(opnd) & 0xFF])
        elif mode in ('abs', 'absx', 'absy'):
            x = v(opnd); out += bytes([op, x & 0xFF, (x >> 8) & 0xFF])
        elif mode == 'rel':
            rel = v(opnd) - (pc + 2)
            assert -128 <= rel <= 127, f"branch out of range: {opnd} {rel}"
            out += bytes([op, rel & 0xFF])
        pc += SIZE[mode]
    return bytes(out), labels


def I(m, mode, o=None):
    return (m, mode, o) if o is not None else (m, mode)


L = lambda n: ('label', n)
B = lambda x: ('?', 'byte', x)
W = lambda x: ('?', 'word', x)
SP = lambda n: ('?', 'space', n)

prog = [
    # ── CIO handler vector table (address-1 words, per the OS spec) ─────────
    L('table'),
    W('r_open-1'), W('r_close-1'), W('r_get-1'), W('r_put-1'),
    W('r_status-1'), W('r_special-1'),
    I('JMP','abs','r_rts'),                        # init vector (PC-installed)

    # SIO call: A = command; device/unit/timeout set here. Caller pre-loads
    # DSTATS / DBUF* / DBYT* / DAUX1 for read/write/complete framing.
    L('siogo'),
    I('STA','abs',DCOMND),
    I('LDA','imm',DEVICE), I('STA','abs',DDEVIC),
    I('LDA','imm',1),      I('STA','abs',DUNIT),
    I('LDA','imm',8),      I('STA','abs',DTIMLO),
    I('JSR','abs',SIOV),
    I('RTS','imp'),                                # Y = SIO status

    # send a complete-only command (no data frame): A=command, DAUX1 preset
    L('cmd_only'),
    I('PHA','imp'),
    I('LDA','imm',0), I('STA','abs',DSTATS),
    I('STA','abs',DBYTLO), I('STA','abs',DBYTHI),
    I('PLA','imp'),
    I('JMP','abs','siogo'),

    # ── OPEN — CONFIGURE the modem (default baud), always succeed ────────────
    L('r_open'),
    I('LDA','imm',DEFAULT_BAUD), I('STA','abs',DAUX1),
    I('LDA','imm',0x42),                           # 'B' CONFIGURE
    I('JSR','abs','cmd_only'),
    I('LDY','imm',1), I('RTS','imp'),

    # ── CLOSE — drop DTR (hang up), always succeed ──────────────────────────
    L('r_close'),
    I('LDA','imm',0x80), I('STA','abs',DAUX1),      # DTR-change-enable, DTR=0
    I('LDA','imm',0x41),                            # 'A' CONTROL
    I('JSR','abs','cmd_only'),
    I('LDY','imm',1), I('RTS','imp'),

    # ── GET — STUB (concurrent mode reads POKEY directly, not via CIO) ───────
    # Returns A=0, Y=1. If the bench shows BobTerm calling GET, implement real
    # buffered/interrupt input here.
    L('r_get'),
    I('LDA','imm',0),
    I('LDY','imm',1), I('RTS','imp'),

    # ── PUT — STUB (discard; concurrent mode writes POKEY directly) ──────────
    L('r_put'),
    I('LDY','imm',1), I('RTS','imp'),

    # ── STATUS — $53 -> DVSTAT {err, handshake} ─────────────────────────────
    L('r_status'),
    I('LDA','imm','#<746'), I('STA','abs',DBUFLO),  # DVSTAT = $02EA = 746
    I('LDA','imm','#>746'), I('STA','abs',DBUFHI),
    I('LDA','imm',2), I('STA','abs',DBYTLO),
    I('LDA','imm',0), I('STA','abs',DBYTHI), I('STA','abs',DAUX1),
    I('LDA','imm',0x40), I('STA','abs',DSTATS),      # read
    I('LDA','imm',0x53),                             # 'S' STATUS
    I('JSR','abs','siogo'),
    I('LDY','imm',1), I('RTS','imp'),

    # ── SPECIAL (XIO) ───────────────────────────────────────────────────────
    L('r_special'),
    I('LDA','zp',ICCOMZ),
    I('CMP','imm',40), I('BEQ','rel','sp_stream'),   # XIO 40 start concurrent
    I('CMP','imm',36), I('BEQ','rel','sp_baud'),     # XIO 36 set baud
    I('CMP','imm',38), I('BEQ','rel','sp_baud'),     # XIO 38 set translation/baud
    I('LDY','imm',1), I('RTS','imp'),                # accept every other XIO

    L('sp_baud'),
    I('LDA','zp',ICAX1Z), I('STA','abs',DAUX1),       # AUX1 baud code
    I('LDA','imm',0x42),                              # CONFIGURE
    I('JSR','abs','cmd_only'),
    I('LDY','imm',1), I('RTS','imp'),

    # XIO 40: read the 9-byte POKEY table from $58 and program POKEY for the
    # negotiated baud. BobTerm then owns the concurrent stream via POKEY.
    L('sp_stream'),
    I('LDA','imm','#<pokeybuf'), I('STA','abs',DBUFLO),
    I('LDA','imm','#>pokeybuf'), I('STA','abs',DBUFHI),
    I('LDA','imm',9), I('STA','abs',DBYTLO),
    I('LDA','imm',0), I('STA','abs',DBYTHI), I('STA','abs',DAUX1),
    I('LDA','imm',0x40), I('STA','abs',DSTATS),        # read (+discard) the 9-byte reply
    I('LDA','imm',0x58),                               # 'X' STREAM -> fw concurrent
    I('JSR','abs','siogo'),
    I('TYA','imp'), I('BMI','rel','sp_sfail'),
    # Deliberately DO NOT poke POKEY. The bench proved that reprogramming POKEY
    # here ($D200-$D208 / SKCTL) leaves it in a state that CORRUPTS the following
    # SIO command frames — BobTerm's baud scan is clean (each command frame resets
    # POKEY via the OS SIO), but once it settles into terminal mode our leftover
    # POKEY config makes every command frame arrive malformed ("cmd cksum" storm)
    # plus a constant SIO tone. At 19200 POKEY is already the correct async UART
    # for the firmware relay, so we leave POKEY entirely to the OS / BobTerm.
    I('LDY','imm',1), I('RTS','imp'),
    L('sp_sfail'),
    I('RTS','imp'),                                    # Y = SIO error

    L('r_rts'),
    I('RTS','imp'),

    # ── self-installer (INITAD target for the boot-disk build) ──────────────
    # Registers 'R' -> this handler's vector table in HATABS ($031A, 3-byte
    # entries). No MEMLO change: the boot build loads the handler into always-
    # reserved page 6, which sits below MEMLO already. Idempotent.
    L('installer'),
    I('LDX','imm',0),
    L('ins_find'),
    I('LDA','absx',0x031A),
    I('BEQ','rel','ins_free'),                     # 0 = empty slot
    I('CMP','imm',0x52), I('BEQ','rel','ins_done'), # 'R' already present
    I('INX','imp'), I('INX','imp'), I('INX','imp'),
    I('CPX','imm',36),                             # 12 slots * 3 bytes
    I('BNE','rel','ins_find'),
    I('RTS','imp'),                                # HATABS full — give up quietly
    L('ins_free'),
    I('LDA','imm',0x52), I('STA','absx',0x031A),    # 'R'
    I('LDA','imm','#<table'), I('STA','absx',0x031B),
    I('LDA','imm','#>table'), I('STA','absx',0x031C),
    L('ins_done'),
    I('RTS','imp'),

    # ── state ───────────────────────────────────────────────────────────────
    L('pokeybuf'), SP(9),
]


def build(org=LOAD):
    _, labels = assemble(prog, org)                 # pass A: sizes + labels
    code, labels = assemble(prog, org, resolve_hash=labels)  # pass B: resolve #<
    return code, labels


# The handler (259 B) overflows page 6, so the boot build loads it into the free
# gap just above DOS 2.5's MEMLO (~$1D00) and below BobTerm's first segment
# ($3000), then RAISES MEMLO past it so BobTerm's MEMLO-based allocations stay
# clear. $2000 leaves a comfortable margin on both sides.
BOOT_ORG = 0x2000
MEMLO_LO, MEMLO_HI = 0x02E7, 0x02E8


def build_xex(org=BOOT_ORG):
    """Assemble the handler at `org` and wrap it as Atari binary-load (.xex)
    segments with an INITAD ($02E2) that (1) registers 'R' in HATABS via the
    self-installer and (2) raises MEMLO past the handler. Intended to be
    APPENDED to another program's AUTORUN.SYS so R: is resident before that
    program's RUNAD fires. Returns (xex_bytes, new_memlo)."""
    code, labels = build(org)
    installer = labels['installer']
    stub_org = org + len(code)
    new_memlo = (stub_org + 14 + 0xFF) & 0xFF00        # 14 = stub length below

    # INITAD stub: JSR installer ; STA MEMLO = new_memlo ; RTS
    stub = bytes([
        0x20, installer & 0xFF, installer >> 8,        # JSR installer
        0xA9, new_memlo & 0xFF, 0x8D, MEMLO_LO & 0xFF, MEMLO_LO >> 8,  # LDA/STA lo
        0xA9, new_memlo >> 8,   0x8D, MEMLO_HI & 0xFF, MEMLO_HI >> 8,  # LDA/STA hi
        0x60,                                          # RTS
    ])
    assert len(stub) == 14

    def seg(start, data):
        end = start + len(data) - 1
        return bytes([start & 0xFF, start >> 8, end & 0xFF, end >> 8]) + data

    out = b'\xff\xff'                                   # binary-load header
    out += seg(org, code)                              # handler body
    out += seg(stub_org, stub)                          # installer stub
    out += seg(0x02E2, bytes([stub_org & 0xFF, stub_org >> 8]))  # INITAD -> stub
    return out, new_memlo


def plan_install(memlo):
    """Pick the install org for a live machine and assemble there (identical
    policy to hdd_handler.plan_install: page-aligned MEMLO + $200 cushion clears
    BASIC's tokenize buffer / resident DOS; DOS-less lands at the proven $0900).
    Returns (org, code, new_memlo)."""
    if not 0x0480 <= memlo <= 0x8000:
        raise ValueError(f"implausible MEMLO ${memlo:04X} — machine not in a "
                         "sane OS state?")
    org = ((memlo + 0xFF) & 0xFF00) + 0x200
    code, _ = build(org)
    new_memlo = (org + len(code) + 0xFF) & 0xFF00
    if new_memlo > 0x9000:
        raise ValueError(f"no room above MEMLO ${memlo:04X} — handler would "
                         f"end at ${new_memlo:04X}")
    return org, code, new_memlo


if __name__ == '__main__':
    code, labels = build()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'build')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'r_handler.bin'), 'wb').write(code)
    with open(os.path.join(out, 'r_handler.lst'), 'w') as f:
        for k in sorted(labels, key=labels.get):
            f.write(f"{labels[k]:04X} {k}\n")
    print(f"r_handler.bin: {len(code)} bytes ${LOAD:04X}-${LOAD+len(code)-1:04X}")
