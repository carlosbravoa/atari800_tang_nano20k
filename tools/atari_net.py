#!/usr/bin/env python3
"""atari_net.py — the Atari's network processor (PC side of N: and the R: modem).

The firmware relays the Atari's SIO traffic as framed events on the serial link
(0xA6 ev len16 payload sum8); this tool turns them into real sockets. Two
personalities share the same transport (0xA6 events in, NET_FEED 0x0B / NET_STATE
0x0C out) but answer different SIO devices:

  N:  network device (0x71) — default. FujiNet-style; the Atari OPENs a
      devicespec and READs/WRITEs framed chunks:
        OPEN "N:TCP://host:port/"  -> TCP connect   (ev 1)
        CLOSE                      -> disconnect     (ev 2)
        WRITE payload              -> socket send    (ev 3)
        socket data                -> NET_FEED into the firmware ring
        connection state           -> NET_STATE, read by the Atari's STATUS

  R1: modem device (0x50) — run with `--modem`. 850-style modem for classic
      terminals (BobTerm). The firmware enters CONCURRENT mode on the SIO 'X'
      command and relays the raw byte stream; this side runs the Hayes-AT
      personality (ATDT dials) + a minimal telnet IAC responder:
        MODEM_CONFIG baud          (ev 0x0F) -> reset modem state
        STREAM_START baud          (ev 0x10) -> concurrent mode active
        STREAM_DATA bytes          (ev 0x11) -> AT parser (cmd mode) / socket (online)
        HANGUP                     (ev 0x12) -> drop the connection (DTR fell)
        STREAM_END                 (ev 0x13) -> concurrent paused (STATUS poll)
        socket / AT result codes   -> NET_FEED into the firmware ring

Run it and leave it running (it owns the serial port, like `log` — firmware log
text passes through to stdout):
    python3 tools/atari_net.py            # N: network processor
    python3 tools/atari_net.py --modem    # R: modem (for BobTerm)

The core classes are transport-agnostic for offline testing
(tools/test_atari_net.py runs them against a mock serial + local server).
"""
import select
import socket
import sys
import time


class LinkPeer:
    """Shared FW<->PC plumbing: 0xA6 event parsing in, NET_FEED/NET_STATE out.

    Subclasses implement handle_event() and poll_socket()."""

    def __init__(self, ser_read, ser_write, log=print):
        self.r, self.w, self.log = ser_read, ser_write, log
        self.sock = None
        self.state = 0
        self.buf = b""
        self.fw_free = 511          # firmware ring free-space estimate
        self.pending = b""          # data waiting to be fed into the ring

    # ── stream parsing (FW -> PC) ────────────────────────────────────────────
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

    def handle_event(self, ev, payload):
        raise NotImplementedError

    # ── firmware feedback (PC -> FW) ─────────────────────────────────────────
    def set_state(self, st):
        self.state = st
        self.w(bytes([0x0C]))
        time.sleep(0.05)
        self.w(bytes([st]))
        self.expect(b"+", "state")

    def feed(self, data):
        """Push bytes into the firmware ring, paced by its free space."""
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


class Processor(LinkPeer):
    """N: network device — devicespec OPEN + framed READ/WRITE."""

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


# Telnet control bytes (RFC 854) for the minimal IAC responder.
IAC, DONT, DO, WONT, WILL, SB, SE = 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF0

# CONFIGURE baud codes (AUX1[3:0]) -> bits-per-second. Matches FujiNet modem.cpp
# and the firmware's modem_baud_tbl. Only 9600/19200 are TX-capable on the board
# (8-bit SIO divisor); lower codes still report a baud for the CONNECT string.
BAUD_CODES = {0x8: 300, 0x9: 600, 0xA: 1200, 0xB: 1800,
              0xC: 2400, 0xD: 4800, 0xE: 9600, 0xF: 19200}


class Modem(LinkPeer):
    """R: 850-style modem — Hayes AT command set + minimal telnet, for BobTerm.

    In command mode the Atari's keystrokes are parsed as AT commands (ATDT dials
    a telnet BBS); once connected we go 'online' and shuttle raw bytes both ways,
    stripping/answering telnet IAC negotiation so it doesn't garbage the screen.
    '+++' (with a guard time) returns to command mode without dropping the line.
    """

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.cmd_mode = True
        self.echo = True                 # ATE1 default (modem echoes in cmd mode)
        self.telnet = True               # ATNET1 default (handle IAC)
        self.baud = 19200
        self.atbuf = b""                 # accumulating AT command line
        self.last_rx = 0.0               # time of last Atari byte (for +++ guard)
        self.plus_count = 0              # consecutive '+' seen for the escape
        self.plus_armed = 0.0            # time the +++ sequence completed
        self._iac = b""                  # partial IAC sequence across recv()s

    # ── events from the Atari ────────────────────────────────────────────────
    def handle_event(self, ev, payload):
        if ev == 0x0F:                                 # MODEM_CONFIG (CONFIGURE)
            if payload:
                self.baud = BAUD_CODES.get(payload[0], 19200)
            self.log(f"[modem] configure {self.baud} baud")
            self.close_socket()
            self.cmd_mode = True
            self.atbuf = b""
        elif ev == 0x10:                               # STREAM_START (concurrent on)
            if payload:
                self.baud = BAUD_CODES.get(payload[0], self.baud)
            self.log(f"[modem] stream @ {self.baud} baud "
                     f"({'online' if not self.cmd_mode else 'command'})")
        elif ev == 0x11:                               # STREAM_DATA (Atari -> modem)
            self.on_atari_bytes(payload)
        elif ev == 0x12:                               # HANGUP (DTR dropped)
            if self.sock:
                self.log("[modem] DTR hangup")
                self.close_socket()
            self.cmd_mode = True
            self.reply("NO CARRIER")
        elif ev == 0x13:                               # STREAM_END (concurrent paused)
            pass                                        # keep socket + mode

    # ── Atari byte stream ────────────────────────────────────────────────────
    def on_atari_bytes(self, data):
        now = time.time()
        if self.cmd_mode:
            for b in data:
                self._at_byte(b)
        else:
            # Online: watch for the '+++' escape (Hayes guard time ~1 s of idle
            # before and after). Anything else flows to the socket.
            if data == b"+" * len(data) and all(c == 0x2B for c in data):
                if now - self.last_rx > 1.0 or self.plus_count:
                    self.plus_count += len(data)
                    if self.plus_count >= 3:
                        self.plus_armed = now
                    self.last_rx = now
                    return
            self.plus_count = 0
            self._socket_send(data)
        self.last_rx = now

    def _at_byte(self, b):
        if b in (0x0D, 0x9B):                           # CR or ATASCII EOL
            line, self.atbuf = self.atbuf, b""
            self.process_at(line)
        elif b in (0x7F, 0x08, 0x9C):                   # backspace / delete
            self.atbuf = self.atbuf[:-1]
            if self.echo:
                self.feed(bytes([b]))
        else:
            self.atbuf += bytes([b])
            if self.echo:
                self.feed(bytes([b]))

    def process_at(self, line):
        s = line.decode("latin1", "replace").strip()
        if not s:
            return
        up = s.upper()
        if not up.startswith("AT"):
            self.reply("ERROR")
            return
        body = s[2:]                                    # after "AT"
        ub = up[2:]
        self.log(f"[modem] AT: {s!r}")
        if ub.startswith("DT") or ub.startswith("DP") or \
           ub.startswith("DI") or ub.startswith("D"):
            # ATD / ATDT / ATDP / ATDI <dial string>
            n = 2 if ub[1:2] in ("T", "P", "I") else 1
            self.dial(body[n:].strip())
        elif ub.startswith("H"):                         # ATH — hang up
            self.close_socket()
            self.cmd_mode = True
            self.reply("OK")
        elif ub.startswith("O"):                         # ATO — return online
            if self.sock:
                self.cmd_mode = False
                self.reply(f"CONNECT {self.baud}")
            else:
                self.reply("NO CARRIER")
        elif ub.startswith("Z"):                         # ATZ — reset
            self.close_socket()
            self.cmd_mode = True
            self.echo = True
            self.telnet = True
            self.reply("OK")
        elif ub.startswith("E"):                         # ATE0/ATE1 — echo
            self.echo = not ub.startswith("E0")
            self.reply("OK")
        elif ub.startswith("NET"):                       # ATNET0/1 — telnet toggle
            self.telnet = not ub.startswith("NET0")
            self.reply("OK")
        else:                                            # AT / ATI / etc. — accept
            self.reply("OK")

    def dial(self, target):
        # Accept "host:port", "host", or a "telnet://host:port" devicespec.
        t = target
        for scheme in ("TELNET://", "TCP://", "telnet://", "tcp://"):
            if t.upper().startswith(scheme.upper()):
                t = t[len(scheme):]
                break
        t = t.rstrip("/")
        host, port = (t.rsplit(":", 1) + ["23"])[:2] if ":" in t else (t, "23")
        try:
            port = int(port)
        except ValueError:
            self.reply("NO CARRIER")
            return
        if not host:
            self.reply("NO CARRIER")
            return
        self.log(f"[modem] dial {host}:{port}")
        self.close_socket()
        try:
            self.sock = socket.create_connection((host, port), timeout=15)
            self.sock.setblocking(False)
            self._iac = b""
            self.cmd_mode = False
            self.reply(f"CONNECT {self.baud}")
            self.log(f"[modem] connected to {host}:{port}")
        except OSError as e:
            self.log(f"[modem] connect failed: {e}")
            self.reply("NO CARRIER")

    def reply(self, code):
        """Hayes result code, CR/LF framed, sent to the Atari via the ring."""
        self.feed(b"\r\n" + code.encode("ascii", "replace") + b"\r\n")

    def _socket_send(self, data):
        if not self.sock:
            return
        if self.telnet:
            data = data.replace(b"\xff", b"\xff\xff")   # escape literal IAC
        try:
            self.sock.sendall(data)
        except OSError as e:
            self.log(f"[modem] send failed: {e}")
            self.close_socket()
            self.cmd_mode = True
            self.reply("NO CARRIER")

    # ── socket side ──────────────────────────────────────────────────────────
    def poll_socket(self):
        # Complete a pending '+++' escape once the guard time has elapsed.
        if self.plus_armed and time.time() - self.plus_armed > 1.0:
            self.plus_armed = 0.0
            self.plus_count = 0
            self.cmd_mode = True
            self.reply("OK")
        if not self.sock:
            return
        if self.cmd_mode:
            # Online-command mode after '+++': leave inbound data in the TCP
            # buffer until ATO, but still retry any paced backlog.
            if self.pending:
                self.feed(b"")
            return
        try:
            data = self.sock.recv(1024)
            if data == b"":
                self.log("[modem] remote closed")
                self.close_socket()
                self.cmd_mode = True
                self.reply("NO CARRIER")
            elif data:
                self.feed(self.telnet_filter(data) if self.telnet else data)
        except BlockingIOError:
            if self.pending:
                self.feed(b"")
        except OSError as e:
            self.log(f"[modem] recv failed: {e}")
            self.close_socket()
            self.cmd_mode = True
            self.reply("NO CARRIER")

    def telnet_filter(self, data):
        """Strip/answer telnet IAC negotiation; return the displayable bytes.

        Minimal client: refuse every option (DO->WONT, WILL->DONT), swallow
        subnegotiations, and un-double IAC IAC to a literal 0xFF. Enough for a
        BBS to fall through to a plain character stream."""
        out = bytearray()
        i = 0
        data = self._iac + data
        self._iac = b""
        n = len(data)
        while i < n:
            b = data[i]
            if b != IAC:
                out.append(b)
                i += 1
                continue
            if i + 1 >= n:                              # IAC split across recv()
                self._iac = data[i:]
                break
            c = data[i + 1]
            if c == IAC:                                # escaped literal 0xFF
                out.append(IAC)
                i += 2
            elif c in (DO, DONT, WILL, WONT):
                if i + 2 >= n:
                    self._iac = data[i:]
                    break
                opt = data[i + 2]
                resp = WONT if c == DO else (DONT if c == WILL else None)
                if resp is not None:
                    try:
                        self.sock.sendall(bytes([IAC, resp, opt]))
                    except OSError:
                        pass
                i += 3
            elif c == SB:                               # subnegotiation -> skip to SE
                j = i + 2
                while j + 1 < n and not (data[j] == IAC and data[j + 1] == SE):
                    j += 1
                if j + 1 >= n:
                    self._iac = data[i:]
                    break
                i = j + 2
            else:                                       # 2-byte command (NOP, etc.)
                i += 2
        return bytes(out)


def main():
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from atari_link import AtariLink
    modem = "--modem" in sys.argv or "modem" in sys.argv[1:]
    with AtariLink(timeout=0) as l:
        kind = "modem (R:)" if modem else "network (N:)"
        print(f"— {kind} processor on {l.port} (Ctrl-C stops; logs pass through) —")
        if modem:
            # The R: handler is installed by the BobTerm boot disk itself
            # (make_modem_disk.py appends it to AUTORUN.SYS). Do NOT auto-install
            # over the bridge here — a second installer just fights the disk's.
            # For a non-disk workflow, install explicitly with `atari.py r-install`.
            if l.r_installed():
                print("  R: handler resident (installed by the boot disk).")
            else:
                print("  ! R: not resident — boot the BobTerm1.21_Rmodem.atr disk "
                      "(or run `atari.py r-install`).")
        cls = Modem if modem else Processor
        p = cls(lambda n: l.ser.read(n), lambda d: l.ser.write(d))
        try:
            while True:
                fds = [l.ser.fileno()] + ([p.sock.fileno()] if p.sock else [])
                r, _, _ = select.select(fds, [], [], 0.2)
                if l.ser.fileno() in r:
                    p.pump_serial(l.ser.read(4096))
                if p.sock and p.sock.fileno() in r:
                    p.poll_socket()
                else:
                    p.poll_socket()                     # timers + paced backlog
        except KeyboardInterrupt:
            p.close_socket()
            print("\n— stopped —")


if __name__ == "__main__":
    main()
