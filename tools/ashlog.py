"""ashlog — ashterm's session log and plain-language error explanations.

What gets logged (one timestamped line each, to ~/.local/state/ashterm/ashterm.log):
  - every command ashterm sends to ASH, with its result (ok / error codes / launched)
  - every request ASH makes of the PC (date, wget, tnfs listing) with what was served
  - the board firmware's own log lines (mounts, SIO and SD errors, file transfers),
    which ashterm used to throw away, including the ones caused by commands typed on
    the Atari keyboard while ashterm is running

Errors are explained on the terminal; everything else only goes to the file.
The tables follow ASH's own codes (ash.s: E_*, ciocodes) and the firmware's return
codes (firmware.c: mount_atr, load_cartridge, FatFs FRESULT).
"""
import os
import re
import time

# ASH error codes (ash.s E_*): shell message, then what to do about it
E_TEXT = {
    1: ("no such file or directory",
        "Check the name with ls. sd: paths start at the card root (sd:/games/x.atr); "
        "h: is the flat /HDD folder with 8.3 names."),
    2: ("not a directory", "The path names a file where a folder was expected."),
    3: ("i/o error", "The device answered with an error; the CIO code and firmware lines below say which."),
    4: ("is a directory", "Use cd or ls for folders; cat/run/cp need a file."),
    5: ("not an executable", "run only takes Atari binary-load files (.xex, starting with $FFFF)."),
    6: ("too many levels", "The folder nesting is deeper than the shell can follow."),
    7: ("missing operand", "The command needs another argument; 'help' lists the syntax."),
    8: ("bad number", "A numeric argument could not be parsed."),
    9: ("not supported here", "This device does not support that operation (e.g. writing to h: subfolders)."),
    10: ("no h: device on this machine",
         "The firmware's H: device did not answer: this is not running on the Tang Nano board firmware."),
    11: ("sd: is read-only",
         "Writes to the card are off for this session. Type 'sd rw' on the Atari; every cold boot turns it off again."),
    12: ("refused (protected, in use, missing)",
         "The firmware refused the write. Protected: ATARIXL.ROM, BASIC.ROM, atari.ini, ASH.CAR. In use: a file "
         "mounted on D1-D4, attached as the cartridge, served as the .xex, or open on the other H: handle "
         "('mount' shows what is in use). Or the source file does not exist."),
    13: ("path too long", "sd: paths are limited to 62 characters; cd into the folder first."),
    14: ("fetch failed", "The PC could not fetch it; see the request line below for the reason."),
}

# CIO status codes (ash.s ciocodes + Atari OS), shell message and the usual cause on this board
CIO_TEXT = {
    128: ("BREAK abort", "The command was interrupted with BREAK (or by ashterm's Ctrl-C)."),
    130: ("no such device", "The device letter is not installed (e.g. h: before the H: handler)."),
    136: ("end of file", "Read past the end of the file."),
    138: ("drive not responding",
          "The drive did not answer in time: nothing mounted on that drive, or the firmware was busy with a "
          "PC link transfer. Retry; 'mount' shows what is mounted."),
    139: ("drive refused (NAK)",
          "The drive rejected the command: a sector outside the disk image, or a command it does not support."),
    144: ("device error (write protected?)",
          "The drive reported an error. On this board that is usually a read-only disk image: the file is "
          "read-only on the card, or the same ATR is mounted on two drives (the second one is read-only)."),
    146: ("not supported", "The device does not implement that operation."),
    160: ("no such drive", "Nothing is mounted on that drive number."),
    161: ("too many open files", "Close a file first (the H: device has 2 handles)."),
    162: ("disk full", "No free sectors left on the disk image."),
    165: ("bad file name", "DOS 2 names are up to 8 characters + 3 extension, letters and digits."),
    167: ("locked, or directory not empty", "unlock the file first, or empty the folder."),
    169: ("directory full", "The disk's directory has no free entries (64 on DOS 2)."),
    170: ("no such file", "Check the name with ls."),
    175: ("not a DOS 2 disk (read-only)", "The shell can read this disk's format but not write it."),
}

# FatFs FRESULT, as printed by the firmware in its log lines
FR_TEXT = {
    1: "SD card I/O error", 2: "internal FatFs error", 3: "SD card not ready",
    4: "no such file", 5: "no such folder", 6: "invalid file name",
    7: "access denied (read-only file, or a directory)", 8: "already exists",
    9: "invalid file object", 10: "card is write-protected", 18: "too many open files",
}

# mount_atr() return codes (negative) — otherwise a FatFs code from f_open
MOUNT_TEXT = {-1: "could not read the ATR header", -2: "not an ATR image (bad magic number)",
              -3: "unsupported sector size / .xfd size"}
# load_cartridge() return codes
CART_TEXT = {-1: "cannot open the file", -2: "not a valid .CAR file (no CART header)",
             -3: "unsupported .CAR type", -4: "raw .ROM must be 2/4/8/16 KB",
             -5: "larger than the 4 MB cartridge window", -6: "read error on the card"}

# ashterm's own network results (MB_NETST)
NET_TEXT = {1: "ok", 2: "network or server error", 3: "too big (4 MB limit)",
            4: "not a file (an HTML page, or a directory)",
            5: "refused by the firmware: the destination file is in use (mounted / attached)",
            6: "unsupported: only http://, https:// and tnfs:// URLs, destination path up to 63 characters"}


def _fr(code):
    return FR_TEXT.get(code, f"FatFs error {code}")


# Firmware log lines worth a translation: (regex, function(match) -> text)
FW_HINTS = [
    (r"sd: mount D(\d) failed (-?\d+)",
     lambda m: f"mounting on D{m[1]} failed: "
               f"{MOUNT_TEXT.get(int(m[2])) or _fr(int(m[2]))}"),
    (r"mount (\S+) err (-?\d+)", lambda m: f"mount of {m[1]} failed: {_fr(int(m[2]))}"),
    (r"(?:sd: )?cart(?::)? failed (-?\d+)",
     lambda m: f"cartridge load failed: {CART_TEXT.get(int(m[1]), m[1])}"),
    (r"cart: unsupported CAR type (\d+)", lambda m: f"the core has no mapper for .CAR type {m[1]}"),
    (r"run: mount failed", lambda m: "the .xex could not be mounted (missing, or no $FFFF header)"),
    (r"put abort @(\d+): rx lost", lambda m: f"a PC file transfer lost bytes at offset {m[1]}; the partial file was removed"),
    (r"put abort @(\d+): f_write (\d+)",
     lambda m: f"a PC file transfer failed writing at offset {m[1]}: {_fr(int(m[2]))}"),
    (r"cmd cksum", lambda m: "an SIO command frame arrived damaged (the Atari retries it); "
                             "frequent ones mean the PC link is too busy during disk I/O"),
    (r"data cksum", lambda m: "an SIO data frame arrived damaged; the write was refused and the Atari retries"),
    (r"rd (\d+) fail", lambda m: f"reading sector {m[1]} of a mounted disk image failed on the card"),
    (r"wr (\d+) fail (-?\d+)", lambda m: f"writing sector {m[1]} failed: {_fr(int(m[2]))}"),
    (r"atr RO", lambda m: "a disk image was mounted read-only (read-only file, or mounted twice)"),
    (r"boot: no (\S+) -> BASIC", lambda m: f"Boot: ASH is on but {m[1]} is missing or unreadable, so BASIC booted"),
    (r"boot: watchdog retry (\d+)", lambda m: f"the Atari did not start; the firmware reset it again (try {m[1]})"),
    (r"Format failed \((-?\d+)\)", lambda m: f"formatting the disk image failed: {_fr(int(m[1]))}"),
]


def fw_hint(line):
    for rx, fn in FW_HINTS:
        m = re.search(rx, line)
        if m:
            return fn(m)
    return None


def explain(err, cio, fw_lines=()):
    """Plain-language explanation lines for a failed command."""
    out = []
    if err in E_TEXT:
        msg, hint = E_TEXT[err]
        if err == 3 and cio in CIO_TEXT:          # i/o error: the CIO code is the real story
            cmsg, chint = CIO_TEXT[cio]
            out.append(f"{msg}: CIO {cio} = {cmsg}. {chint}")
        else:
            out.append(hint)
    elif cio in CIO_TEXT:
        cmsg, chint = CIO_TEXT[cio]
        out.append(f"CIO {cio} = {cmsg}. {chint}")
    elif err or cio:
        out.append(f"shell error {err}, CIO status {cio}")
    for line in fw_lines:
        h = fw_hint(line)
        out.append(f"firmware: {line}" + (f"  ({h})" if h else ""))
    return out


def default_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "ashterm", "ashterm.log")


class SessionLog:
    MAX_BYTES = 1024 * 1024                      # rotate to .1 at 1 MB

    def __init__(self, path=None):
        self.path = path
        self._buf = b""
        self.pending_fw = []                     # firmware lines since the last take_fw()
        if path:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            try:
                if os.path.getsize(path) > self.MAX_BYTES:
                    os.replace(path, path + ".1")
            except OSError:
                pass

    def write(self, kind, text):
        if not self.path:
            return
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        try:
            with open(self.path, "a", encoding="utf-8") as f:
                for i, line in enumerate(text.splitlines() or [""]):
                    f.write(f"{stamp}  {kind:<4} {line}\n" if i == 0 else f"{'':19}  {'':<4}   {line}\n")
        except OSError:
            pass

    def firmware_bytes(self, data):
        """Raw bytes the firmware sent outside a reply (its uart log). Keep whole
        printable lines; acks, NAKs and stale reply fragments are dropped."""
        self._buf += data
        *lines, self._buf = self._buf.split(b"\n")
        self._buf = self._buf[-256:]
        for raw in lines:
            line = raw.decode("latin1").strip().lstrip("+K\x15")
            if len(line) < 4 or not re.search(r"[a-zA-Z]{2}", line):
                continue
            if any(ord(c) < 32 or ord(c) > 126 for c in line):
                continue
            if line.startswith(("ST u:", "key=")):
                continue
            self.pending_fw.append(line)
            h = fw_hint(line)
            self.write("fw", line + (f"  -- {h}" if h else ""))

    def take_fw(self):
        out, self.pending_fw = self.pending_fw, []
        return out


def tail(path, n):
    try:
        with open(path, encoding="utf-8") as f:
            return f.readlines()[-n:]
    except OSError:
        return []
