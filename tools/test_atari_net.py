#!/usr/bin/env python3
"""Loopback simulation of the N: network path (PC half + a firmware mock).

MockFirmware implements the firmware's serial behavior (0x0B feed / 0x0C state
commands, 512-byte ring) in python; the Processor runs against it exactly as it
would against the real port; a local echo server plays "the internet".

Round trip proven offline:
  Atari OPEN event -> Processor connects -> Atari DATA event -> socket ->
  echo -> Processor feeds -> mock ring receives the same bytes.

Run: python3 tools/test_atari_net.py
"""
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from atari_net import Processor

fails = 0


def check(label, cond, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + (f"  {extra}" if extra else ""))
    if not cond:
        fails += 1


class MockFirmware:
    """The firmware's side of the wire: consumes 0x0B/0x0C, produces events."""

    def __init__(self):
        self.to_pc = b""       # firmware -> PC bytes (events, acks)
        self.ring = b""        # NET_FEED destination
        self.state = None
        self.cmd = b""         # PC -> firmware bytes being parsed

    # wire from the Processor's perspective
    def read(self, n):
        d, self.to_pc = self.to_pc[:n], self.to_pc[n:]
        return d

    def write(self, data):
        self.cmd += data
        self._consume()

    def _consume(self):
        while self.cmd:
            op = self.cmd[0]
            if op == 0x0C:
                if len(self.cmd) < 2:
                    return
                self.state = self.cmd[1]
                self.cmd = self.cmd[2:]
                self.to_pc += b"+"
            elif op == 0x0B:
                if len(self.cmd) < 3:
                    return
                ln = self.cmd[1] | (self.cmd[2] << 8)
                if len(self.cmd) < 3 + ln:
                    return
                free = 511 - len(self.ring)
                if ln > free:
                    self.cmd = self.cmd[3 + ln:]
                    self.to_pc += b"\x15"          # NAK (ring full) — was '-'
                    continue
                self.to_pc += b"+"
                self.ring += self.cmd[3:3 + ln]
                self.cmd = self.cmd[3 + ln:]
                self.to_pc += b"K" + bytes([min(255, 511 - len(self.ring))])
            else:
                self.cmd = self.cmd[1:]

    def emit_event(self, ev, payload=b""):
        ln = len(payload)
        sum8 = (ev + (ln & 0xFF) + (ln >> 8) + sum(payload)) & 0xFF
        self.to_pc += bytes([0xA6, ev, ln & 0xFF, ln >> 8]) + payload + bytes([sum8])


def main():
    # "the internet": a local echo server
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    def echo():
        c, _ = srv.accept()
        while True:
            d = c.recv(256)
            if not d:
                break
            c.sendall(d.upper())     # transform so we know it went through
        c.close()

    threading.Thread(target=echo, daemon=True).start()

    fw = MockFirmware()
    logs = []
    p = Processor(fw.read, fw.write, log=logs.append)

    # frame parser: log text passes through, bad checksum resyncs
    fw.to_pc += b"boot: running\n"
    bad = bytes([0xA6, 3, 1, 0, 65, 0x00])              # wrong sum
    fw.to_pc += bad
    fw.emit_event(2)                                     # valid CLOSE after junk
    p.pump_serial(fw.read(4096))
    check("resync after bad frame", any("resync" in l for l in logs))

    # OPEN -> real connect
    spec = f"N:TCP://127.0.0.1:{port}/".encode() + b"\x9b" + bytes(20)
    fw.emit_event(1, spec.ljust(64, b"\x00"))
    p.pump_serial(fw.read(4096))
    check("open connects", p.sock is not None and fw.state == 1,
          f"state={fw.state}")

    # DATA Atari->net, echo comes back, Processor feeds the ring
    fw.emit_event(3, b"hello atari")
    p.pump_serial(fw.read(4096))
    deadline = time.time() + 3
    while time.time() < deadline and fw.ring != b"HELLO ATARI":
        p.poll_socket()
        time.sleep(0.02)
    check("round trip via echo", fw.ring == b"HELLO ATARI", f"ring={fw.ring!r}")

    # ring backpressure: feed 1500 bytes, ring caps at 511, backlog retried
    fw.ring = b""
    big = bytes(range(256)) * 6                          # 1536 bytes
    p.feed(big)
    check("backpressure holds", len(fw.ring) <= 511 and len(p.pending) > 0,
          f"ring={len(fw.ring)} pending={len(p.pending)}")
    # drain: consume the ring (as the Atari would) and let it retry
    got = fw.ring
    fw.ring = b""
    p.fw_free = 511
    p.feed(b"")
    got += fw.ring
    check("backlog delivered in order", big.startswith(got) and len(got) > 511,
          f"got={len(got)}")

    # CLOSE
    fw.emit_event(2)
    p.pump_serial(fw.read(4096))
    check("close", p.sock is None and fw.state == 0)

    # devicespec parsing corner cases
    check("spec parse", Processor.parse_spec("N:TCP://BBS.FOZZTEXX.COM:23/")
          == ("BBS.FOZZTEXX.COM", 23))
    check("spec telnet default port",
          Processor.parse_spec("N1:TELNET://EXAMPLE.COM/") == ("EXAMPLE.COM", 23))
    check("spec junk rejected", Processor.parse_spec("D:GAME.ATR") == (None, None))

    print(f"\n{'ALL GREEN' if fails == 0 else f'{fails} FAILURES'}")
    return fails


if __name__ == "__main__":
    sys.exit(main())
