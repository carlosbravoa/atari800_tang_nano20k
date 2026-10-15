#!/usr/bin/env python3
"""ashterm — drive ASH-TN on the Tang Nano Atari over the PC link, no keystrokes.

ASH-TN keeps a mailbox in page 6 ($0640; the contract is owned and documented
by the ASH project, ash/tn.s, github.com/carlosbravoa/atari800-atari-shell):
we poke a command line, the shell runs it as if typed and mirrors its output
into RAM, which we peek. Exact output, no typing cadence, and the shell can
ping us (`pc`). Works with any ASH build that has the mailbox (ASH-TN .xex/.atr
and the ASH.CAR cartridge). Uses only AtariLink.peek/poke/send from atari_link.py.

  ashterm                      interactive: a prompt that shows ASH's own path
  ashterm -c "ls -l" [-c ...]  run commands, print their output, exit
  ashterm get SRC [DST]        copy a file from the Atari (any disk, h:, MyDOS
                               subdir) to the PC through the RAM window
  ashterm put FILE [DST]       send a file to h: (the SD /HDD folder), then
                               `cp` it to DST on the Atari (default: stays on h:)
  ashterm log [N]              show the last N lines of the session log (default 40)

Session log (--log FILE, default ~/.local/state/ashterm/ashterm.log; --no-log):
every command with its result, every request served for the shell (date,
wget, tnfs) and the board firmware's own log lines (mounts, SIO/SD errors,
transfers) — including those caused by commands typed on the Atari keyboard
while ashterm runs. A failed command is explained in plain language on the
terminal (shell error, CIO code, firmware lines), not just the shell's terse text.

Output is shown when a command completes (not progressively): while the shell
streams SIO (listings, cat, cp, getw) the PC keeps its bridge traffic to a
~1.5 ms status poll, because a long bridge reply makes the firmware miss an
SIO frame and a chunk of the stream is lost. While a command runs, and while
the interactive prompt is idle, the PC also answers the shell's `pc` ping, its `date` request (local PC time) and its
network requests (`wget URL [dest]`: the PC fetches on its own HTTP stack and
delivers the file over the bridge's PUT — straight to an sd: path, or to h:
for the shell to copy on; `ls`/`cat`/`run`/`cp` of a tnfs://host/path URL
speak TNFS from the PC and hand the shell a listing or the file).

Exit status 1 on a failed command. Errors say what to check: the board on
USB, ASH-TN running, or the shell being busy (pager / editor / a program).
"""
import argparse
import os
import re
import socket
import struct
import sys
import time
import urllib.request
import urllib.error

from atari_link import AtariLink, LinkError
import ashlog

MB = 0x0640
MB_CMDREQ, MB_STATUS, MB_ERR, MB_CIOERR = 0x643, 0x644, 0x645, 0x646
MB_OUT, MB_CAP, MB_LEN, MB_SEQ = 0x647, 0x649, 0x64B, 0x64D
MB_PING, MB_PONG, MB_ABORT, MB_RAM, MB_MORE = 0x64E, 0x64F, 0x650, 0x651, 0x653
MB_TIMEREQ, MB_TIME = 0x654, 0x655          # `date`: shell sets TIMEREQ=1; PC writes yy mm dd hh mm ss, clears it
HDR_LEN = 0x20                              # keep bridge replies SHORT: a long peek delays the firmware's SIO ACK,
                                            # the OS retries the command and a 128-byte READ chunk is lost (2026-10-15)
# wget / tnfs: mailbox requests served here, delivered by the bridge PUT (never N:)
MB_NETREQ, MB_NETST, MB_NETLEN = 0x6D0, 0x6D1, 0x6D2   # req 1 fetch / 2 listing; st; len LE24
MB_NETDEST, MB_NETNAME = 0x6D5, 0x6D6                  # dest 0 sd: path / 1 /HDD/NAME / 2 text@$8200; NAME
NET_URL, NET_DEST, NET_TEXT, NET_TEXT_MAX = 0x9000, 0x9100, 0x9200, 0x2E00   # URL/DEST strings, listing text ≤ 11.5 KB
NET_CAP = 4 * 1024 * 1024
NST_OK, NST_NETERR, NST_TOOBIG, NST_NOTFILE, NST_REFUSED, NST_UNSUP = 1, 2, 3, 4, 5, 6
MB_CMD, MB_PROMPT = 0x660, 0x6E8            # v2: command line up to 111 chars + 0 ($0660-$06CF); prompt at $06E8 (≤23)
MB_VER, MB_VER_WANT, MB_CMD_MAX = 0x642, 2, 111
RAMWIN = 0x9000                             # getw window ($9000, 12 KB chunks; the mirror is $7800-$8FFF)
EOL = 0x9B

NO_BOARD = "no board found on USB: connect the Atari board to this computer and make sure it is powered on"
NO_ASH = ("the board answers but ASH-TN is not running on it: deploy "
          "build/ash-tn.xex or boot ASH-TN.ATR, then retry")
BUSY = ("ASH is not at its prompt (a pager, the editor, or a running program "
        "on the Atari): finish that on the Atari and retry")


class AshError(Exception):
    pass


class TnfsError(Exception):
    def __init__(self, status):
        super().__init__(f"tnfs status {status}")
        self.status = status


class Tnfs:
    """Minimal TNFS client (FujiNet file protocol, UDP/16384): mount, listdir with
    stat, read a whole file. The Atari never sees TNFS — ashterm presents the
    result through the mailbox as text or as a delivered file."""
    EOF, ENOENT, ENOTDIR, EISDIR = 0x21, 0x02, 0x0C, 0x0D
    READ_SZ = 512                                 # fits every server's datagram

    def __init__(self, host, port=16384, timeout=3.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.addr, self.seq, self.sid = (host, port), 0, 0
        r = self._xfer(0x00, b"\x02\x01/\0\0\0")   # protocol 1.2, root, no credentials
        if r[4] != 0:
            raise TnfsError(r[4])
        self.sid = struct.unpack("<H", r[:2])[0]

    def close(self):
        try:
            self._xfer(0x01, b"")
        except (TnfsError, OSError):
            pass
        self.sock.close()

    def _xfer(self, cmd, payload, tries=3):
        pkt = struct.pack("<HBB", self.sid, self.seq, cmd) + payload
        for _ in range(tries):
            self.sock.sendto(pkt, self.addr)
            try:
                while True:
                    r, _ = self.sock.recvfrom(2048)
                    if len(r) >= 5 and r[2] == self.seq and r[3] == cmd:
                        self.seq = (self.seq + 1) & 0xFF
                        return r
            except socket.timeout:
                continue
        raise TnfsError(0xFF)                      # no answer

    def stat(self, path):
        r = self._xfer(0x24, path.encode("latin1") + b"\0")
        if r[4] != 0:
            raise TnfsError(r[4])
        mode, _, _, size = struct.unpack("<HHHI", r[5:15])
        return (mode & 0xF000) == 0x4000, size

    def listdir(self, path):
        """[(is_dir, size, name)] — directories first, as the shell's ls shows them."""
        r = self._xfer(0x10, path.encode("latin1") + b"\0")
        if r[4] != 0:
            raise TnfsError(r[4])
        dh, names = r[5], []
        while True:
            r = self._xfer(0x11, bytes([dh]))
            if r[4] != 0:
                break
            names.append(r[5:].split(b"\0")[0].decode("latin1"))
        self._xfer(0x12, bytes([dh]))
        out = []
        for n in names:
            if n in (".", ".."):
                continue
            try:
                is_dir, size = self.stat(path.rstrip("/") + "/" + n)
            except TnfsError:
                is_dir, size = False, 0
            out.append((is_dir, size, n))
        out.sort(key=lambda e: (not e[0], e[2].lower()))
        return out

    def read_file(self, path, cap, progress=None):
        r = self._xfer(0x29, struct.pack("<HH", 0x0001, 0) + path.encode("latin1") + b"\0")
        if r[4] != 0:
            raise TnfsError(r[4])
        fd, data = r[5], bytearray()
        try:
            while len(data) <= cap:
                r = self._xfer(0x21, struct.pack("<BH", fd, self.READ_SZ))
                if r[4] == self.EOF:
                    break
                if r[4] != 0:
                    raise TnfsError(r[4])
                n = struct.unpack("<H", r[5:7])[0]
                data += r[7:7 + n]
                if progress:
                    progress(len(data))
                if n == 0:
                    break
        finally:
            self._xfer(0x23, bytes([fd]))
        return bytes(data)


def atascii(b):
    out = []
    for c in b:
        if c == EOL:
            out.append("\n")
        elif 0x20 <= c < 0x7D:
            out.append(chr(c))
        elif 0xA0 <= c < 0xFD:
            out.append(chr(c & 0x7F))
        elif c in (0x7E, 0x7F, 0x1B):
            pass
        else:
            out.append(".")
    return "".join(out)


class Ash:
    def __init__(self, log_path=None):
        self.log = ashlog.SessionLog(log_path)
        self.last_explain = []                    # explanation lines of the last failed command
        try:
            self.l = AtariLink()
        except LinkError:
            raise AshError(NO_BOARD)
        self.l.on_log = self.log.firmware_bytes   # keep the firmware's log lines, don't drop them
        self.missed = self.log.backlog(self.l.backlog)   # logged while nobody was connected
        self.hdr = None
        if not self.alive():
            raise AshError(NO_ASH)
        if self.hdr[MB_VER - MB] != MB_VER_WANT:
            raise AshError(f"ASH-TN speaks mailbox version {self.hdr[MB_VER - MB]}, this ashterm "
                           f"needs {MB_VER_WANT}: update ASH-TN (or ashterm) so they match")

    def close(self):
        self.l.close()

    def _io(self, fn, *args, tries=40):
        """Link calls time out while the firmware is inside an SIO transaction
        (ASH reading a disk); wait it out and retry — after DRAINING the line:
        the firmware still completes the abandoned request, and its late reply
        (same length, valid checksum) would otherwise be read as the answer to
        the retry = stale data (seen as listings cut short, or the previous
        command's output coming back)."""
        for i in range(tries):
            try:
                return fn(*args)
            except LinkError as e:
                if i == tries - 1:
                    raise AshError("the link stopped answering (" + BUSY + ")")
                if os.environ.get("ASHTERM_DEBUG"):
                    sys.stderr.write(f"[link retry {i + 1}: {e}]\n")
                self._drain()

    def _drain(self, silence=0.25, limit=3.0):
        """Swallow whatever is still streaming in until `silence` seconds pass
        with no byte (bounded by `limit`)."""
        ser = self.l.ser
        saved, ser.timeout = ser.timeout, 0.05
        try:
            t_end, quiet = time.time() + limit, time.time()
            while time.time() < t_end:
                b = ser.read(4096)
                if b:
                    self.log.firmware_bytes(b)
                    quiet = time.time()
                elif time.time() - quiet >= silence:
                    break
        finally:
            ser.timeout = saved

    def rpeek(self, a, n):
        return self._io(self.l.peek, a, n)

    def poke(self, a, data):
        return self._io(self.l.poke, a, data)

    def poll_window(self):
        """While a command RUNS the shell may be streaming SIO (listings, cat, getw,
        cp) and every bridge byte is a chance to make the firmware miss an SIO frame.
        So the running-command poll is a 17-byte peek of $0644..$0654 (STATUS, ERR,
        CIOERR, OUTPTR/CAP/LEN, SEQ, PING/PONG, ABORT, RAM/MORE, TIMEREQ) — ~1.5 ms
        on the wire — padded into the 32-byte header layout."""
        w = self.peek(MB + 4, 17)
        return b"\0" * 4 + w + b"\0" * (0x20 - 4 - 17)

    def peek(self, a, n):
        """A stable read: the link can serve stale bytes, so read until two agree."""
        last = None
        for _ in range(6):
            cur = self.rpeek(a, n)
            if cur == last:
                return cur
            last = cur
        return last

    def alive(self):
        try:
            self.hdr = self.l.peek(MB, HDR_LEN)
        except LinkError:
            try:                                   # the first call after idle often misses
                self.hdr = self.l.peek(MB, HDR_LEN)
            except LinkError:
                return False
        return self.hdr[:2] == b"AS"

    def prompt(self):
        p = self.peek(MB_PROMPT, 32)
        return atascii(p.split(b"\0")[0])

    def pong(self, hdr):
        if hdr[MB_PING - MB] != hdr[MB_PONG - MB]:
            self.poke(MB_PONG, bytes([hdr[MB_PING - MB]]))
        if hdr[MB_TIMEREQ - MB]:                   # `date`: local time, binary, yy = year - 2000
            t = time.localtime()
            self.poke(MB_TIME, bytes([t.tm_year - 2000, t.tm_mon, t.tm_mday,
                                      t.tm_hour, t.tm_min, t.tm_sec]))
            self.poke(MB_TIMEREQ, b"\x00")
            self.log.write("req", time.strftime("date -> %Y-%m-%d %H:%M:%S (PC local time)", t))
        self._net_tick = getattr(self, "_net_tick", 0) + 1
        if self._net_tick % 2 == 0:                # NETREQ lives outside the 32-byte header
            req = self.rpeek(MB_NETREQ, 1)[0]
            if req in (1, 2):
                self.serve_net(req)

    # ── wget / tnfs server ────────────────────────────────────────────────────
    def _cstr(self, addr, n):
        return self.rpeek(addr, n).split(b"\0")[0].decode("latin1")

    @staticmethod
    def hdd_name(url):
        """An 8.3 /HDD name from the URL's last path component (hdd_path rules)."""
        last = url.split("?")[0].rstrip("/").rsplit("/", 1)[-1] or "FILE"
        base, _, ext = last.rpartition(".") if "." in last else (last, "", "")
        clean = lambda t, n: (re.sub(r"[^A-Z0-9_-]", "", t.upper())[:n] or "X")
        name = clean(base, 8)
        return name + ("." + clean(ext, 3) if ext else "")

    @staticmethod
    def fetch(url):
        """GET url on the PC. Returns (status, data, content_type)."""
        req = urllib.request.Request(url, headers={"User-Agent": "ashterm/1.0 (Atari 800 Tang Nano 20K)"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                if r.status != 200:
                    Ash.net_detail = f"HTTP {r.status}"
                    return NST_NETERR, b"", ""
                ctype = (r.headers.get("Content-Type") or "").lower()
                data = r.read(NET_CAP + 1)
        except urllib.error.HTTPError as e:
            Ash.net_detail = f"HTTP {e.code} {e.reason}"
            return NST_NETERR, b"", ""
        except (urllib.error.URLError, OSError, ValueError) as e:
            Ash.net_detail = str(getattr(e, "reason", e))
            return NST_NETERR, b"", ""
        if len(data) > NET_CAP:
            return NST_TOOBIG, b"", ctype
        return NST_OK, data, ctype

    @staticmethod
    def tnfs_split(url):
        """tnfs://host[:port]/path -> (host, port, '/path')"""
        rest = url.split("://", 1)[1]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        return host, int(port) if port.isdigit() else 16384, "/" + path

    @staticmethod
    def listing_text(entries):
        """The XIO 40 line format the shell already parses: '<d|f> <size8> <name27>'EOL … 'END'EOL."""
        out = bytearray()
        for is_dir, size, name in entries:
            line = ("d " + " " * 8 if is_dir else "f " + str(size).rjust(8)) + " " + name[:27]
            out += line.encode("latin1", "replace") + b"\x9b"
            if len(out) > NET_TEXT_MAX - 64:
                break
        return bytes(out) + b"END\x9b"

    def tnfs_request(self, req, url):
        """Returns (status, data) — data = file bytes (req 1) or listing text (req 2)."""
        try:
            host, port, path = self.tnfs_split(url)
            t = Tnfs(host, port)
        except (TnfsError, OSError, ValueError) as e:
            Ash.net_detail = f"tnfs mount failed ({e})"
            return NST_NETERR, b""
        try:
            if req == 2:
                return NST_OK, self.listing_text(t.listdir(path))
            is_dir, size = t.stat(path)
            if is_dir:
                return NST_NOTFILE, b""
            if size > NET_CAP:
                return NST_TOOBIG, b""
            return NST_OK, t.read_file(path, NET_CAP)
        except TnfsError as e:
            Ash.net_detail = f"tnfs status 0x{e.status:02X}"
            if e.status in (Tnfs.ENOENT, Tnfs.ENOTDIR, Tnfs.EISDIR):
                return NST_NOTFILE, b""
            return NST_NETERR, b""
        except OSError as e:
            Ash.net_detail = str(e)
            return NST_NETERR, b""
        finally:
            t.close()

    def serve_net(self, req):
        """Serve one mailbox network request (wget / ls of a URL); clears NETREQ last."""
        url = self._cstr(NET_URL, 256)
        dest = self._cstr(NET_DEST, 128)
        st, n, dtype, name = NST_UNSUP, 0, 0, ""
        Ash.net_detail = ""
        target = ""
        scheme = url.split("://", 1)[0].lower() if "://" in url else ""
        data, ctype = b"", ""
        if req == 2 and scheme == "tnfs":          # listing -> text at $8200
            st, text = self.tnfs_request(2, url)
            if st == NST_OK:
                for off in range(0, len(text), 256):
                    self.poke(NET_TEXT + off, text[off:off + 256])
                n, dtype = len(text), 2
        elif req == 1 and scheme in ("http", "https", "tnfs"):
            if scheme == "tnfs":
                st, data = self.tnfs_request(1, url)
            else:
                st, data, ctype = self.fetch(url)
            html = ctype.startswith("text/html")
            if st == NST_OK and html and not url.lower().split("?")[0].endswith((".html", ".htm")):
                st = NST_NOTFILE                       # an error/landing page, not the file
            if st == NST_OK:
                d = dest.strip()
                dl = d.lower()
                if dl.startswith("sd:/"):
                    target, dtype = d[3:], 0            # final path on the card
                elif dl.startswith("h:"):     # "h:NAME" -> that name; "h:" alone -> from the URL
                    name = self.hdd_name(d[2:] if d[2:].strip() else url)
                    target, dtype = "/HDD/" + name, 1
                else:                                   # d<n>:NAME or '-': stage on h:, shell copies/cats
                    name = self.hdd_name(url); target, dtype = "/HDD/" + name, 1
                if len(target) > 63:
                    st = NST_UNSUP
                else:
                    try:
                        self._io(self.l.send, data, target)
                        n = len(data)
                    except AshError:
                        st = NST_REFUSED                # the firmware NAKed the PUT (guarded file)
                        target = ""
        self.poke(MB_NETLEN, n.to_bytes(3, "little"))
        self.poke(MB_NETDEST, bytes([dtype]))
        self.poke(MB_NETNAME, (name.encode("ascii")[:15] + b"\0").ljust(16, b"\0"))
        self.poke(MB_NETST, bytes([st]))
        self.poke(MB_NETREQ, b"\x00")                   # last: the shell is waiting on this
        what = "list" if req == 2 else "fetch"
        where = f" -> {dest}" if req == 1 else ""
        if st == NST_OK:
            to = f", delivered to {target}" if target else ""
            self.log.write("req", f"{what} {url}{where}: ok, {n} bytes{to}")
        else:
            why = ashlog.NET_TEXT.get(st, f"status {st}")
            if Ash.net_detail:
                why += f" ({Ash.net_detail})"
            fw = self.log.take_fw()
            lines = [f"{what} {url}{where}: FAILED - {why}"] + \
                    [f"firmware: {x}" + (f"  ({ashlog.fw_hint(x)})" if ashlog.fw_hint(x) else "") for x in fw]
            self.log.write("req", "\n".join(lines))
            sys.stderr.write("\n[pc] " + "\n[pc] ".join(lines) + "\n")

    def idle_service(self):
        """One idle-time poll: answer PING / TIMEREQ raised from the Atari keyboard
        while no command of ours is running (interactive prompt). Never raises."""
        try:
            self.pong(self.l.peek(MB, HDR_LEN))
        except LinkError:
            pass

    def run(self, line, sink=None, timeout=120):
        """Run one command (logged; explained on failure). Returns (status, err, cioerr)."""
        self.log.take_fw()                        # earlier firmware lines are already in the file
        self.last_explain = []
        t0 = time.time()
        seen = []
        def tee(t):
            seen.append(t)
            if sink:
                sink(t)
        try:
            st, err, cio = self._run(line, tee, timeout)
        except AshError as e:
            self.log.write("cmd", f"{line}  -> not run: {e}")
            raise
        dt = time.time() - t0
        fw = self.log.take_fw()
        if st == 1:
            self.log.write("cmd", f"{line}  -> ok ({dt:.1f}s)")
            # The shell said ok, but the firmware may have failed behind it (a mount or
            # cart load is deferred to the firmware's main loop): surface those too.
            self.last_explain = [f"firmware: {x}  ({ashlog.fw_hint(x)})" for x in fw if ashlog.fw_hint(x)]
        elif st == 3:
            self.log.write("run", f"{line}  -> program launched; ASH is no longer running")
        else:
            if not cio:                           # the shell printed it but left MB_CIOERR at 0
                m = re.search(r"error (1[2-9]\d)\b", "".join(seen))
                cio = int(m.group(1)) if m else 0
            self.last_explain = ashlog.explain(err, cio, fw)
            self.log.write("cmd", f"{line}  -> error E{err} CIO {cio} ({dt:.1f}s)\n" +
                           "\n".join(self.last_explain))
        return st, err, cio

    def _run(self, line, sink=None, timeout=120):
        """Run one command; stream its output to sink(text). Returns (status, err, cioerr)."""
        hdr = self.peek(MB, HDR_LEN)
        if hdr[:2] != b"AS":
            raise AshError(NO_ASH)
        if hdr[MB_STATUS - MB] == 0 or hdr[MB_CMDREQ - MB]:
            raise AshError(BUSY)
        data = line.encode("latin1")[:MB_CMD_MAX] + b"\0"
        self.poke(MB_CMD, data)
        seq = hdr[MB_SEQ - MB]
        self.poke(MB_CMDREQ, b"\x01")
        out = self.rpeek(MB_OUT, 2)
        base = int.from_bytes(out, "little")
        got, t0, started, done_seen = 0, time.time(), False, False
        while True:
            hdr = self.poll_window()
            self.pong(hdr)
            n = int.from_bytes(hdr[MB_LEN - MB:MB_LEN - MB + 2], "little")
            st = hdr[MB_STATUS - MB]
            if st == 0 or hdr[MB_SEQ - MB] != seq:
                started = True
            # Output is fetched only AFTER the command is done (shell idle = no SIO
            # in flight): reading it progressively costs frames while the shell
            # streams. Until the shell has signalled the command (STATUS 0 / new SEQ)
            # OUTLEN still describes the previous one, so never read before that.
            if started and st != 0 and hdr[MB_SEQ - MB] != seq:
                # Done — confirm on a second read (a header read can lag the output).
                if done_seen:
                    while n > got:
                        chunk = self.rpeek(base + got, min(n - got, 1024))
                        if sink:
                            sink(atascii(chunk))
                        got += len(chunk)
                    if os.environ.get("ASHTERM_DEBUG"):
                        sys.stderr.write(f"[done: st={st} seq={seq}->{hdr[MB_SEQ - MB]} outlen={n} got={got} "
                                         f"elapsed={time.time() - t0:.2f}s]\n")
                    return st, hdr[MB_ERR - MB], hdr[MB_CIOERR - MB]
                done_seen = True
                continue
            done_seen = False
            if st == 3:
                return 3, 0, 0
            if time.time() - t0 > timeout:
                raise AshError("timed out waiting for ASH (" + BUSY + ")")
            if not started and time.time() - t0 > 5:
                raise AshError(BUSY)
            time.sleep(float(os.environ.get("ASHTERM_POLL", "0.15")))   # poll pace while a command runs

    def get(self, src, dst, progress=None):
        data = bytearray()
        cmd = f"getw {src}"
        while True:
            msgs = []
            st, err, cio = self.run(cmd, sink=msgs.append)
            if st != 1:
                msg = "".join(msgs).strip() or f"getw failed ({err}/{cio})"
                raise AshError("\n".join([msg] + self.last_explain))
            hdr = self.peek(MB, HDR_LEN)
            n = int.from_bytes(hdr[MB_RAM - MB:MB_RAM - MB + 2], "little")
            for off in range(0, n, 1024):
                data += self.rpeek(RAMWIN + off, min(1024, n - off))
            if progress:
                progress(len(data))
            if not hdr[MB_MORE - MB]:
                break
            cmd = "getw"
        open(dst, "wb").write(data)
        self.log.write("get", f"{src} -> {dst}: {len(data)} bytes")
        return len(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", action="append", default=[], metavar="CMD", help="run this command and exit")
    ap.add_argument("--log", metavar="FILE", default=ashlog.default_path(),
                    help="session log file (default: %(default)s)")
    ap.add_argument("--no-log", action="store_true", help="do not write the session log")
    ap.add_argument("op", nargs="?", choices=["get", "put", "log"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    if a.op == "log":                           # show the end of the session log; no board needed
        n = int(a.args[0]) if a.args and a.args[0].isdigit() else 40
        lines = ashlog.tail(a.log, n)
        sys.stdout.write("".join(lines) if lines else f"(no log yet at {a.log})\n")
        sys.exit(0)
    def explain(ash):                           # printed after any command that has something to explain
        for x in ash.last_explain:
            sys.stderr.write(f"ashterm: {x}\n")
    try:
        ash = Ash(None if a.no_log else a.log)
    except AshError as e:
        sys.exit(f"ashterm: {e}")
    rc = 0
    try:
        if a.op == "get":
            if not a.args:
                sys.exit("usage: ashterm get SRC [DST]")
            src = a.args[0]
            dst = a.args[1] if len(a.args) > 1 else os.path.basename(src.split(":")[-1].split("/")[-1])
            n = ash.get(src, dst, progress=lambda k: print(f"\r{k} bytes", end="", flush=True))
            print(f"\r{dst}: {n} bytes        ")
        elif a.op == "put":
            if not a.args:
                sys.exit("usage: ashterm put FILE [DST]")
            path = a.args[0]
            name = os.path.basename(path).upper()
            ash.l.send(open(path, "rb").read(), f"HDD/{name}")
            print(f"h:{name.lower()} <- {path}")
            if len(a.args) > 1:
                st, *_ = ash.run(f"cp h:{name.lower()} {a.args[1]}", sink=lambda t: print(t, end=""))
                rc = 0 if st == 1 else 1
                explain(ash)
        elif a.c:
            for cmd in a.c:
                try:
                    st, err, cio = ash.run(cmd, sink=lambda t: print(t, end="", flush=True))
                except BrokenPipeError:             # `ashterm -c ... | head`: reader went away;
                    ash.poke(MB_ABORT, b"\x01")      # BREAK the shell's command so it returns
                    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
                    break                           # to its prompt instead of waiting on us
                if st == 3:
                    print("(program launched; ASH is no longer running)")
                    break
                if st != 1:
                    rc = 1
                explain(ash)
        else:
            print("ASH-TN terminal — Ctrl-D or 'exit' to leave; the Atari keeps running")
            ash.log.write("sess", "interactive session started")
            # Idle poller: while we sit at the prompt, answer the shell's `pc` ping and
            # `date` request (raised from the Atari keyboard) every ~250 ms. The serial
            # link is one byte stream, so EVERY access is serialised through `link`:
            # the main thread holds it for prompt() and run(), the poller for each tick
            # (an unguarded first tick once raced prompt() and wedged both sides).
            import threading
            link = threading.Lock()
            stop = threading.Event()
            def poller():
                while not stop.wait(0.25):
                    with link:
                        ash.idle_service()
            th = threading.Thread(target=poller, daemon=True)
            th.start()
            while True:
                try:
                    with link:
                        p = ash.prompt()
                    line = input(f"{p}$ ")
                except (EOFError, KeyboardInterrupt):
                    print()
                    break
                if line.strip() in ("exit", "quit"):
                    break
                if not line.strip():
                    continue
                try:
                    with link:
                        st, err, cio = ash.run(line, sink=lambda t: print(t, end="", flush=True))
                except KeyboardInterrupt:
                    with link:
                        ash.l.poke(MB_ABORT, b"\x01")
                    print("\n(abort sent)")
                    continue
                if st == 3:
                    print("(program launched; ASH is no longer running)")
                    break
                explain(ash)
            stop.set()                         # after the loop: the poller ends with the prompt
    except AshError as e:
        sys.exit(f"ashterm: {e}")
    finally:
        ash.close()
    sys.exit(rc)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:                     # stdout closed under a late print
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
