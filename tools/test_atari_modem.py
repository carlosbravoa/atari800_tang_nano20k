#!/usr/bin/env python3
"""Loopback simulation of the R: modem path (BobTerm side) — PC half + FW mock.

Reuses MockFirmware from test_atari_net (the firmware's serial behaviour: 0x0B
feed / 0x0C state, 512-byte ring) and drives the Modem personality with the
event stream the firmware's rs232_stream_loop() would emit. A scripted local
"BBS" (with telnet IAC negotiation) plays the internet.

Covers: the AT dial dance, telnet IAC strip/answer, bidirectional online stream,
'+++' escape to command mode, ATH + DTR hang-up, and stream survival across a
simulated STATUS-poll interruption (STREAM_END/START).

Run: python3 tools/test_atari_modem.py
"""
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from atari_net import Modem, IAC, DO, WILL, WONT, DONT
from test_atari_net import MockFirmware

fails = 0


def check(label, cond, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + label + (f"  {extra}" if extra else ""))
    if not cond:
        fails += 1


def drain(fw, p):
    """Collect what the modem fed to the Atari and free the ring (Atari read it)."""
    out, fw.ring = fw.ring, b""
    p.fw_free = 511
    return out


def pump_until(fw, p, pred, timeout=3):
    """Poll the socket + serial until pred() or timeout; returns accumulated ring."""
    acc = bytearray()
    end = time.time() + timeout
    while time.time() < end:
        p.poll_socket()
        acc += drain(fw, p)
        if pred(bytes(acc)):
            break
        time.sleep(0.02)
    return bytes(acc)


def main():
    # ── scripted BBS: greets with telnet IAC negotiation, then echoes uppercased
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    bbs_rx = []                                     # everything the BBS received

    def bbs():
        c, _ = srv.accept()
        # Negotiate: ask the client to echo + suppress-go-ahead (it should refuse)
        c.sendall(bytes([IAC, DO, 1, IAC, WILL, 3]) + b"Welcome to the BBS\r\n")
        c.setblocking(False)
        end = time.time() + 8
        while time.time() < end:
            try:
                d = c.recv(256)
                if d == b"":
                    break
                bbs_rx.append(d)
                # echo printable input back uppercased (skip IAC responses)
                if not d.startswith(bytes([IAC])):
                    c.sendall(d.upper())
            except BlockingIOError:
                time.sleep(0.02)
            except OSError:
                break
        try:
            c.close()
        except OSError:
            pass

    threading.Thread(target=bbs, daemon=True).start()

    fw = MockFirmware()
    logs = []
    p = Modem(fw.read, fw.write, log=logs.append)

    # 1) CONFIGURE (19200) then STREAM_START -> command mode, ready for AT
    fw.emit_event(0x0F, bytes([0xF]))
    fw.emit_event(0x10, bytes([0xF]))
    p.pump_serial(fw.read(4096))
    check("configure -> 19200 / command mode",
          p.baud == 19200 and p.cmd_mode, f"baud={p.baud} cmd={p.cmd_mode}")

    # 2) Type "ATDT<host>:<port>" — modem dials, replies CONNECT, goes online
    fw.emit_event(0x11, f"ATDT127.0.0.1:{port}\r".encode())
    p.pump_serial(fw.read(4096))
    connect_echo = drain(fw, p)
    check("ATDT connects + CONNECT result",
          p.sock is not None and not p.cmd_mode and b"CONNECT" in connect_echo,
          f"sock={p.sock is not None} cmd={p.cmd_mode}")

    # 3) BBS greeting arrives; telnet IAC is stripped, text reaches the Atari
    greeting = pump_until(fw, p, lambda a: b"Welcome to the BBS" in a)
    check("BBS greeting delivered (IAC stripped)",
          b"Welcome to the BBS" in greeting and bytes([IAC]) not in greeting,
          f"greeting={greeting!r}")

    # 3b) …and the modem answered the negotiation by refusing both options
    time.sleep(0.2)
    iac_replies = b"".join(d for d in bbs_rx if d.startswith(bytes([IAC])))
    check("telnet refuses DO ECHO -> WONT, WILL SGA -> DONT",
          bytes([IAC, WONT, 1]) in iac_replies and bytes([IAC, DONT, 3]) in iac_replies,
          f"iac_replies={iac_replies!r}")

    # 4) Online: Atari types a line, BBS echoes it uppercased back to the screen
    fw.emit_event(0x11, b"hello world\r")
    p.pump_serial(fw.read(4096))
    echoed = pump_until(fw, p, lambda a: b"HELLO WORLD" in a)
    check("online round-trip (Atari->BBS->Atari)",
          b"HELLO WORLD" in echoed, f"echoed={echoed!r}")
    check("Atari bytes reached the BBS",
          any(b"hello world" in d for d in bbs_rx))

    # 5) '+++' escape (guard time) -> back to command mode, socket stays open
    p.last_rx = time.time() - 2                      # satisfy the pre-guard
    fw.emit_event(0x11, b"+++")
    p.pump_serial(fw.read(4096))
    p.plus_armed = time.time() - 2                   # satisfy the post-guard
    esc = pump_until(fw, p, lambda a: b"OK" in a)
    check("+++ returns to command mode (line held)",
          p.cmd_mode and p.sock is not None and b"OK" in esc,
          f"cmd={p.cmd_mode} sock={p.sock is not None}")

    # 6) ATH hangs up the held line
    fw.emit_event(0x11, b"ATH\r")
    p.pump_serial(fw.read(4096))
    check("ATH hangs up", p.sock is None)

    # 7) DTR drop (CONTROL 'A' -> HANGUP event) drops an active call w/ NO CARRIER
    fw.emit_event(0x0F, bytes([0xF]))               # reconfigure (fresh session)
    fw.emit_event(0x10, bytes([0xF]))
    p.pump_serial(fw.read(4096))
    # (the previous BBS thread's client is gone; open a fresh one)
    srv2 = socket.socket(); srv2.bind(("127.0.0.1", 0)); srv2.listen(1)
    port2 = srv2.getsockname()[1]
    threading.Thread(target=lambda: srv2.accept(), daemon=True).start()
    fw.emit_event(0x11, f"ATDT127.0.0.1:{port2}\r".encode())
    p.pump_serial(fw.read(4096)); drain(fw, p)
    check("second dial online", p.sock is not None and not p.cmd_mode)
    fw.emit_event(0x12)                              # DTR dropped
    p.pump_serial(fw.read(4096))
    nc = drain(fw, p)
    check("DTR hang-up -> NO CARRIER", p.sock is None and b"NO CARRIER" in nc,
          f"nc={nc!r}")

    # 8) STREAM_END/START (STATUS poll) must not disturb an online session
    srv3 = socket.socket(); srv3.bind(("127.0.0.1", 0)); srv3.listen(1)
    port3 = srv3.getsockname()[1]
    threading.Thread(target=lambda: srv3.accept(), daemon=True).start()
    fw.emit_event(0x0F, bytes([0xF])); fw.emit_event(0x10, bytes([0xF]))
    fw.emit_event(0x11, f"ATDT127.0.0.1:{port3}\r".encode())
    p.pump_serial(fw.read(4096)); drain(fw, p)
    online_before = (p.sock is not None and not p.cmd_mode)
    fw.emit_event(0x13)                              # concurrent paused (STATUS)
    fw.emit_event(0x10, bytes([0xF]))               # resumed
    p.pump_serial(fw.read(4096))
    check("session survives a STATUS-poll interruption",
          online_before and p.sock is not None and not p.cmd_mode)

    print(f"\n{'ALL GREEN' if fails == 0 else f'{fails} FAILURES'}")
    return fails


if __name__ == "__main__":
    sys.exit(main())
