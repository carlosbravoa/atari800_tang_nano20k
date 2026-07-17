#!/usr/bin/env python3
"""atari.py — PC side of the Tang Nano 20K Atari serial bridge (BL616 USB-C CDC).

The board's own USB-C exposes a serial port (the BL616 bridges it to the FPGA).
Firmware logs stream out continuously; `ping` proves the PC->firmware direction.

Usage:
  atari.py ports                     # list candidate serial ports
  atari.py log  [-p PORT]            # tail firmware logs (Ctrl-C to stop)
  atari.py ping [-p PORT]            # send ENQ, expect "A8OK" back
  atari.py send FILE [NAME] [-p P]   # copy FILE to the SD root (default: same name)
  atari.py run  FILE.XEX [-p P]      # send + boot it (the make-run dev loop)
  atari.py reset [--warm] [-p P]     # cold boot (or warm start with --warm)

Protocol (firmware bridge v1): single-byte commands. PUT = 0x01 nlen name
size32LE, '+' ack, raw 256-byte chunks each ack'd '+', then sum16LE -> 'K'/'E'.
RUN = 0x02 nlen name. COLD/WARM = 0x03/0x04.

Needs: pip install pyserial. Baud is fixed at 115200 (firmware side is fixed).
Close this tool before using the Gowin programmer, just in case the interfaces
share more than expected (they shouldn't - JTAG is separate).
"""
import argparse
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("pyserial required:  pip install pyserial")

BAUD = 115200


def find_port(explicit):
    if explicit:
        return explicit
    cands = sorted(serial.tools.list_ports.comports(), key=lambda p: p.device)
    if not cands:
        sys.exit("No serial ports found — is the board connected?")
    if len(cands) == 1:
        return cands[0].device
    # The BL616 enumerates FT2232-style: two ports with the same VID:PID —
    # interface 0 = JTAG, interface 1 = the UART. Pick the SECOND of a pair.
    for i in range(len(cands) - 1):
        a, b = cands[i], cands[i + 1]
        if (a.vid, a.pid) == (b.vid, b.pid) and a.vid is not None:
            return b.device
    for p in cands:
        text = f"{p.description} {p.manufacturer or ''}".lower()
        if any(k in text for k in ("sipeed", "bl616", "jtag", "debug", "serial")):
            return p.device
    listing = "\n".join(f"  {p.device}  {p.description}" for p in cands)
    sys.exit("Can't auto-pick a port — use -p. Candidates:\n" + listing)


def cmd_ports(_):
    for p in serial.tools.list_ports.comports():
        print(f"{p.device}  {p.description}  [{p.manufacturer or '?'}]")


def cmd_log(args):
    port = find_port(args.port)
    print(f"— tailing {port} @ {BAUD} (Ctrl-C to stop) —")
    with serial.Serial(port, BAUD, timeout=0.5) as s:
        try:
            while True:
                data = s.read(4096)
                if data:
                    sys.stdout.write(data.decode("ascii", "replace"))
                    sys.stdout.flush()
        except KeyboardInterrupt:
            print("\n— stopped —")


def cmd_ping(args):
    port = find_port(args.port)
    with serial.Serial(port, BAUD, timeout=2) as s:
        s.reset_input_buffer()
        s.write(b"\x05")               # ENQ
        deadline = time.time() + 2
        buf = b""
        while time.time() < deadline:
            buf += s.read(64)
            if b"A8OK" in buf:
                print("A8OK — bridge is alive (both directions)")
                return
        sys.exit(f"no reply (got {buf!r}) — check the Atari is booted and the "
                 f"port is right; firmware logs should appear with 'atari.py log'")


def _expect(s, want, what, timeout=3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = s.read(1)
        if b:
            if b in want:
                return b
            sys.exit(f"{what}: unexpected reply {b!r}")
    sys.exit(f"{what}: timeout")


def _sd_name(path, override):
    import os
    name = override or os.path.basename(path)
    name = name.upper()
    if len(name) > 31:
        sys.exit(f"name too long for the bridge: {name}")
    return name


def _put(s, data, name):
    s.reset_input_buffer()
    s.write(bytes([0x01, len(name)]) + name.encode("ascii") +
            len(data).to_bytes(4, "little"))
    _expect(s, b"+", "open")
    sent = 0
    while sent < len(data):
        chunk = data[sent:sent + 256]
        s.write(chunk)
        _expect(s, b"+", f"chunk @{sent}", timeout=5)
        sent += len(chunk)
        pct = sent * 100 // len(data)
        sys.stdout.write(f"\r{name}: {sent}/{len(data)} bytes ({pct}%)")
        sys.stdout.flush()
    s.write((sum(data) & 0xFFFF).to_bytes(2, "little"))
    r = _expect(s, b"KE", "checksum")
    print()
    if r == b"E":
        sys.exit("checksum mismatch — file deleted on the Atari side, retry")
    print(f"OK — /{name} on the SD card")


def cmd_send(args):
    data = open(args.file, "rb").read()
    name = _sd_name(args.file, args.name)
    with serial.Serial(find_port(args.port), BAUD, timeout=1) as s:
        _put(s, data, name)


def cmd_run(args):
    data = open(args.file, "rb").read()
    if data[:2] != b"\xff\xff":
        sys.exit("not a .xex (missing $FFFF header) — refusing to boot it")
    name = _sd_name(args.file, args.name)
    with serial.Serial(find_port(args.port), BAUD, timeout=1) as s:
        _put(s, data, name)
        s.write(bytes([0x02, len(name)]) + name.encode("ascii"))
        _expect(s, b"+", "run")
        print("booting it on the Atari…")


def cmd_reset(args):
    with serial.Serial(find_port(args.port), BAUD, timeout=1) as s:
        s.reset_input_buffer()
        s.write(b"\x04" if args.warm else b"\x03")
        _expect(s, b"+", "reset")
        print("warm start requested" if args.warm else "cold boot requested")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("ports", cmd_ports), ("log", cmd_log), ("ping", cmd_ping)):
        sp = sub.add_parser(name)
        sp.add_argument("-p", "--port", default=None)
        sp.set_defaults(fn=fn)
    sp = sub.add_parser("send")
    sp.add_argument("file"); sp.add_argument("name", nargs="?", default=None)
    sp.add_argument("-p", "--port", default=None); sp.set_defaults(fn=cmd_send)
    sp = sub.add_parser("run")
    sp.add_argument("file"); sp.add_argument("name", nargs="?", default=None)
    sp.add_argument("-p", "--port", default=None); sp.set_defaults(fn=cmd_run)
    sp = sub.add_parser("reset")
    sp.add_argument("--warm", action="store_true")
    sp.add_argument("-p", "--port", default=None); sp.set_defaults(fn=cmd_reset)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
