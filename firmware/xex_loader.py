#!/usr/bin/env python3
# Assembles the 6502 XEX boot loader and emits firmware/xex_loader.h
#
# The firmware serves this loader as a *virtual bootable disk* on D1:. The
# Atari OS disk-boot reads sectors 1..BLDCNT into RAM at $0700 and then JSRs
# $0706 (load+6). From there the loader pulls the remaining disk sectors (the
# raw .xex file bytes, 128 per sector, starting at FIRSTSEC) via SIOV and
# processes the Atari binary-load format:
#   - leading $FFFF header / optional $FFFF segment separators
#   - per-segment start/end address words followed by that many data bytes
#   - INITAD ($02E2/3): JSR (INITAD) after a segment that sets it
#   - RUNAD  ($02E0/1): JMP (RUNAD) at end-of-file (preset to the first
#                       segment's start so files without an explicit RUNAD
#                       still auto-run)
# End-of-file is an exact byte counter (REM) the firmware patches in per file,
# so the partially-filled last sector never feeds garbage to the parser.
#
# Loader code lives at $0700; $0600 is the 128-byte sector buffer.
# Limitation: a .xex that loads into $0600-$07FF would overwrite the running
# loader. That range is rarely used by real programs.
#
# Run:  python3 xex_loader.py   (regenerates xex_loader.h)

LOAD = 0x0700

# Diagnostic build: paint COLBK at milestones and halt at RUNAD instead of
# jumping. Lets us locate a hardware boot failure with no UART (TX is unwired):
#   red  = loader got control      green = a sector read succeeded
#   blue + frozen = parsed to RUNAD (loader works; problem is downstream)
DIAG = False     # production: no COLBK milestone painting; JMP RUNAD (don't halt)
COLBK = 0x02C8   # background colour shadow (VBI copies it to $D01A each frame)

# Zero-page scratch — all in the "free for application" $CB-$D7 region.
BUFIDX = 0xCB   # index into sector buffer (0..127; 128 => needs refill)
SECLO  = 0xCC   # next disk sector to fetch (16-bit)
SECHI  = 0xCD
REMLO  = 0xCE   # remaining stream bytes, 24-bit little-endian (patched per file)
REMMID = 0xCF
REMHI  = 0xD0
DSTLO  = 0xD1   # moving store pointer
DSTHI  = 0xD2
ENDLO  = 0xD3   # current segment end address
ENDHI  = 0xD4
SSTLO  = 0xD5   # current segment start address (saved)
SSTHI  = 0xD6
FIRSTF = 0xD7   # 1 until the first segment's start is copied into RUNAD

BUF    = 0x0600
SIOV   = 0xE459
RUNAD  = 0x02E0
INITAD = 0x02E2

# ---- minimal 2-pass assembler ---------------------------------------------
OPC = {
    ('LDA','imm'):0xA9, ('LDA','zp'):0xA5, ('LDA','absx'):0xBD, ('LDA','indy'):0xB1,
    ('STA','zp'):0x85, ('STA','abs'):0x8D, ('STA','indy'):0x91,
    ('TAX','imp'):0xAA,
    ('INX','imp'):0xE8,
    ('INC','zp'):0xE6, ('DEC','zp'):0xC6,
    ('CMP','imm'):0xC9, ('CMP','zp'):0xC5,
    ('AND','zp'):0x25, ('ORA','zp'):0x05,
    ('SBC','imm'):0xE9,
    ('SEC','imp'):0x38, ('CLC','imp'):0x18,
    ('BNE','rel'):0xD0, ('BEQ','rel'):0xF0, ('BCC','rel'):0x90, ('BCS','rel'):0xB0,
    ('JMP','abs'):0x4C, ('JMP','ind'):0x6C, ('JSR','abs'):0x20, ('RTS','imp'):0x60,
    ('LDY','imm'):0xA0,
}
SIZE = {'imp':1,'imm':2,'zp':2,'absx':3,'abs':3,'ind':3,'indy':2,'rel':2,
        'byte':1,'word':2}

def assemble(prog):
    labels, pc = {}, LOAD
    for it in prog:                              # pass 1: resolve labels
        if it[0] == 'label':
            labels[it[1]] = pc
        else:
            pc += SIZE[it[1]]
    out, pc, patch = [], LOAD, {}
    def v(o):
        if isinstance(o, str) and o.startswith('@'):
            return 0                              # placeholder, patched later
        return labels[o] if isinstance(o, str) else o
    for it in prog:                              # pass 2: encode
        if it[0] == 'label':
            continue
        mnem, mode, opnd = it
        if mode == 'byte':
            out.append(v(opnd) & 0xFF)
        elif mode == 'word':
            x = v(opnd); out += [x & 0xFF, (x >> 8) & 0xFF]
        else:
            op = OPC[(mnem, mode)]
            if mode == 'imp':
                out.append(op)
            elif mode in ('imm','zp','indy'):
                out += [op, v(opnd) & 0xFF]
            elif mode in ('abs','absx','ind'):
                x = v(opnd); out += [op, x & 0xFF, (x >> 8) & 0xFF]
            elif mode == 'rel':
                rel = v(opnd) - (pc + 2)
                assert -128 <= rel <= 127, f"branch out of range -> {opnd}: {rel}"
                out += [op, rel & 0xFF]
        if isinstance(opnd, str) and opnd.startswith('@'):
            patch[opnd] = len(out) - 1            # offset of the operand byte
        pc += SIZE[mode]
    return out, labels, patch

def b(x):   return ('?', 'byte', x)
def w(x):   return ('?', 'word', x)
def i(m, mode, o=None): return (m, mode, o)
L = lambda n: ('label', n)

prog = [
    # ---- boot header (offset 0..5) ----
    b(0x00),                       # +0 flags
    b('@BLDCNT'),                  # +1 sector count
    w(LOAD),                       # +2 load address
    w('boot6'),                    # +4 DOSINI (unused; boot6 never returns)
    L('boot6'),
    i('JMP','abs','start'),        # +6 OS JSRs here after loading the loader

    # ---- getbyte: returns next stream byte in A; C=1 on EOF. clobbers A,X ----
    L('getbyte'),
    i('LDA','zp',REMLO), i('ORA','zp',REMMID), i('ORA','zp',REMHI),
    i('BNE','rel','gb_ok'),
    i('SEC','imp'), i('RTS','imp'),
    L('gb_ok'),
    i('LDA','zp',REMLO), i('SEC','imp'), i('SBC','imm',1), i('STA','zp',REMLO),
    i('LDA','zp',REMMID), i('SBC','imm',0), i('STA','zp',REMMID),
    i('LDA','zp',REMHI), i('SBC','imm',0), i('STA','zp',REMHI),
    i('LDA','zp',BUFIDX), i('CMP','imm',128), i('BCC','rel','gb_have'),
    i('JSR','abs','readsec'),
    i('LDA','imm',0), i('STA','zp',BUFIDX),
    L('gb_have'),
    i('LDA','zp',BUFIDX), i('TAX','imp'),   # X = current index
    i('INC','zp',BUFIDX),                   # BUFIDX++ (leaves A,X untouched)
    i('LDA','absx',BUF),                    # A = BUF[X]
    i('CLC','imp'), i('RTS','imp'),

    # ---- readsec: read sector SECLO/HI into BUF via SIOV; inc sector ----
    L('readsec'),
    i('LDA','imm',0x31), i('STA','abs',0x0300),   # DDEVIC = $31 (D:)
    i('LDA','imm',0x01), i('STA','abs',0x0301),   # DUNIT  = 1
    i('LDA','imm',0x52), i('STA','abs',0x0302),   # DCOMND = read
    i('LDA','imm',0x40), i('STA','abs',0x0303),   # DSTATS = read direction
    i('LDA','imm',BUF & 0xFF),  i('STA','abs',0x0304),  # DBUFLO
    i('LDA','imm',BUF >> 8),    i('STA','abs',0x0305),  # DBUFHI
    i('LDA','imm',0x1F), i('STA','abs',0x0306),   # DTIMLO timeout
    i('LDA','imm',0x80), i('STA','abs',0x0308),   # DBYTLO = 128
    i('LDA','imm',0x00), i('STA','abs',0x0309),   # DBYTHI
    i('LDA','zp',SECLO), i('STA','abs',0x030A),   # DAUX1 = sector lo
    i('LDA','zp',SECHI), i('STA','abs',0x030B),   # DAUX2 = sector hi
    i('JSR','abs',SIOV),
    i('INC','zp',SECLO), i('BNE','rel','rs_done'),
    i('INC','zp',SECHI),
    L('rs_done'),
    *([i('LDA','imm',0xC8), i('STA','abs',COLBK)] if DIAG else []),   # green = a read worked
    i('RTS','imp'),

    # ---- do_init: JSR (INITAD) — init code RTSes back to our caller ----
    L('do_init'),
    i('JMP','ind',INITAD),

    # ---- start ----
    L('start'),
    *([i('LDA','imm',0x34), i('STA','abs',COLBK)] if DIAG else []),   # red = got control
    i('LDA','imm','@FIRSTSEC'), i('STA','zp',SECLO),   # first .xex data sector
    i('LDA','imm',0), i('STA','zp',SECHI),
    i('LDA','imm','@REMLO'),  i('STA','zp',REMLO),     # remaining length (patched)
    i('LDA','imm','@REMMID'), i('STA','zp',REMMID),
    i('LDA','imm','@REMHI'),  i('STA','zp',REMHI),
    i('LDA','imm',128), i('STA','zp',BUFIDX),          # force buffer refill
    i('LDA','imm',1),   i('STA','zp',FIRSTF),

    # ---- segment loop ----
    L('nextseg'),
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','zp',SSTLO),
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','zp',SSTHI),
    # $FFFF separator? (both bytes $FF)
    i('LDA','zp',SSTLO), i('AND','zp',SSTHI), i('CMP','imm',0xFF),
    i('BEQ','rel','nextseg'),
    # segment end address
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','zp',ENDLO),
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','zp',ENDHI),
    # preset RUNAD := first segment start
    i('LDA','zp',FIRSTF), i('BEQ','rel','not_first'),
    i('LDA','imm',0), i('STA','zp',FIRSTF),
    i('LDA','zp',SSTLO), i('STA','abs',RUNAD),
    i('LDA','zp',SSTHI), i('STA','abs',RUNAD + 1),
    L('not_first'),
    # dst := start
    i('LDA','zp',SSTLO), i('STA','zp',DSTLO),
    i('LDA','zp',SSTHI), i('STA','zp',DSTHI),
    L('seg_store'),
    i('JSR','abs','getbyte'), i('BCS','rel','run'),
    i('LDY','imm',0), i('STA','indy',DSTLO),
    # dst == end ?
    i('LDA','zp',DSTLO), i('CMP','zp',ENDLO), i('BNE','rel','seg_inc'),
    i('LDA','zp',DSTHI), i('CMP','zp',ENDHI), i('BNE','rel','seg_inc'),
    # segment complete -> INITAD?
    i('JSR','abs','seg_has_init'), i('BCC','rel','nextseg'),
    i('JSR','abs','do_init'),
    i('JMP','abs','nextseg'),
    L('seg_inc'),
    i('INC','zp',DSTLO), i('BNE','rel','seg_store'),
    i('INC','zp',DSTHI), i('JMP','abs','seg_store'),

    L('run'),
    *([i('LDA','imm',0x84), i('STA','abs',COLBK),     # blue = parsed to RUNAD
       L('halt'), i('JMP','abs','halt')]              # freeze so the colour is visible
      if DIAG else
      [i('JMP','ind',RUNAD)]),

    # ---- seg_has_init: C=1 iff $02E2 lies within [SST..END] ----
    L('seg_has_init'),
    i('LDA','imm',INITAD & 0xFF), i('CMP','zp',SSTLO),     # $E2 - SSTLO
    i('LDA','imm',INITAD >> 8),   i('SBC','zp',SSTHI),     # 16-bit $02E2 - SST
    i('BCC','rel','shi_no'),                               # SST > $02E2
    i('LDA','zp',ENDLO), i('CMP','imm',INITAD & 0xFF),     # ENDLO - $E2
    i('LDA','zp',ENDHI), i('SBC','imm',INITAD >> 8),       # 16-bit END - $02E2
    i('BCC','rel','shi_no'),                               # END < $02E2
    i('SEC','imp'), i('RTS','imp'),
    L('shi_no'),
    i('CLC','imp'), i('RTS','imp'),
]

# seg_has_init uses CMP zp and SBC zp — add to table.
OPC[('CMP','zp')] = 0xC5
OPC[('SBC','zp')] = 0xE5

code, labels, patch = assemble(prog)

# Build-time constants: loader occupies whole 128-byte sectors.
BLDCNT = (len(code) + 127) // 128
FIRSTSEC = BLDCNT + 1
# Patch the build-time immediates now (REM stays a runtime patch in firmware).
code[patch['@BLDCNT']]   = BLDCNT
code[patch['@FIRSTSEC']] = FIRSTSEC

img = code + [0] * (BLDCNT * 128 - len(code))   # pad to whole sectors

with open('xex_loader.h', 'w') as f:
    f.write("// Generated by xex_loader.py - DO NOT EDIT.\n")
    f.write("// 6502 binary-load boot loader served as a virtual D1: disk.\n\n")
    f.write(f"#define XEX_BLDCNT     {BLDCNT}    // loader size in 128-byte sectors\n")
    f.write(f"#define XEX_FIRSTSEC   {FIRSTSEC}    // first sector carrying .xex bytes\n")
    f.write(f"#define XEX_IMG_SIZE   {len(img)}\n")
    f.write(f"#define XEX_REMLO_OFF  {patch['@REMLO']}    // patch offsets for the 24-bit\n")
    f.write(f"#define XEX_REMMID_OFF {patch['@REMMID']}    // remaining-byte length\n")
    f.write(f"#define XEX_REMHI_OFF  {patch['@REMHI']}\n\n")
    f.write("static unsigned char xex_loader_img[XEX_IMG_SIZE] = {\n")
    for r in range(0, len(img), 12):
        f.write("    " + ",".join(f"0x{x:02x}" for x in img[r:r+12]) + ",\n")
    f.write("};\n")

print(f"loader {len(code)} bytes, BLDCNT={BLDCNT}, FIRSTSEC={FIRSTSEC}, "
      f"REM offsets={patch['@REMLO']}/{patch['@REMMID']}/{patch['@REMHI']}")
