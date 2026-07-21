#!/usr/bin/env python3
"""hdd_handler.py — assemble the H: CIO handler (SIO device $72 -> /HDD on SD).

A classic Atari CIO device handler, relocatable to any org, using only
official interfaces: ZIOCB ($20-$2F, CIO's zero-page copy of the active IOCB),
HATABS registration (done by the installer), DVSTAT, the SIO DCB + SIOV.

Two concurrent channels (matching the firmware's two handles), each with a
128-byte buffer: GET refills via STATUS(avail)+READ; PUT flushes on a full
buffer and at CLOSE. XIO 32 rename ("OLD,NEW") / 33 delete.

Install (session-scoped): `atari.py hdd-install` reads MEMLO, assembles the
handler just above it (plan_install — clears resident DOS, bug #19), pokes it,
adds the HATABS entry and raises MEMLO. RESET clears HATABS — re-run
(boot-poll persistence comes later).

Outputs: tools/build/hdd_handler.bin + .lst. Tests: tools/test_hdd_handler.py.
"""
import os

LOAD   = 0x0900
SIOV   = 0xE459
DVSTAT = 0x02EA
DDEVIC, DUNIT, DCOMND, DSTATS = 0x0300, 0x0301, 0x0302, 0x0303
DBUFLO, DBUFHI, DTIMLO        = 0x0304, 0x0305, 0x0306
DBYTLO, DBYTHI, DAUX1, DAUX2  = 0x0308, 0x0309, 0x030A, 0x030B
ICCOMZ, ICBALZ, ICAX1Z        = 0x22, 0x24, 0x2A
DEVICE = 0x72

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
 ('CMP','imm'):0xC9, ('CMP','abs'):0xCD, ('CMP','absx'):0xDD, ('CPY','imm'):0xC0,
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
    W('h_open-1'), W('h_close-1'), W('h_get-1'), W('h_put-1'),
    W('h_status-1'), W('h_special-1'),
    I('JMP','abs','h_rts'),                        # init vector (PC-installed)

    # A = IOCB number (X = IOCB*16 on entry to every vector)
    L('iocbnum'),
    I('TXA','imp'), I('LSR','acc'), I('LSR','acc'), I('LSR','acc'), I('LSR','acc'),
    I('RTS','imp'),

    # find the slot owned by the calling IOCB; C=1 if none
    L('findslot'),
    I('JSR','abs','iocbnum'),
    I('CMP','abs','owner0'), I('BNE','rel','fs_1'),
    I('LDA','imm',0), I('JMP','abs','setslot'),
    L('fs_1'),
    I('CMP','abs','owner1'), I('BNE','rel','fs_no'),
    I('LDA','imm',1), I('JMP','abs','setslot'),
    L('fs_no'),
    I('SEC','imp'), I('RTS','imp'),

    # A = slot -> slot var + self-mod buffer base + DCB base bytes; C=0
    L('setslot'),
    I('STA','abs','slot'),
    I('BNE','rel','ss_1'),
    I('LDA','imm','#<buf0'), I('JMP','abs','ss_lo'),
    L('ss_1'),
    I('LDA','imm','#<buf1'),
    L('ss_lo'),
    I('STA','abs','ld_buf+1'), I('STA','abs','st_buf+1'), I('STA','abs','buflo'),
    I('LDA','abs','slot'), I('BNE','rel','ss_h1'),
    I('LDA','imm','#>buf0'), I('JMP','abs','ss_hi'),
    L('ss_h1'),
    I('LDA','imm','#>buf1'),
    L('ss_hi'),
    I('STA','abs','ld_buf+2'), I('STA','abs','st_buf+2'), I('STA','abs','bufhi'),
    I('CLC','imp'), I('RTS','imp'),

    # SIO call: A = command; DAUX2=slot, device/unit/timeout set here
    L('siogo'),
    I('STA','abs',DCOMND),
    I('LDA','imm',DEVICE), I('STA','abs',DDEVIC),
    I('LDA','imm',1),      I('STA','abs',DUNIT),
    I('LDA','imm',8),      I('STA','abs',DTIMLO),
    I('LDA','abs','slot'), I('STA','abs',DAUX2),
    I('JSR','abs',SIOV),
    I('RTS','imp'),                                # Y = SIO status

    # copy the ZIOCB name string to namebuf (EOL/NUL ends; zero-padded to 64)
    L('copyname'),
    I('LDY','imm',0),
    L('cn_loop'),
    I('LDA','indy',ICBALZ),
    I('CMP','imm',0x9B), I('BEQ','rel','cn_pad'),
    I('CMP','imm',0),    I('BEQ','rel','cn_pad'),
    I('STA','absy','namebuf'),
    I('INY','imp'), I('CPY','imm',63), I('BNE','rel','cn_loop'),
    L('cn_pad'),
    I('LDA','imm',0),
    L('cn_padl'),
    I('STA','absy','namebuf'),
    I('INY','imp'), I('CPY','imm',64), I('BNE','rel','cn_padl'),
    # DCB: 64-byte send from namebuf
    I('LDA','imm','#<namebuf'), I('STA','abs',DBUFLO),
    I('LDA','imm','#>namebuf'), I('STA','abs',DBUFHI),
    I('LDA','imm',64), I('STA','abs',DBYTLO),
    I('LDA','imm',0),  I('STA','abs',DBYTHI),
    I('LDA','imm',0x80), I('STA','abs',DSTATS),
    I('RTS','imp'),

    # ── OPEN ─────────────────────────────────────────────────────────────────
    L('h_open'),
    I('LDA','abs','owner0'), I('CMP','imm',0xFF), I('BEQ','rel','op_u0'),
    I('LDA','abs','owner1'), I('CMP','imm',0xFF), I('BEQ','rel','op_u1'),
    I('LDY','imm',161), I('RTS','imp'),            # too many open channels
    L('op_u0'), I('LDA','imm',0), I('JMP','abs','op_go'),
    L('op_u1'), I('LDA','imm',1),
    L('op_go'),
    I('JSR','abs','setslot'),
    I('JSR','abs','iocbnum'),
    I('LDX','abs','slot'),
    I('STA','absx','owner0'),                      # claim (owner0/owner1 adjacent)
    I('LDA','zp',ICAX1Z),                          # open mode
    I('STA','absx','mode0'),
    I('LDA','imm',0),
    I('STA','absx','cnt0'), I('STA','absx','pos0'),
    I('JSR','abs','copyname'),
    I('LDX','abs','slot'),
    I('LDA','absx','mode0'), I('STA','abs',DAUX1),
    I('LDA','imm',0x4F),                           # 'O'
    I('JSR','abs','siogo'),
    I('TYA','imp'), I('BMI','rel','op_fail'),
    I('LDY','imm',1), I('RTS','imp'),
    L('op_fail'),
    I('LDX','abs','slot'),
    I('LDA','imm',0xFF), I('STA','absx','owner0'), # release the claim
    I('RTS','imp'),                                # Y = SIO error

    # ── GET ──────────────────────────────────────────────────────────────────
    L('h_get'),
    I('JSR','abs','findslot'), I('BCC','rel','g_have'),
    I('LDY','imm',133), I('RTS','imp'),            # not open
    L('g_have'),
    I('LDX','abs','slot'),
    I('LDA','absx','pos0'), I('CMP','absx','cnt0'), I('BNE','rel','g_serve'),
    I('JSR','abs','do_status'),
    I('TYA','imp'), I('BMI','rel','g_ret'),
    I('LDA','abs',DVSTAT + 2), I('ORA','abs',DVSTAT + 3), I('BNE','rel','g_len'),
    I('LDY','imm',136), I('RTS','imp'),            # EOF
    L('g_len'),
    I('LDA','abs',DVSTAT + 3), I('BNE','rel','g_cap'),
    I('LDA','abs',DVSTAT + 2), I('CMP','imm',129), I('BCC','rel','g_setl'),
    L('g_cap'), I('LDA','imm',128),
    L('g_setl'),
    I('STA','abs','xferlen'),
    I('LDA','abs','buflo'), I('STA','abs',DBUFLO),
    I('LDA','abs','bufhi'), I('STA','abs',DBUFHI),
    I('LDA','abs','xferlen'), I('STA','abs',DBYTLO), I('STA','abs',DAUX1),
    I('LDA','imm',0), I('STA','abs',DBYTHI),
    I('LDA','imm',0x40), I('STA','abs',DSTATS),
    I('LDA','imm',0x52),                           # 'R'
    I('JSR','abs','siogo'),
    I('TYA','imp'), I('BMI','rel','g_ret'),
    I('LDX','abs','slot'),
    I('LDA','abs','xferlen'), I('STA','absx','cnt0'),
    I('LDA','imm',0), I('STA','absx','pos0'),
    L('g_serve'),
    I('LDX','abs','slot'),
    I('LDA','absx','pos0'),
    I('TAY','imp'),                                # Y = old pos
    I('CLC','imp'), I('ADC','imm',1),
    I('STA','absx','pos0'),                        # pos += 1
    I('TYA','imp'), I('TAX','imp'),                # X = old pos
    L('ld_buf'),
    I('LDA','absx','buf0'),                        # self-modified base
    I('LDY','imm',1),
    L('g_ret'),
    I('RTS','imp'),

    # ── PUT ──────────────────────────────────────────────────────────────────
    L('h_put'),
    I('PHA','imp'),
    I('JSR','abs','findslot'), I('BCC','rel','p_have'),
    I('PLA','imp'), I('LDY','imm',133), I('RTS','imp'),
    L('p_have'),
    I('LDX','abs','slot'),
    I('LDA','absx','pos0'),
    I('TAY','imp'),                                # Y = old pos
    I('CLC','imp'), I('ADC','imm',1),
    I('STA','absx','pos0'),
    I('TYA','imp'), I('TAX','imp'),                # X = old pos
    I('PLA','imp'),
    L('st_buf'),
    I('STA','absy','buf0'),                        # self-modified base (Y=... )
    I('LDX','abs','slot'),
    I('LDA','absx','pos0'),
    I('CMP','imm',128), I('BCC','rel','p_done'),
    I('JSR','abs','flush'),
    I('TYA','imp'), I('BMI','rel','p_ret'),
    L('p_done'),
    I('LDY','imm',1),
    L('p_ret'),
    I('RTS','imp'),

    # flush pos0[slot] buffered bytes via WRITE; resets pos; Y=status
    L('flush'),
    I('LDX','abs','slot'),
    I('LDA','absx','pos0'), I('BNE','rel','fl_go'),
    I('LDY','imm',1), I('RTS','imp'),
    L('fl_go'),
    I('STA','abs','xferlen'),
    I('LDA','abs','buflo'), I('STA','abs',DBUFLO),
    I('LDA','abs','bufhi'), I('STA','abs',DBUFHI),
    I('LDA','abs','xferlen'), I('STA','abs',DBYTLO), I('STA','abs',DAUX1),
    I('LDA','imm',0), I('STA','abs',DBYTHI),
    I('LDA','imm',0x80), I('STA','abs',DSTATS),
    I('LDA','imm',0x57),                           # 'W'
    I('JSR','abs','siogo'),
    I('LDX','abs','slot'),
    I('LDA','imm',0), I('STA','absx','pos0'),
    I('RTS','imp'),

    # ── CLOSE ────────────────────────────────────────────────────────────────
    L('h_close'),
    I('JSR','abs','findslot'), I('BCC','rel','c_have'),
    I('LDY','imm',1), I('RTS','imp'),
    L('c_have'),
    I('LDX','abs','slot'),
    I('LDA','absx','mode0'), I('AND','imm',0x08), I('BEQ','rel','c_nofl'),
    I('JSR','abs','flush'),
    L('c_nofl'),
    I('LDA','imm',0), I('STA','abs',DSTATS),
    I('LDA','imm',0), I('STA','abs',DBYTLO), I('STA','abs',DBYTHI),
    I('LDA','imm',0x43),                           # 'C'
    I('JSR','abs','siogo'),
    I('LDX','abs','slot'),
    I('LDA','imm',0xFF), I('STA','absx','owner0'),
    I('LDY','imm',1), I('RTS','imp'),

    # ── STATUS (fills DVSTAT) ────────────────────────────────────────────────
    L('h_status'),
    I('JSR','abs','findslot'),
    I('JSR','abs','do_status'),
    I('LDY','imm',1), I('RTS','imp'),

    L('do_status'),
    I('LDA','imm','#<746'), I('STA','abs',DBUFLO),   # DVSTAT = $02EA = 746
    I('LDA','imm','#>746'), I('STA','abs',DBUFHI),
    I('LDA','imm',4), I('STA','abs',DBYTLO),
    I('LDA','imm',0), I('STA','abs',DBYTHI), I('STA','abs',DAUX1),
    I('LDA','imm',0x40), I('STA','abs',DSTATS),
    I('LDA','imm',0x53),                           # 'S'
    I('JSR','abs','siogo'),
    I('RTS','imp'),

    # ── SPECIAL: XIO 32 rename / 33 delete ──────────────────────────────────
    L('h_special'),
    I('LDA','zp',ICCOMZ),
    I('CMP','imm',32), I('BEQ','rel','sp_go'),
    I('CMP','imm',33), I('BEQ','rel','sp_go'),
    I('LDY','imm',146), I('RTS','imp'),            # not implemented
    L('sp_go'),
    I('PHA','imp'),
    I('JSR','abs','copyname'),
    I('PLA','imp'), I('STA','abs',DAUX1),          # aux1 = XIO number
    I('LDA','imm',0x58),                           # 'X'
    I('JSR','abs','siogo'),
    I('TYA','imp'), I('BMI','rel','sp_ret'),
    I('LDY','imm',1),
    L('sp_ret'),
    I('RTS','imp'),

    L('h_rts'),
    I('RTS','imp'),

    # ── state (paired arrays: xxx0/xxx1 adjacent for absx addressing) ───────
    L('slot'),    B(0),
    L('buflo'),   B(0),
    L('bufhi'),   B(0),
    L('xferlen'), B(0),
    L('owner0'),  B(0xFF),
    L('owner1'),  B(0xFF),
    L('mode0'),   B(0),
    L('mode1'),   B(0),
    L('cnt0'),    B(0),
    L('cnt1'),    B(0),
    L('pos0'),    B(0),
    L('pos1'),    B(0),
    L('namebuf'), SP(64),
    L('buf0'),    SP(128),
    L('buf1'),    SP(128),
]


def build(org=LOAD):
    _, labels = assemble(prog, org)                 # pass A: sizes + labels
    code, labels = assemble(prog, org, resolve_hash=labels)  # pass B: resolve #<
    return code, labels


def plan_install(memlo):
    """Pick the install org for a live machine and assemble there.

    org = page-aligned MEMLO + $200: the +$200 clears BASIC's 256-byte
    tokenize buffer AND its (near-empty) tables, which sit AT LOMEM == MEMLO —
    installing exactly at MEMLO would be shredded by the next typed line.
    DOS-less (MEMLO=$0700) this lands at the HW-proven $0900; with resident
    MyDOS (MEMLO ~$1Fxx+) it clears the FMS (bug #19). BASIC only re-reads the
    raised MEMLO on NEW — the installer's caller must say so.

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
    open(os.path.join(out, 'hdd_handler.bin'), 'wb').write(code)
    with open(os.path.join(out, 'hdd_handler.lst'), 'w') as f:
        for k in sorted(labels, key=labels.get):
            f.write(f"{labels[k]:04X} {k}\n")
    print(f"hdd_handler.bin: {len(code)} bytes ${LOAD:04X}-${LOAD+len(code)-1:04X}")
