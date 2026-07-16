#!/usr/bin/env python3
"""atari.py — PC side of the Tang Nano 20K Atari serial bridge (BL616 USB-C CDC).

The board's own USB-C exposes a serial port (the BL616 bridges it to the FPGA).
Firmware logs stream out continuously; `ping` proves the PC->firmware direction.

Usage:
  atari.py ports                # list candidate serial ports
  atari.py log  [-p PORT]       # tail firmware logs (Ctrl-C to stop)
  atari.py ping [-p PORT]       # send ENQ, expect "A8OK" back

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


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("ports", cmd_ports), ("log", cmd_log), ("ping", cmd_ping)):
        sp = sub.add_parser(name)
        sp.add_argument("-p", "--port", default=None)
        sp.set_defaults(fn=fn)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
