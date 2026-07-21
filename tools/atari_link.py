"""atari_link.py — protocol library for the Tang Nano 20K Atari PC Link.

One implementation of the serial-bridge protocol (v1, firmware >= v2.5), shared by
the CLI (atari.py) and the desktop app (atari_gui.py). Wire behavior is identical
to the hardware-proven CLI code: strict '+' flow control, 50 ms beat after command
bytes, checksum-verified transfers.

Protocol (single-byte commands, replies are raw bytes):
  0x05 ENQ                       -> "A8OK\\n" in the log stream
  0x01 PUT nlen name size32LE    -> '+', per-256B-chunk '+', sum16LE -> 'K'/'E'
  0x02 RUN nlen name             -> '+'  (mounts the .xex + cold-boots it)
  0x03 COLD / 0x04 WARM          -> '+'
  0x06 EJECT                     -> '+'
  0x07 TYPE len16LE ...          -> '+', per-char '+', 'K' ('M' = Atari took
                                    the keyboard back via F12/S2)
"""
import os
import sys
import time

import serial
import serial.tools.list_ports

BAUD = 115200

# Protocol refusal byte (firmware BRIDGE_NAK). 0x15 = ASCII NAK — a control char
# that never appears in the firmware's ASCII log text, so scanning for it in a
# stream that interleaves logs and replies is unambiguous. (Before 2026-07-21
# the firmware refused with '-', which collided with log content like filenames
# — a log '-' was misread as a refusal. Old firmware still sends '-'; the tools
# no longer treat it as a refusal, so against old firmware a genuine refusal
# degrades to a timeout instead of a false-positive on the happy path.)
NAK = 0x15


def _screencode_to_ascii(c):
    """Atari internal screen code -> printable ASCII (inverse video ignored)."""
    c &= 0x7F
    a = c + 32 if c < 64 else (c - 64 if c < 96 else c)
    return chr(a) if 32 <= a < 127 else "."


class LinkError(Exception):
    pass


class MenuTakeover(Exception):
    """The user pressed F12/S2 on the Atari — it took the keyboard back."""


def list_ports():
    return sorted(serial.tools.list_ports.comports(), key=lambda p: p.device)


def usb_ports():
    """Only real USB serial devices (drops motherboard ttyS* noise)."""
    return [p for p in list_ports() if p.vid is not None]


def auto_port():
    """The BL616 enumerates FT2232-style: two ports, same VID:PID —
    interface 0 = JTAG, interface 1 = the UART. Pick the SECOND of a pair."""
    cands = usb_ports()
    if not cands:
        raise LinkError("No USB serial ports found — is the board connected "
                        "and powered? (Linux: sudo modprobe ftdi_sio)")
    if len(cands) == 1:
        return cands[0].device
    for i in range(len(cands) - 1):
        a, b = cands[i], cands[i + 1]
        if (a.vid, a.pid) == (b.vid, b.pid) and a.vid is not None:
            return b.device
    for p in cands:
        text = f"{p.description} {p.manufacturer or ''}".lower()
        if any(k in text for k in ("sipeed", "bl616", "jtag", "debug", "serial")):
            return p.device
    listing = "\n".join(f"  {p.device}  {p.description}" for p in cands)
    raise LinkError("Can't auto-pick a port. Candidates:\n" + listing)


def sd_name(path, override=None, default_dir="PC"):
    """Destination path on the SD: default <default_dir>/<basename>, uppercased."""
    name = override or (f"{default_dir}/" + os.path.basename(path)
                        if default_dir else os.path.basename(path))
    name = name.upper().lstrip("/")
    if len(name) > 63:
        raise LinkError(f"path too long for the bridge: {name}")
    return name


class AtariLink:
    """One open connection. Not thread-safe — serialize access externally."""

    def __init__(self, port=None, timeout=1.0, settle=True):
        self.port = port or auto_port()
        self._timeout = timeout
        # exclusive: a second reader steals bytes mid-frame — two atari_net
        # instances once split an event stream 50/50 (HW-hit; one served the
        # request, the other broke the next one). Fail loudly instead.
        self.ser = serial.Serial(self.port, BAUD, timeout=timeout, exclusive=True)
        if settle:
            self._settle_drain()

    def _settle_drain(self, quiet=0.25, limit=3.0):
        """The BL616 stores firmware log output while no PC reader is attached
        and delivers the backlog on the next open (7+ KB takes ~0.7 s at
        115200). Read until the line goes quiet so stale logs are never
        mistaken for live replies. (A single reset_input_buffer loses this
        race — the backlog is still streaming in.)"""
        end = time.time() + limit
        deadline = time.time() + quiet
        old_to = self.ser.timeout
        self.ser.timeout = 0.05
        try:
            while time.time() < deadline and time.time() < end:
                if self.ser.read(4096):
                    deadline = time.time() + quiet
        finally:
            self.ser.timeout = old_to

    def reconnect(self, wait=4.0, deadline=20.0):
        """Recover from a BL616 USB drop: the device re-enumerates within a few
        seconds (usually to the same ttyUSB node). `wait` also lets an aborted
        firmware type-session time out (3 s per-char getc) before we resume."""
        try:
            self.ser.close()
        except Exception:
            pass
        time.sleep(wait)
        end = time.time() + deadline
        while True:
            try:
                port = self.port
                try:
                    port = auto_port()      # node may have moved
                except LinkError:
                    pass
                self.ser = serial.Serial(port, BAUD, timeout=self._timeout,
                                         exclusive=True)
                self.port = port
                break
            except (serial.SerialException, OSError):
                if time.time() > end:
                    raise
                time.sleep(1)
        try:
            self.ser.reset_input_buffer()
        except Exception:
            pass

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ── plumbing ────────────────────────────────────────────────────────────
    def _expect(self, want, what, timeout=3):
        """Scan for a reply byte in `want`, skipping interleaved log bytes."""
        deadline = time.time() + timeout
        skipped = b""
        while time.time() < deadline:
            b = self.ser.read(1)
            if b:
                if b in want:
                    return b
                if b == bytes([NAK]):
                    raise LinkError(f"{what}: firmware refused (NAK)")
                skipped += b
        raise LinkError(f"{what}: timeout (skipped {skipped!r})")

    def _cmd(self, byte):
        """Command byte, then the dispatch beat (firmware main-loop latency)."""
        self.ser.reset_input_buffer()
        self.ser.write(bytes([byte]))
        time.sleep(0.05)

    # ── commands ────────────────────────────────────────────────────────────
    def ping(self, timeout=2):
        self.ser.reset_input_buffer()
        self.ser.write(b"\x05")
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            buf += self.ser.read(64)
            if b"A8OK" in buf:
                return True
        return False

    def send(self, data, name, progress=None):
        """PUT `data` to /`name` on the SD. progress(sent, total) if given."""
        self._cmd(0x01)
        self.ser.write(bytes([len(name)]) + name.encode("ascii") +
                       len(data).to_bytes(4, "little"))
        self._expect(b"+", "open")
        sent = 0
        while sent < len(data):
            chunk = data[sent:sent + 256]
            self.ser.write(chunk)
            self._expect(b"+", f"chunk @{sent}", timeout=5)
            sent += len(chunk)
            if progress:
                progress(sent, len(data))
        self.ser.write((sum(data) & 0xFFFF).to_bytes(2, "little"))
        if self._expect(b"KE", "checksum") == b"E":
            raise LinkError("checksum mismatch — file deleted on the Atari, retry")

    def run(self, data, name, progress=None):
        """PUT then boot. `data` must be a .xex ($FFFF header)."""
        if data[:2] != b"\xff\xff":
            raise LinkError("not a .xex (missing $FFFF header)")
        self.send(data, name, progress)
        self._cmd(0x02)
        self.ser.write(bytes([len(name)]) + name.encode("ascii"))
        self._expect(b"+", "run")

    def eject(self):
        self._cmd(0x06)
        self._expect(b"+", "eject")

    def reset(self, warm=False, keep=False):
        if not keep:
            self.eject()
            time.sleep(0.05)
        self.ser.write(b"\x04" if warm else b"\x03")
        self._expect(b"+", "reset")

    def type_text(self, text, progress=None):
        """Paste text as keystrokes (~18 chars/s). progress(done, total)."""
        data = text.replace("\r\n", "\n").encode("ascii", "replace")
        self._cmd(0x07)
        self.ser.write(len(data).to_bytes(2, "little"))
        self._expect(b"+", "type start")
        for i, b in enumerate(data):
            self.ser.write(bytes([b]))
            self._expect(b"+", f"char {i}", timeout=5)
            if progress:
                progress(i + 1, len(data))
        self._expect(b"K", "type end")

    def type_lines(self, text, progress=None, retries=4):
        """Type line-by-line, self-healing across BL616 USB drops: each line is
        its own type session; a line whose session dies anywhere is flushed
        (bare RETURN) and retyped whole — idempotent for numbered BASIC lines,
        safe for immediate-mode commands that haven't executed yet."""
        lines = [l for l in text.replace("\r\n", "\n").split("\n") if l != ""]
        for n, line in enumerate(lines):
            for attempt in range(retries + 1):
                try:
                    self.type_text(line + "\n")
                    break
                except Exception:
                    if attempt == retries:
                        raise
                    # ride out the drop: reconnect may itself hiccup while the
                    # device re-enumerates — keep trying within this attempt
                    for _ in range(3):
                        try:
                            self.reconnect()
                            self.type_text("\n")     # flush any partial line
                            break
                        except Exception:
                            time.sleep(2)
            if progress:
                progress(n + 1, len(lines))

    def type_key(self, ch):
        """Type ONE character (bounded 1-char session). ~110 ms round-trip;
        suits GUI live-keyboard use without holding a session open."""
        data = ch.encode("ascii", "replace")[:1]
        if not data:
            return
        self._cmd(0x07)
        self.ser.write(b"\x01\x00" + data)
        self._expect(b"+", "type start")
        self._expect(b"+", "key", timeout=5)
        self._expect(b"K", "type end")

    def kbd_session(self):
        """Open a live session; returns a KbdSession. Firmware services SIO
        between keystrokes; F12/S2 on the Atari ends it (MenuTakeover)."""
        self._cmd(0x07)
        self.ser.write(b"\xff\xff")
        self._expect(b"+", "session start")
        return KbdSession(self)

    def status(self, timeout=3):
        """One parseable status line from the firmware (0x08)."""
        self.ser.reset_input_buffer()
        self.ser.write(b"\x08")
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            buf += self.ser.read(64)
            if b"ST " in buf and b"\n" in buf[buf.index(b"ST "):]:
                line = buf[buf.index(b"ST "):]
                return line[:line.index(b"\n")].decode("ascii", "replace")
        raise LinkError("status: no reply")

    def peek(self, addr, length):
        """Read Atari memory (0x09): returns `length` bytes from `addr`."""
        if not 0 < length <= 1024:
            raise LinkError("peek length 1..1024")
        self._cmd(0x09)
        self.ser.write(addr.to_bytes(2, "little") + length.to_bytes(2, "little"))
        self._expect(b"+", "peek")
        data = b""
        deadline = time.time() + 5
        while len(data) < length + 2 and time.time() < deadline:
            data += self.ser.read(length + 2 - len(data))
        if len(data) < length + 2:
            raise LinkError(f"peek: short read ({len(data)}/{length + 2})")
        payload, sum_rx = data[:length], int.from_bytes(data[length:], "little")
        if sum(payload) & 0xFFFF != sum_rx:
            raise LinkError("peek: checksum mismatch")
        return payload

    def fwpeek(self, addr, length):
        """Read FIRMWARE memory (0x0D): PicoRV32 BSRAM 0x0000-0xFFFF —
        remote inspection of firmware globals (debug aid)."""
        if not 0 < length <= 1024:
            raise LinkError("fwpeek length 1..1024")
        self._cmd(0x0D)
        self.ser.write(addr.to_bytes(2, "little") + length.to_bytes(2, "little"))
        self._expect(b"+", "fwpeek")
        data = b""
        deadline = time.time() + 5
        while len(data) < length + 2 and time.time() < deadline:
            data += self.ser.read(length + 2 - len(data))
        if len(data) < length + 2:
            raise LinkError(f"fwpeek: short read ({len(data)}/{length + 2})")
        payload, sum_rx = data[:length], int.from_bytes(data[length:], "little")
        if sum(payload) & 0xFFFF != sum_rx:
            raise LinkError("fwpeek: checksum mismatch")
        return payload

    def poke(self, addr, data):
        """Write bytes into Atari memory (0x0A)."""
        if not 0 < len(data) <= 256:
            raise LinkError("poke length 1..256")
        self._cmd(0x0A)
        self.ser.write(addr.to_bytes(2, "little") +
                       len(data).to_bytes(2, "little"))
        self._expect(b"+", "poke")
        self.ser.write(bytes(data))
        self._expect(b"K", "poke end")

    def screen(self):
        """Text dump of the Atari's screen (GR.0 assumed): 24 lines x 40 cols,
        read from screen RAM via SAVMSC ($58/59). The AI-eyes command."""
        savmsc = int.from_bytes(self.peek(0x58, 2), "little")
        raw = self.peek(savmsc, 960)
        lines = []
        for row in range(24):
            lines.append("".join(_screencode_to_ascii(c)
                                 for c in raw[row * 40:(row + 1) * 40]))
        return "\n".join(lines)

    def alive(self):
        """Is the 6502 running? Watch the OS jiffy counter (RTCLOK $12-14)."""
        a = self.peek(0x12, 3)
        time.sleep(0.1)
        b = self.peek(0x12, 3)
        return a != b

    def hdd_install(self, handler_path=None):
        """Install the H: handler: poke the binary at $0900, register 'H' in
        HATABS ($031A), raise MEMLO. Session-scoped (RESET clears HATABS —
        re-run). Returns (load_addr, end_addr)."""
        import os
        if handler_path is None:
            handler_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "build", "hdd_handler.bin")
        code = open(handler_path, "rb").read()
        load = 0x0900
        # already installed? scan HATABS for 'H'
        hatabs = self.peek(0x031A, 38)
        for i in range(0, 36, 3):
            if hatabs[i] == 0:
                free = i
                break
            if hatabs[i] == ord('H'):
                raise LinkError("H: already installed (RESET to clear)")
        else:
            raise LinkError("HATABS full")
        for off in range(0, len(code), 256):
            self.poke(load + off, code[off:off + 256])
        back = self.peek(load, min(len(code), 64))
        if bytes(back) != code[:len(back)]:
            raise LinkError("handler verify failed")
        self.poke(0x031A + free,
                  bytes([ord('H'), load & 0xFF, load >> 8]))
        memlo = ((load + len(code) + 0xFF) // 0x100) * 0x100
        self.poke(0x02E7, bytes([memlo & 0xFF, memlo >> 8]))
        return load, load + len(code)

    def read_log(self, max_bytes=4096):
        """Drain any pending firmware log bytes (non-blocking-ish)."""
        return self.ser.read(max_bytes)


class KbdSession:
    def __init__(self, link):
        self.link = link
        self.open = True

    def send_key(self, ch):
        if not self.open:
            raise LinkError("session closed")
        b = ch.encode("ascii", "replace")[:1]
        if b == b"\r":
            b = b"\n"
        self.link.ser.write(b)
        r = self.link._expect(b"+M", "key", timeout=5)
        if r == b"M":
            self.open = False
            raise MenuTakeover()

    def poll_takeover(self):
        """Check for an unsolicited 'M' (F12 pressed while we're idle)."""
        b = self.link.ser.read(1)
        if b == b"M":
            self.open = False
            raise MenuTakeover()

    def end(self):
        if self.open:
            self.link.ser.write(b"\x00")
            self.link._expect(b"K", "session end")
            self.open = False
