#!/usr/bin/env python3
"""atari.py — CLI for the Tang Nano 20K Atari PC Link (BL616 USB-C serial).

Usage:
  atari.py ports                     # list candidate serial ports
  atari.py log  [-p PORT]            # tail firmware logs (Ctrl-C to stop)
  atari.py ping [-p PORT]            # send ENQ, expect "A8OK" back
  atari.py send FILE [NAME] [-p P]   # copy FILE to the SD, default /PC/<name>;
                                     #   NAME may include folders: GAMES/X.ATR
  atari.py run  FILE.XEX [-p P]      # send + boot it (the make-run dev loop)
  atari.py type FILE|- [-p P]        # paste text as keystrokes (~18 chars/s;
                                     #   OSD must be closed)
  atari.py kbd [-p P]                # LIVE keyboard: type on the PC, it lands
                                     #   on the Atari; Ctrl-] exits
  atari.py eject [-p P]              # just eject the virtual .xex from D1:
  atari.py reset [--warm] [-p P]     # eject virtual .xex + cold boot (--warm =
                                     #   warm start; --keep = don't eject)
  atari.py status [-p P]             # firmware status line (boot stage, mounts,
                                     #   SIO counters, stack canary)
  atari.py screen [-p P]             # text dump of the Atari's screen (GR.0)
  atari.py peek ADDR [LEN] [-p P]    # hex dump of Atari memory (e.g. 0x58 16)
  atari.py fwpeek ADDR [LEN] [-p P]  # hex dump of FIRMWARE BSRAM (fw globals, debug)
  atari.py poke ADDR B [B...] [-p P] # write bytes into Atari memory
  atari.py hdd-install [-p P]        # install the H: handler (files -> /HDD
                                     #   on the SD); session-scoped

Protocol implementation lives in atari_link.py (shared with the desktop app,
atari_gui.py). Needs: pip install pyserial.
Linux: sudo modprobe ftdi_sio if no /dev/ttyUSB* appears.
"""
import argparse
import sys

from atari_link import (AtariLink, LinkError, MenuTakeover,
                        list_ports, sd_name, BAUD)


def _progress(name):
    def cb(done, total):
        pct = done * 100 // total
        if sys.stdout.isatty():
            sys.stdout.write(f"\r{name}: {done}/{total} bytes ({pct}%)")
            sys.stdout.flush()
        elif pct % 25 == 0:
            print(f"{name}: {pct}%")
    return cb


def cmd_ports(args):
    for p in list_ports():
        print(f"{p.device}  {p.description}  [{p.manufacturer or '?'}]")


def cmd_ping(args):
    with AtariLink(args.port) as l:
        if l.ping():
            print("A8OK — bridge is alive (both directions)")
        else:
            sys.exit("no reply — check the Atari is booted and the port is right")


def cmd_log(args):
    with AtariLink(args.port, timeout=0.5) as l:
        print(f"— tailing {l.port} @ {BAUD} (Ctrl-C to stop) —")
        try:
            while True:
                d = l.read_log()
                if d:
                    sys.stdout.write(d.decode("ascii", "replace"))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            print("\n— stopped —")


def cmd_send(args):
    data = open(args.file, "rb").read()
    if getattr(args, "text", False):
        # Atari INPUT needs ATASCII EOLs ($9B) — a raw \n text file reads as
        # one endless record (HW-hit during the H: bring-up).
        data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\x9b")
    name = sd_name(args.file, args.name)
    with AtariLink(args.port) as l:
        l.send(data, name, _progress(name))
    print(f"\nOK — /{name} on the SD card"
          + (" (ATASCII EOLs)" if getattr(args, "text", False) else ""))


def cmd_run(args):
    data = open(args.file, "rb").read()
    name = sd_name(args.file, args.name)
    with AtariLink(args.port) as l:
        l.run(data, name, _progress(name))
    print("\nbooting it on the Atari…")


def cmd_type(args):
    text = sys.stdin.read() if args.file == "-" else \
        open(args.file, "r", encoding="utf-8", errors="replace").read()
    with AtariLink(args.port) as l:
        l.type_text(text, _progress("typing"))
    print("\ndone — check the screen")


def cmd_kbd(args):
    import os
    import select
    import termios
    import tty
    print("live keyboard -> Atari  (Ctrl-] to exit; F12 on the Atari keyboard "
          "opens its menu and ends the session)")
    ended_by_menu = False
    with AtariLink(args.port) as l:
        sess = l.kbd_session()
        fd = sys.stdin.fileno()
        old_t = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            while True:
                r, _, _ = select.select([fd, l.ser.fileno()], [], [])
                try:
                    if l.ser.fileno() in r:
                        sess.poll_takeover()
                        continue
                    ch = os.read(fd, 1)
                    if ch == b"\x1d":          # Ctrl-]
                        break
                    sess.send_key(ch.decode("latin1"))
                except MenuTakeover:
                    ended_by_menu = True
                    break
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_t)
        sess.end()
    print("\nsession closed" +
          (" — OSD menu opened on the Atari" if ended_by_menu else ""))


def cmd_status(args):
    with AtariLink(args.port) as l:
        print(l.status())


def cmd_screen(args):
    with AtariLink(args.port) as l:
        print(l.screen())


def cmd_peek(args):
    addr = int(args.addr, 0)
    length = int(args.len, 0)
    with AtariLink(args.port) as l:
        data = l.peek(addr, length)
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        hexs = " ".join(f"{b:02x}" for b in row)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"{addr + off:04x}  {hexs:<48}  {text}")


def cmd_poke(args):
    addr = int(args.addr, 0)
    data = bytes(int(b, 0) for b in args.bytes)
    with AtariLink(args.port) as l:
        l.poke(addr, data)
    print(f"{len(data)} byte(s) written at {addr:#06x}")


def cmd_fwpeek(args):
    addr = int(args.addr, 0)
    length = int(args.len, 0)
    with AtariLink(args.port) as l:
        data = l.fwpeek(addr, length)
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        hexs = " ".join(f"{b:02x}" for b in row)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"{addr + off:04x}  {hexs:<48}  {text}")


def cmd_hdd_install(args):
    with AtariLink(args.port) as l:
        lo, hi = l.hdd_install()
    print(f"H: installed at ${lo:04X}-${hi - 1:04X}, MEMLO raised — "
          f'try OPEN #1,8,0,"H:HELLO.TXT" from BASIC '
          f"(files land in /HDD on the SD). RESET clears it; re-run to restore.")


def cmd_eject(args):
    with AtariLink(args.port) as l:
        l.eject()
    print("virtual .xex ejected from D1:")


def cmd_reset(args):
    with AtariLink(args.port) as l:
        l.reset(warm=args.warm, keep=args.keep)
    print("warm start requested" if args.warm else "cold boot requested")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, *extra):
        sp = sub.add_parser(name)
        for e in extra:
            e(sp)
        sp.add_argument("-p", "--port", default=None)
        sp.set_defaults(fn=fn)

    add("ports", cmd_ports)
    add("ping", cmd_ping)
    add("log", cmd_log)
    add("send", cmd_send, lambda sp: sp.add_argument("file"),
        lambda sp: sp.add_argument("name", nargs="?", default=None),
        lambda sp: sp.add_argument("--text", action="store_true",
                                   help="convert \\n line endings to ATASCII $9B"))
    add("run", cmd_run, lambda sp: sp.add_argument("file"),
        lambda sp: sp.add_argument("name", nargs="?", default=None))
    add("type", cmd_type,
        lambda sp: sp.add_argument("file", help="text file, or - for stdin"))
    add("kbd", cmd_kbd)
    add("eject", cmd_eject)
    add("hdd-install", cmd_hdd_install)
    add("status", cmd_status)
    add("screen", cmd_screen)
    add("peek", cmd_peek, lambda sp: sp.add_argument("addr"),
        lambda sp: sp.add_argument("len", nargs="?", default="64"))
    add("poke", cmd_poke, lambda sp: sp.add_argument("addr"),
        lambda sp: sp.add_argument("bytes", nargs="+"))
    add("fwpeek", cmd_fwpeek, lambda sp: sp.add_argument("addr"),
        lambda sp: sp.add_argument("len", nargs="?", default="64"))
    add("reset", cmd_reset,
        lambda sp: sp.add_argument("--warm", action="store_true"),
        lambda sp: sp.add_argument("--keep", action="store_true",
                                   help="don't eject the virtual .xex first"))

    args = ap.parse_args()
    try:
        args.fn(args)
    except LinkError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
