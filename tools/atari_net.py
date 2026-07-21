#!/usr/bin/env python3
"""atari_net.py — the Atari's network processor (PC side of the N: device).

The firmware relays the Atari's N: SIO traffic as framed events on the serial
link (0xA6 ev len16 payload sum8); this tool turns them into real sockets:

  OPEN "N:TCP://host:port/"  -> TCP connect     (ev 1)
  CLOSE                      -> disconnect      (ev 2)
  WRITE payload              -> socket send     (ev 3)
  socket data                -> NET_FEED (0x0B) into the firmware's ring
  connection state           -> NET_STATE (0x0C), read by the Atari's STATUS

Run it and leave it running (it owns the serial port, like `log` — firmware
log text passes through to stdout):    python3 tools/atari_net.py

The Processor core is transport-agnostic for offline testing
(tools/test_atari_net.py runs it against a mock serial + local echo server).
"""
import select
import socket
import sys
import time


class Processor:
    """Parses the FW->PC stream, drives sockets, feeds data back."""

    def __init__(self, ser_read, ser_write, log=print):
        self.r, self.w, self.log = ser_read, ser_write, log
        self.sock = None
        self.state = 0
        self.buf = b""
        self.fw_free = 511          # firmware ring free-space estimate
        self.pending = b""          # socket data waiting to be fed

    # ── stream parsing ───────────────────────────────────────────────────────
    def pump_serial(self, data):
        self.buf += data
        out_text = b""
        while self.buf:
            if self.buf[0] != 0xA6:
                out_text += self.buf[:1]
                self.buf = self.buf[1:]
                continue
            if len(self.buf) < 4:
                break
            ev, ll, lh = self.buf[1], self.buf[2], self.buf[3]
            need = 4 + (ll | (lh << 8)) + 1
            if len(self.buf) < need:
                break
            payload = self.buf[4:need - 1]
            sum_rx = self.buf[need - 1]
            calc = (ev + ll + lh + sum(payload)) & 0xFF
            if calc != sum_rx:
                self.log("[net] bad frame checksum — resyncing")
                self.buf = self.buf[1:]
                continue
            self.buf = self.buf[need:]
            self.handle_event(ev, payload)
        if out_text:
            try:
                text = out_text.decode("ascii", "replace")
                if text.strip():
                    sys.stdout.write(text)
                    sys.stdout.flush()
            except Exception:
                pass

    # ── events from the Atari ────────────────────────────────────────────────
    def handle_event(self, ev, payload):
        if ev == 1:                                    # OPEN devicespec
            spec = payload.split(b"\x00")[0].split(b"\x9b")[0] \
                          .decode("latin1").strip()
            self.log(f"[net] OPEN {spec!r}")
            self.close_socket()
            host, port = self.parse_spec(spec)
            if not host:
                self.set_state(2)
                return
            try:
                self.sock = socket.create_connection((host, port), timeout=10)
                self.sock.setblocking(False)
                self.set_state(1)
                self.log(f"[net] connected to {host}:{port}")
            except OSError as e:
                self.log(f"[net] connect failed: {e}")
                self.set_state(2)
        elif ev == 2:                                  # CLOSE
            self.log("[net] CLOSE")
            self.close_socket()
            self.set_state(0)
        elif ev == 3:                                  # DATA Atari -> net
            if self.sock:
                try:
                    self.sock.sendall(payload)
                except OSError as e:
                    self.log(f"[net] send failed: {e}")
                    self.close_socket()
                    self.set_state(2)

    @staticmethod
    def parse_spec(spec):
        """'N:TCP://host:port/' (N1:, TELNET aliases tolerated)."""
        s = spec.upper()
        for pre in ("N1:", "N2:", "N3:", "N4:", "N:"):
            if s.startswith(pre):
                s = s[len(pre):]
                break
        for scheme in ("TCP://", "TELNET://"):
            if s.startswith(scheme):
                rest = s[len(scheme):].rstrip("/")
                if ":" in rest:
                    host, port = rest.rsplit(":", 1)
                    try:
                        return host, int(port)
                    except ValueError:
                        return None, None
                return rest, 23
        return None, None

    # ── firmware feedback ────────────────────────────────────────────────────
    def set_state(self, st):
        self.state = st
        self.w(bytes([0x0C]))
        time.sleep(0.05)
        self.w(bytes([st]))
        self.expect(b"+", "state")

    def feed(self, data):
        """Push socket data into the firmware ring, paced by its free space."""
        self.pending += data
        while self.pending and self.fw_free > 0:
            chunk = self.pending[:min(128, self.fw_free)]
            self.w(bytes([0x0B]))
            time.sleep(0.05)
            self.w(len(chunk).to_bytes(2, "little") + chunk)
            r = self.expect(b"+\x15", "feed hdr")      # \x15 = NAK (ring full)
            if r != b"+":
                break                                  # ring full — retry later
            r = self.expect(b"K\x15", "feed end")
            if r != b"K":
                break
            free = self.r(1)
            self.fw_free = free[0] if free else 0
            self.pending = self.pending[len(chunk):]

    def expect(self, want, what, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            b = self.r(1)
            if b:
                if b in [bytes([c]) for c in want]:
                    return b
                self.pump_serial(b)                    # interleaved event/log
        self.log(f"[net] {what}: timeout")
        return b""

    def close_socket(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.pending = b""
        self.fw_free = 511

    # ── socket side ──────────────────────────────────────────────────────────
    def poll_socket(self):
        if not self.sock:
            return
        try:
            data = self.sock.recv(512)
            if data == b"":
                self.log("[net] remote closed")
                self.close_socket()
                self.set_state(0)
            elif data:
                self.feed(data)
        except BlockingIOError:
            if self.pending:
                self.feed(b"")                          # retry paced backlog
        except OSError as e:
            self.log(f"[net] recv failed: {e}")
            self.close_socket()
            self.set_state(2)


def main():
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from atari_link import AtariLink
    with AtariLink(timeout=0) as l:
        print(f"— network processor on {l.port} (Ctrl-C stops; logs pass through) —")
        p = Processor(lambda n: l.ser.read(n), lambda d: l.ser.write(d))
        try:
            while True:
                fds = [l.ser.fileno()] + ([p.sock.fileno()] if p.sock else [])
                r, _, _ = select.select(fds, [], [], 0.2)
                if l.ser.fileno() in r:
                    p.pump_serial(l.ser.read(4096))
                if p.sock and p.sock.fileno() in r:
                    p.poll_socket()
                elif p.pending:
                    p.poll_socket()
        except KeyboardInterrupt:
            p.close_socket()
            print("\n— stopped —")


if __name__ == "__main__":
    main()
