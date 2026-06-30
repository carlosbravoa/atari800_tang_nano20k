#!/usr/bin/env python3
# Assembles the 6502 XEX boot loader and emits firmware/xex_loader.h
#
# The firmware serves this loader as a *virtual bootable disk* on D1:. The Atari
# OS disk-boot reads sectors 1..BLDCNT into RAM at $0700 and JSRs $0706 (load+6).
# From there the loader pulls the remaining disk sectors (the raw .xex file
# bytes, 128/sector from FIRSTSEC) via SIOV and processes the binary-load format:
#   - leading $FFFF header / optional $FFFF segment separators
#   - per-segment start/end address words followed by that many data bytes
#   - INITAD ($02E2/3): JSR (INITAD) after a segment whose range includes $02E2
#   - RUNAD  ($02E0/1): JMP (RUNAD) at EOF (preset to the first segment's start
#                       so files without an explicit RUNAD still auto-run)
# End-of-file is an exact byte counter (REM) the firmware patches in per file.
#
# v2 (compatibility rewrite): the loader keeps ZERO state in zero page and its
# sector buffer OFF page 6. v1 kept 13 pointers in ZP $CB-$D7 and the buffer in
# page 6 ($0600); any .xex whose segments loaded into high zero page (very common
# ML init, e.g. $80-$FF) or page 6 corrupted the running loader -> "works for
# some, fails for many". v2 holds ALL state in absolute memory inside the loader
# image and stores bytes via SELF-MODIFYING `STA abs` (no (zp),Y is needed), so
# its only RAM footprint is the contiguous loader block at $0700.., which
# DOS-format files already avoid. Validated in py65 (see the failure matrix):
# zero-page and page-6 collisions fixed; INITAD/RUNAD semantics unchanged.
#   Limitation that remains: a .xex loading into the loader block itself
#   ($0700..$08FF) would overwrite the running loader -- but DOS-format binaries
#   reserve that low region anyway.
#
# Run:  python3 xex_loader.py   (regenerates xex_loader.h)

import sys
LOAD = 0x0700

# Diagnostic build: paint COLBK at milestones and halt at RUNAD (TX is unwired).
DIAG  = False
COLBK = 0x02C8

SIOV   = 0xE459
RUNAD  = 0x02E0
INITAD = 0x02E2

# ---- minimal 2-pass assembler (now uses absolute, not zero-page, for state) ---
OPC = {
    ('LDA','imm'):0xA9, ('LDA','zp'):0xA5, ('LDA','abs'):0xAD, ('LDA','absx'):0xBD,
    ('STA','abs'):0x8D,
    ('TAX','imp'):0xAA, ('INX','imp'):0xE8,
    ('INC','abs'):0xEE, ('DEC','abs'):0xCE,
    ('CMP','imm'):0xC9, ('CMP','abs'):0xCD,
    ('AND','abs'):0x2D, ('ORA','abs'):0x0D,
    ('SBC','imm'):0xE9, ('SBC','abs'):0xED,
    ('SEC','imp'):0x38, ('CLC','imp'):0x18,
    ('BNE','rel'):0xD0, ('BEQ','rel'):0xF0, ('BCC','rel'):0x90, ('BCS','rel'):0xB0,
    ('JMP','abs'):0x4C, ('JMP','ind'):0x6C, ('JSR','abs'):0x20, ('RTS','imp'):0x60,
    ('LDY','imm'):0xA0,
}
SIZE = {'imp':1,'imm':2,'zp':2,'absx':3,'abs':3,'ind':3,'indy':2,'rel':2,'byte':1,'word':2}

def assemble(prog):
    labels, pc = {}, LOAD
    for it in prog:                                  # pass 1: resolve labels
        if it[0] == 'label': labels[it[1]] = pc
        else: pc += SIZE[it[1]]
    def v(o):
        if isinstance(o, str):
            if o.startswith('@'): return 0           # firmware-patched immediate
            if '+' in o:                             # label+offset (self-mod operands)
                base, off = o.split('+'); return labels[base] + int(off)
            return labels[o]
        return o
    out, pc, patch = [], LOAD, {}
    for it in prog:                                  # pass 2: encode
        if it[0] == 'label': continue
        mnem, mode, opnd = it
        if mode == 'byte':   out.append(v(opnd) & 0xFF)
        elif mode == 'word': x=v(opnd); out += [x&0xFF,(x>>8)&0xFF]
        else:
            op = OPC[(mnem,mode)]
            if mode == 'imp': out.append(op)
            elif mode in ('imm','zp','indy'): out += [op, v(opnd)&0xFF]
            elif mode in ('abs','absx','ind'): x=v(opnd); out += [op, x&0xFF, (x>>8)&0xFF]
            elif mode == 'rel':
                rel = v(opnd) - (pc+2)
                assert -128 <= rel <= 127, f"branch out of range -> {opnd}: {rel}"
                out += [op, rel & 0xFF]
        if isinstance(opnd,str) and opnd.startswith('@'):
            patch[opnd] = len(out)-1
        pc += SIZE[mode]
    return out, labels, patch

def b(x):  return ('?','byte',x)
def w(x):  return ('?','word',x)
def i(m,mode,o=None): return (m,mode,o)
L = lambda n: ('label', n)

prog = [
    # ---- boot header (offset 0..5) ----
    b(0x00), b('@BLDCNT'), w(LOAD), w('boot6'),
    L('boot6'),
    i('JMP','abs','start'),                          # OS JSRs here after loading

    # ---- getbyte: A=next stream byte, C=1 on EOF. clobbers A,X ----
    L('getbyte'),
    i('LDA','abs','REMLO'), i('ORA','abs','REMMID'), i('ORA','abs','REMHI'),
    i('BNE','rel','gb_ok'),
    i('SEC','imp'), i('RTS','imp'),
    L('gb_ok'),
    i('LDA','abs','REMLO'), i('SEC','imp'), i('SBC','imm',1), i('STA','abs','REMLO'),
    i('LDA','abs','REMMID'), i('SBC','imm',0), i('STA','abs','REMMID'),
    i('LDA','abs','REMHI'), i('SBC','imm',0), i('STA','abs','REMHI'),
    i('LDA','abs','BUFIDX'), i('CMP','imm',128), i('BCC','rel','gb_have'),
    i('JSR','abs','readsec'),
    i('LDA','imm',0), i('STA','abs','BUFIDX'),
    L('gb_have'),
    i('LDA','abs','BUFIDX'), i('TAX','imp'),
    i('INC','abs','BUFIDX'),
    i('LDA','absx','BUF'),
    i('CLC','imp'), i('RTS','imp'),

    # ---- readsec: read sector SECLO/HI into BUF via SIOV; inc sector ----
    L('readsec'),
    i('LDA','imm',0x31), i('STA','abs',0x0300),       # DDEVIC = $31 (D:)
    i('LDA','imm',0x01), i('STA','abs',0x0301),       # DUNIT  = 1
    i('LDA','imm',0x52), i('STA','abs',0x0302),       # DCOMND = read
    i('LDA','imm',0x40), i('STA','abs',0x0303),       # DSTATS = read direction
    i('LDA','imm','@BUFLO'), i('STA','abs',0x0304),   # DBUFLO (patched: BUF & FF)
    i('LDA','imm','@BUFHI'), i('STA','abs',0x0305),   # DBUFHI (patched: BUF >> 8)
    i('LDA','imm',0x1F), i('STA','abs',0x0306),       # DTIMLO
    i('LDA','imm',0x80), i('STA','abs',0x0308),       # DBYTLO = 128
    i('LDA','imm',0x00), i('STA','abs',0x0309),       # DBYTHI
    i('LDA','abs','SECLO'), i('STA','abs',0x030A),    # DAUX1
    i('LDA','abs','SECHI'), i('STA','abs',0x030B),    # DAUX2
    i('JSR','abs',SIOV),
    i('INC','abs','SECLO'), i('BNE','rel','rs_done'),
    i('INC','abs','SECHI'),
    L('rs_done'),
    *([i('LDA','imm',0xC8), i('STA','abs',COLBK)] if DIAG else []),
    i('RTS','imp'),

    # ---- do_init: JSR (INITAD) — init code RTSes back to our caller ----
    L('do_init'),
    i('JMP','ind',INITAD),

    # ---- start ----
    L('start'),
    *([i('LDA','imm',0x34), i('STA','abs',COLBK)] if DIAG else []),
    i('LDA','imm','@FIRSTSEC'), i('STA','abs','SECLO'),
    i('LDA','imm',0), i('STA','abs','SECHI'),
    i('LDA','imm','@REMLO'),  i('STA','abs','REMLO'),
    i('LDA','imm','@REMMID'), i('STA','abs','REMMID'),
    i('LDA','imm','@REMHI'),  i('STA','abs','REMHI'),
    i('LDA','imm',128), i('STA','abs','BUFIDX'),       # force buffer refill
    i('LDA','imm',1),   i('STA','abs','FIRSTF'),

    # ---- segment loop ----
    L('nextseg'),
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','abs','SSTLO'),
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','abs','SSTHI'),
    # $FFFF separator? (both bytes $FF)
    i('LDA','abs','SSTLO'), i('AND','abs','SSTHI'), i('CMP','imm',0xFF),
    i('BEQ','rel','nextseg'),
    # segment end address
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','abs','ENDLO'),
    i('JSR','abs','getbyte'), i('BCS','rel','run'), i('STA','abs','ENDHI'),
    # preset RUNAD := first segment start
    i('LDA','abs','FIRSTF'), i('BEQ','rel','not_first'),
    i('LDA','imm',0), i('STA','abs','FIRSTF'),
    i('LDA','abs','SSTLO'), i('STA','abs',RUNAD),
    i('LDA','abs','SSTHI'), i('STA','abs',RUNAD+1),
    L('not_first'),
    # self-modifying store pointer := segment start
    i('LDA','abs','SSTLO'), i('STA','abs','store_op+1'),
    i('LDA','abs','SSTHI'), i('STA','abs','store_op+2'),
    L('seg_store'),
    i('JSR','abs','getbyte'), i('BCS','rel','run'),
    L('store_op'),
    i('STA','abs',0x0000),                            # operand self-modified to dst
    # dst == end ?
    i('LDA','abs','store_op+1'), i('CMP','abs','ENDLO'), i('BNE','rel','seg_inc'),
    i('LDA','abs','store_op+2'), i('CMP','abs','ENDHI'), i('BNE','rel','seg_inc'),
    # segment complete -> INITAD?
    i('JSR','abs','seg_has_init'), i('BCC','rel','nextseg'),
    i('JSR','abs','do_init'),
    i('JMP','abs','nextseg'),
    L('seg_inc'),
    i('INC','abs','store_op+1'), i('BNE','rel','seg_store'),
    i('INC','abs','store_op+2'), i('JMP','abs','seg_store'),

    L('run'),
    *([i('LDA','imm',0x84), i('STA','abs',COLBK), L('halt'), i('JMP','abs','halt')]
      if DIAG else [i('JMP','ind',RUNAD)]),

    # ---- seg_has_init: C=1 iff $02E2 lies within [SST..END] ----
    L('seg_has_init'),
    i('LDA','imm',INITAD & 0xFF), i('CMP','abs','SSTLO'),
    i('LDA','imm',INITAD >> 8),   i('SBC','abs','SSTHI'),
    i('BCC','rel','shi_no'),
    i('LDA','abs','ENDLO'), i('CMP','imm',INITAD & 0xFF),
    i('LDA','abs','ENDHI'), i('SBC','imm',INITAD >> 8),
    i('BCC','rel','shi_no'),
    i('SEC','imp'), i('RTS','imp'),
    L('shi_no'),
    i('CLC','imp'), i('RTS','imp'),

    # ---- absolute working state (was ZP $CB-$D7 in v1) ----
    L('BUFIDX'), b(0),
    L('SECLO'),  b(0), L('SECHI'), b(0),
    L('REMLO'),  b(0), L('REMMID'),b(0), L('REMHI'), b(0),
    L('ENDLO'),  b(0), L('ENDHI'), b(0),
    L('SSTLO'),  b(0), L('SSTHI'), b(0),
    L('FIRSTF'), b(0),

    # ---- 128-byte sector buffer, inside the loader image (off page 6) ----
    L('BUF'),
    *[b(0) for _ in range(128)],
]

code, labels, patch = assemble(prog)

# Build-time constants. Buffer + state live inside the loaded image.
BUF_ADDR = labels['BUF']
BLDCNT   = (len(code) + 127) // 128
FIRSTSEC = BLDCNT + 1
code[patch['@BLDCNT']]   = BLDCNT
code[patch['@FIRSTSEC']] = FIRSTSEC
code[patch['@BUFLO']]    = BUF_ADDR & 0xFF
code[patch['@BUFHI']]    = (BUF_ADDR >> 8) & 0xFF

img = code + [0] * (BLDCNT * 128 - len(code))         # pad to whole sectors

out = sys.argv[1] if len(sys.argv) > 1 else "xex_loader.h"
with open(out, 'w') as f:
    f.write("// Generated by xex_loader.py - DO NOT EDIT.\n")
    f.write("// 6502 binary-load boot loader served as a virtual D1: disk (v2: no ZP, buffer off page 6).\n\n")
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

print(f"loader {len(code)} bytes, BLDCNT={BLDCNT}, FIRSTSEC={FIRSTSEC}, BUF=${BUF_ADDR:04X}, "
      f"REM offsets={patch['@REMLO']}/{patch['@REMMID']}/{patch['@REMHI']}")
