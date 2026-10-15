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

While a command runs, and while the interactive prompt is idle, the PC also
answers the shell's `pc` ping, its `date` request (local PC time) and its
network requests (`wget URL [dest]`: the PC fetches on its own HTTP stack and
delivers the file over the bridge's PUT — straight to an sd: path, or to h:
for the shell to copy on; `ls tnfs://…` is next).

Exit status 1 on a failed command. Errors say what to check: the board on
USB, ASH-TN running, or the shell being busy (pager / editor / a program).
"""
import argparse
import os
import re
import sys
import time
import urllib.request
import urllib.error

from atari_link import AtariLink, LinkError

MB = 0x0640
MB_CMDREQ, MB_STATUS, MB_ERR, MB_CIOERR = 0x643, 0x644, 0x645, 0x646
MB_OUT, MB_CAP, MB_LEN, MB_SEQ = 0x647, 0x649, 0x64B, 0x64D
MB_PING, MB_PONG, MB_ABORT, MB_RAM, MB_MORE = 0x64E, 0x64F, 0x650, 0x651, 0x653
MB_TIMEREQ, MB_TIME = 0x654, 0x655          # `date`: shell sets TIMEREQ=1; PC writes yy mm dd hh mm ss, clears it
HDR_LEN = 0x91                              # one header peek covers $0640..$06D0 (incl. NETREQ)
# wget / tnfs: mailbox requests served here, delivered by the bridge PUT (never N:)
MB_NETREQ, MB_NETST, MB_NETLEN = 0x6D0, 0x6D1, 0x6D2   # req 1 fetch / 2 listing; st; len LE24
MB_NETDEST, MB_NETNAME = 0x6D5, 0x6D6                  # dest 0 sd: path / 1 /HDD/NAME / 2 text@$8200; NAME
NET_URL, NET_DEST, NET_TEXT, NET_TEXT_MAX = 0x8000, 0x8100, 0x8200, 0x3E00
NET_CAP = 4 * 1024 * 1024
NST_OK, NST_NETERR, NST_TOOBIG, NST_NOTFILE, NST_REFUSED, NST_UNSUP = 1, 2, 3, 4, 5, 6
MB_CMD, MB_PROMPT = 0x660, 0x6E8            # v2: command line up to 111 chars + 0 ($0660-$06CF); prompt at $06E8 (≤23)
MB_VER, MB_VER_WANT, MB_CMD_MAX = 0x642, 2, 111
RAMWIN = 0x8000
EOL = 0x9B

NO_BOARD = "no board found on USB: connect the Atari board to this computer and make sure it is powered on"
NO_ASH = ("the board answers but ASH-TN is not running on it: deploy "
          "build/ash-tn.xex or boot ASH-TN.ATR, then retry")
BUSY = ("ASH is not at its prompt (a pager, the editor, or a running program "
        "on the Atari): finish that on the Atari and retry")


class AshError(Exception):
    pass


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
    def __init__(self):
        try:
            self.l = AtariLink()
        except LinkError:
            raise AshError(NO_BOARD)
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
                if ser.read(4096):
                    quiet = time.time()
                elif time.time() - quiet >= silence:
                    break
        finally:
            ser.timeout = saved

    def rpeek(self, a, n):
        return self._io(self.l.peek, a, n)

    def poke(self, a, data):
        return self._io(self.l.poke, a, data)

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
        if hdr[MB_NETREQ - MB] in (1, 2):
            self.serve_net(hdr[MB_NETREQ - MB])

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
                    return NST_NETERR, b"", ""
                ctype = (r.headers.get("Content-Type") or "").lower()
                data = r.read(NET_CAP + 1)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
            return NST_NETERR, b"", ""
        if len(data) > NET_CAP:
            return NST_TOOBIG, b"", ctype
        return NST_OK, data, ctype

    def serve_net(self, req):
        """Serve one mailbox network request (wget / ls of a URL); clears NETREQ last."""
        url = self._cstr(NET_URL, 256)
        dest = self._cstr(NET_DEST, 128)
        st, n, dtype, name = NST_UNSUP, 0, 0, ""
        scheme = url.split("://", 1)[0].lower() if "://" in url else ""
        if req == 1 and scheme in ("http", "https"):
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
        elif scheme == "tnfs":
            st = NST_UNSUP                              # TNFS: next step (needs a test server)
        self.poke(MB_NETLEN, n.to_bytes(3, "little"))
        self.poke(MB_NETDEST, bytes([dtype]))
        self.poke(MB_NETNAME, (name.encode("ascii")[:15] + b"\0").ljust(16, b"\0"))
        self.poke(MB_NETST, bytes([st]))
        self.poke(MB_NETREQ, b"\x00")                   # last: the shell is waiting on this

    def idle_service(self):
        """One idle-time poll: answer PING / TIMEREQ raised from the Atari keyboard
        while no command of ours is running (interactive prompt). Never raises."""
        try:
            self.pong(self.l.peek(MB, HDR_LEN))
        except LinkError:
            pass

    def run(self, line, sink=None, timeout=120):
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
            hdr = self.peek(MB, HDR_LEN)
            self.pong(hdr)
            n = int.from_bytes(hdr[MB_LEN - MB:MB_LEN - MB + 2], "little")
            st = hdr[MB_STATUS - MB]
            if st == 0 or hdr[MB_SEQ - MB] != seq:
                started = True
            # Until the shell has signalled the command (STATUS 0 running, or a new
            # SEQ), OUTLEN/STATUS still describe the PREVIOUS command while the new
            # output is already overwriting the buffer — reading then returns stale
            # text (seen as the previous command's output coming back).
            if started and n > got:
                chunk = self.rpeek(base + got, min(n - got, 1024))
                if sink:
                    sink(atascii(chunk))
                got += len(chunk)
                done_seen = False
                continue
            if started and st != 0 and hdr[MB_SEQ - MB] != seq:
                # Done — but a header read can be STALE relative to the output length
                # (the link serves stale bytes now and then; seen as listings cut short
                # or empty). Confirm on a second read that nothing more arrived.
                if done_seen:
                    return st, hdr[MB_ERR - MB], hdr[MB_CIOERR - MB]
                done_seen = True
                continue
            if st == 3:
                return 3, 0, 0
            if time.time() - t0 > timeout:
                raise AshError("timed out waiting for ASH (" + BUSY + ")")
            if not started and time.time() - t0 > 5:
                raise AshError(BUSY)
            time.sleep(0.05)

    def get(self, src, dst, progress=None):
        data = bytearray()
        cmd = f"getw {src}"
        while True:
            msgs = []
            st, err, cio = self.run(cmd, sink=msgs.append)
            if st != 1:
                raise AshError("".join(msgs).strip() or f"getw failed ({err}/{cio})")
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
        return len(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", action="append", default=[], metavar="CMD", help="run this command and exit")
    ap.add_argument("op", nargs="?", choices=["get", "put"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    try:
        ash = Ash()
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
        else:
            print("ASH-TN terminal — Ctrl-D or 'exit' to leave; the Atari keeps running")
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
