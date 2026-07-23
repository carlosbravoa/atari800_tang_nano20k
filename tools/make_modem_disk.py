#!/usr/bin/env python3
"""make_modem_disk.py — build a BobTerm boot disk that self-installs the R:
modem handler.

BobTerm needs a resident R: handler in HATABS (else "No modem handler!!"), but
its disk auto-launches BobTerm (AUTORUN.SYS) with no chance to load one first.
This appends our R: handler (r_handler.build_xex) as extra binary-load segments
to the disk's AUTORUN.SYS, with an INITAD ($02E2) that installs R: DURING load —
so R: is resident before BobTerm's RUNAD launches it. One disk, boots straight
into a working BobTerm; no firmware change, no reflash.

The append is safe surgery on a copy: the DOS 2.5 sector CHAIN is what the boot
loader follows, so we fill the file's last-sector slack, allocate free sectors
(found by scanning every file's chain, not the fiddly double VTOC), re-link, and
bump the directory count. VTOC2 is updated best-effort (irrelevant to a read-only
boot). The original ATR is never modified.

Usage:
  python3 tools/make_modem_disk.py IN.atr [OUT.atr]
  python3 tools/make_modem_disk.py    # defaults to the known BobTerm1.21.atr
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from r_handler import build_xex

SECSZ = 128
DIR_SECS = range(361, 369)
SYSTEM = {1, 2, 3, 360, 720, 1024} | set(DIR_SECS)


def sec_off(n):
    return 16 + (n - 1) * SECSZ


def walk_chain(d, start):
    chain, s, guard = [], start, 0
    while s and guard < 4000:
        guard += 1
        chain.append(s)
        o = sec_off(s)
        s = ((d[o + 125] & 0x03) << 8) | d[o + 126]
    return chain


def find_file(d, prefix):
    for di in range(64):
        s = 361 + di // 8
        e = sec_off(s) + (di % 8) * 16
        flag = d[e]
        if flag == 0 or flag & 0x80:
            continue
        name = d[e + 5:e + 13].decode('latin1').strip()
        if name.startswith(prefix):
            return di, (d[e + 3] | d[e + 4] << 8), (d[e + 1] | d[e + 2] << 8)
    return None


def free_sectors(d):
    used = set(SYSTEM)
    for di in range(64):
        s = 361 + di // 8
        e = sec_off(s) + (di % 8) * 16
        if d[e] == 0 or d[e] & 0x80:
            continue
        used |= set(walk_chain(d, d[e + 3] | d[e + 4] << 8))
    return [n for n in range(4, 1024) if n not in used]


def append_to_file(d, file_no, start, count, extra):
    """Append `extra` bytes to DOS-2.x file `file_no` (chain from `start`)."""
    chain = walk_chain(d, start)
    free = iter(free_sectors(d))
    data = bytearray(extra)
    added = 0

    # 1) fill the last existing sector's slack
    last = chain[-1]
    o = sec_off(last)
    used = d[o + 127]
    room = 125 - used
    take = min(room, len(data))
    d[o + used:o + used + take] = data[:take]
    d[o + 127] = used + take
    data = data[take:]

    prev = last
    # 2) allocate new sectors for the remainder
    while data:
        try:
            ns = next(free)
        except StopIteration:
            raise RuntimeError("no free sectors on the disk")
        po = sec_off(prev)
        d[po + 125] = (file_no << 2) | ((ns >> 8) & 0x03)   # prev -> ns
        d[po + 126] = ns & 0xFF
        no = sec_off(ns)
        chunk = data[:125]
        d[no:no + len(chunk)] = chunk
        for i in range(len(chunk), 125):
            d[no + i] = 0
        d[no + 125] = (file_no << 2)                        # next=0 for now
        d[no + 126] = 0
        d[no + 127] = len(chunk)
        data = data[125:]
        prev = ns
        added += 1
        _vtoc2_mark_used(d, ns)

    # 3) bump the directory sector count
    ds = 361 + file_no // 8
    de = sec_off(ds) + (file_no % 8) * 16
    newcount = count + added
    d[de + 1] = newcount & 0xFF
    d[de + 2] = newcount >> 8
    return added


def _vtoc2_mark_used(d, n):
    """DOS 2.5 VTOC2 (sector 1024): clear the free bit for sector n (720-1023)
    and decrement the free counter at bytes 122-123. Best-effort — a read-only
    boot never consults it."""
    v = sec_off(1024)
    if 720 <= n <= 1023:
        byte = 84 + (n - 720) // 8
        bit = 7 - (n - 720) % 8
        if d[v + byte] & (1 << bit):
            d[v + byte] &= ~(1 << bit) & 0xFF
            free = d[v + 122] | d[v + 123] << 8
            if free:
                free -= 1
                d[v + 122], d[v + 123] = free & 0xFF, free >> 8


def main():
    args = [a for a in sys.argv[1:]]
    default_in = os.path.expanduser(
        "~/Documents/atari tang nano/sd disk image/disks/dos/BobTerm1.21.atr")
    inp = args[0] if args else default_in
    if len(args) >= 2:
        outp = args[1]
    else:
        base, ext = os.path.splitext(inp)
        outp = base + "_Rmodem" + ext

    d = bytearray(open(inp, 'rb').read())
    f = find_file(d, "AUTORUN")
    if not f:
        sys.exit("no AUTORUN.SYS on this disk — is it a bootable BobTerm disk?")
    file_no, start, count = f

    xex, new_memlo = build_xex()
    added = append_to_file(d, file_no, start, count, xex)
    open(outp, 'wb').write(d)

    # verify: re-extract AUTORUN.SYS via the chain and confirm our tail is there
    chain = walk_chain(d, start)
    blob = bytearray()
    for s in chain:
        o = sec_off(s)
        blob += d[o:o + d[o + 127]]
    ok = bytes(blob[-len(xex):]) == xex
    print(f"appended R: handler ({len(xex)} B, +{added} sectors) to AUTORUN.SYS")
    print(f"  handler installs R: -> $2000, raises MEMLO to ${new_memlo:04X}")
    print(f"  chain now {len(chain)} sectors; tail verify: {'OK' if ok else 'FAILED'}")
    print(f"  wrote {outp}")
    if not ok:
        sys.exit("tail verify failed — NOT flashing this image")
    print("\nCopy this .atr to the SD card and boot it on D1: (with "
          "`atari_net.py --modem` running on the PC). BobTerm should now start "
          "with R: resident.")


if __name__ == '__main__':
    main()
