#!/usr/bin/env python3
"""atari_gui.py — desktop app for the Tang Nano 20K Atari PC Link.

Tkinter (stdlib) + pyserial + atari_link.py. Runs on Linux and Windows.

    python3 tools/atari_gui.py

Layout: port bar on top; action buttons + destination folder on the left;
tabs for Log / Type / Live Keys on the right; progress + status at the bottom.

Threading: one worker thread owns the serial connection and consumes a job
queue; when idle it drains firmware log bytes. The Tk main loop never touches
the port. UI updates flow back through a queue polled with root.after().
"""
import glob
import os
import queue
import sys
import threading
import time


def _sanitize_ld_path():
    """The Gowin IDE setup often exports LD_LIBRARY_PATH=<IDE>/lib globally,
    which makes python load Gowin's libtcl (old, with a baked-in script path
    that only exists inside the IDE) — breaking every Tk app on the machine.
    If any LD_LIBRARY_PATH entry ships a libtcl/libtk, re-exec ourselves with
    those entries removed before tkinter ever loads."""
    if os.environ.get("_ATARI_GUI_REEXEC") == "1" or os.name == "nt":
        return
    llp = os.environ.get("LD_LIBRARY_PATH", "")
    if not llp:
        return
    keep = [d for d in llp.split(":")
            if d and not (glob.glob(os.path.join(d, "libtcl8*")) or
                          glob.glob(os.path.join(d, "libtk8*")))]
    if ":".join(keep) != llp:
        env = dict(os.environ)
        env["LD_LIBRARY_PATH"] = ":".join(keep)
        env["_ATARI_GUI_REEXEC"] = "1"
        os.execve(sys.executable, [sys.executable] + sys.argv, env)


_sanitize_ld_path()
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from atari_link import AtariLink, LinkError, MenuTakeover, usb_ports, sd_name


APP_TITLE = "Atari PC Link — Tang Nano 20K"


class Worker(threading.Thread):
    """Owns the AtariLink. Jobs: (name, fn(link)); idle = log tailing."""

    def __init__(self, ui_q):
        super().__init__(daemon=True)
        self.ui_q = ui_q
        self.jobs = queue.Queue()
        self.link = None
        self.sess = None                 # live KbdSession (owned by this thread)
        self._lbuf = ""                  # partial-line assembly for PRN routing
        self._ltime = 0.0
        self.want_port = None
        self.stop_flag = False

    # thread-safe API for the UI side
    def submit(self, name, fn):
        self.jobs.put((name, fn))

    def connect(self, port):
        self.want_port = port or "AUTO"

    def disconnect(self):
        self.want_port = None

    # ── thread body ──────────────────────────────────────────────────────────
    def _emit(self, kind, *payload):
        self.ui_q.put((kind, payload))

    def _route_log(self, text):
        """Assemble lines; 'PRN: ' lines go to the Printer pane, rest to Log."""
        self._lbuf += text
        self._ltime = time.time()
        while "\n" in self._lbuf:
            line, self._lbuf = self._lbuf.split("\n", 1)
            if line.startswith("PRN: "):
                self._emit("prn", line[5:] + "\n")
            else:
                self._emit("log", line + "\n")

    def run(self):
        while not self.stop_flag:
            # connection management
            if self.want_port and self.link is None:
                try:
                    port = None if self.want_port == "AUTO" else self.want_port
                    self.link = AtariLink(port, timeout=0.2)
                    alive = self.link.ping()
                    self._emit("connected", self.link.port, alive)
                except LinkError as e:
                    self._emit("error", str(e))
                    self.want_port = None
                except Exception as e:
                    self._emit("error", f"{type(e).__name__}: {e}")
                    self.want_port = None
                continue
            if not self.want_port and self.link is not None:
                self.link.close()
                self.link = None
                self._emit("disconnected")
                continue
            if self.link is None:
                time.sleep(0.2)
                continue

            # jobs, else tail logs
            try:
                name, fn = self.jobs.get(timeout=0.05)
            except queue.Empty:
                try:
                    d = self.link.read_log()
                    if d:
                        # logs are muted during a live session, so any 'M' is
                        # the F12/S2 takeover marker — not log text
                        if self.sess and b"M" in d:
                            self.sess.open = False
                            self.sess = None
                            self._emit("kbd_takeover")
                            d = d.replace(b"M", b"", 1)
                        if d:
                            self._route_log(d.decode("ascii", "replace"))
                    elif self._lbuf and time.time() - self._ltime > 0.5:
                        self._emit("log", self._lbuf)   # flush stale partial
                        self._lbuf = ""
                except Exception:
                    self._emit("error", "connection lost")
                    self.link.close()
                    self.link = None
                    self.want_port = None
                continue

            self._emit("busy", name)
            try:
                fn(self.link)
                self._emit("done", name)
            except MenuTakeover:
                self._emit("done", f"{name} — Atari took the keyboard (F12)")
            except LinkError as e:
                self._emit("error", f"{name}: {e}")
            except Exception as e:
                self._emit("error", f"{name}: {type(e).__name__}: {e}")


class App:
    def __init__(self, root):
        self.root = root
        root.title(APP_TITLE)
        root.minsize(720, 460)
        self.ui_q = queue.Queue()
        self.worker = Worker(self.ui_q)
        self.worker.start()
        self.connected = False
        self._build()
        self._refresh_ports()
        root.after(50, self._poll_ui)
        root.protocol("WM_DELETE_WINDOW", self._quit)

    # ── UI construction ──────────────────────────────────────────────────────
    def _build(self):
        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")
        ttk.Label(top, text="Port:").pack(side="left")
        self.port_cb = ttk.Combobox(top, width=28, state="readonly")
        self.port_cb.pack(side="left", padx=4)
        ttk.Button(top, text="↻", width=3,
                   command=self._refresh_ports).pack(side="left")
        self.conn_btn = ttk.Button(top, text="Connect", command=self._toggle_conn)
        self.conn_btn.pack(side="left", padx=8)
        self.status = ttk.Label(top, text="disconnected", foreground="gray")
        self.status.pack(side="left", padx=8)

        body = ttk.Frame(self.root, padding=(6, 0, 6, 6))
        body.pack(fill="both", expand=True)

        # left: actions
        left = ttk.Frame(body)
        left.pack(side="left", fill="y", padx=(0, 8))
        self.act_btns = []

        def act(label, cmd):
            b = ttk.Button(left, text=label, command=cmd, width=18)
            b.pack(pady=2)
            self.act_btns.append(b)
            return b

        act("Send file…", self._send_file)
        act("Run .xex…", self._run_xex)
        ttk.Label(left, text="Destination folder:").pack(pady=(10, 0))
        self.dest = ttk.Entry(left, width=18)
        self.dest.insert(0, "PC")
        self.dest.pack()
        ttk.Separator(left).pack(fill="x", pady=8)
        act("Eject virtual disk", lambda: self._simple("eject",
                                                       lambda l: l.eject()))
        act("Warm start", lambda: self._simple("warm start",
                                               lambda l: l.reset(warm=True)))
        act("Cold boot (reset)", lambda: self._simple("reset",
                                                      lambda l: l.reset()))
        ttk.Separator(left).pack(fill="x", pady=8)
        act("Ping", self._ping)

        # right: tabs
        tabs = ttk.Notebook(body)
        tabs.pack(side="left", fill="both", expand=True)

        logf = ttk.Frame(tabs)
        tabs.add(logf, text="Log")
        self.log = scrolledtext.ScrolledText(logf, height=12, state="disabled",
                                             font=("monospace", 9))
        self.log.pack(fill="both", expand=True)
        lb = ttk.Frame(logf)
        lb.pack(fill="x")
        ttk.Button(lb, text="Clear", command=self._log_clear).pack(side="left")
        ttk.Button(lb, text="Save…", command=self._log_save).pack(side="left")

        typef = ttk.Frame(tabs)
        tabs.add(typef, text="Type")
        self.type_box = scrolledtext.ScrolledText(typef, height=10,
                                                  font=("monospace", 10))
        self.type_box.pack(fill="both", expand=True)
        tb = ttk.Frame(typef)
        tb.pack(fill="x")
        ttk.Button(tb, text="Type it on the Atari",
                   command=self._type_text).pack(side="left")
        ttk.Button(tb, text="Load file…",
                   command=self._type_load).pack(side="left")
        ttk.Label(tb, text="(~18 chars/s; OSD must be closed)").pack(side="left",
                                                                     padx=6)

        prnf = ttk.Frame(tabs)
        tabs.add(prnf, text="Printer")
        self.prn = scrolledtext.ScrolledText(prnf, height=12, state="disabled",
                                             font=("monospace", 10))
        self.prn.pack(fill="both", expand=True)
        pb = ttk.Frame(prnf)
        pb.pack(fill="x")
        ttk.Button(pb, text="Save as .txt…",
                   command=self._prn_save).pack(side="left")
        ttk.Button(pb, text="Save as PDF…",
                   command=self._prn_pdf).pack(side="left")
        ttk.Button(pb, text="Print…", command=self._prn_print).pack(side="left")
        ttk.Button(pb, text="Clear", command=self._prn_clear).pack(side="left")
        ttk.Label(pb, text="LPRINT / AtariWriter output lands here").pack(
            side="left", padx=8)

        kbdf = ttk.Frame(tabs)
        tabs.add(kbdf, text="Live Keys")
        ttk.Label(kbdf, text="Click the box, then type — every key lands on "
                             "the Atari.\nBackspace/Esc/Tab/Enter work. "
                             "Click elsewhere to stop.").pack(pady=6)
        self.kbd_zone = tk.Label(kbdf, text="⌨  click here to type on the Atari",
                                 relief="groove", padx=20, pady=30,
                                 background="#f0f0f0", takefocus=1)
        self.kbd_zone.pack(padx=20, pady=10, fill="x")
        self.kbd_zone.bind("<Button-1>", lambda e: self.kbd_zone.focus_set())
        self.kbd_zone.bind("<FocusIn>", self._kbd_focus)
        self.kbd_zone.bind("<FocusOut>", self._kbd_blur)
        self.kbd_zone.bind("<KeyPress>", self._kbd_key)

        bottom = ttk.Frame(self.root, padding=6)
        bottom.pack(fill="x")
        self.prog = ttk.Progressbar(bottom, maximum=100)
        self.prog.pack(side="left", fill="x", expand=True)
        self.busy_lbl = ttk.Label(bottom, text="", width=32)
        self.busy_lbl.pack(side="left", padx=6)

        self._set_actions_enabled(False)

    # ── helpers ──────────────────────────────────────────────────────────────
    def _set_actions_enabled(self, on):
        for b in self.act_btns:
            b.configure(state="normal" if on else "disabled")

    def _refresh_ports(self):
        ports = ["(auto)"] + [p.device for p in usb_ports()]
        self.port_cb["values"] = ports
        if not self.port_cb.get():
            self.port_cb.set(ports[0])

    def _toggle_conn(self):
        if self.connected:
            self.worker.disconnect()
        else:
            sel = self.port_cb.get()
            self.worker.connect(None if sel in ("", "(auto)") else sel)
            self.status.configure(text="connecting…", foreground="orange")

    def _progress_cb(self):
        def cb(done, total):
            self.ui_q.put(("progress", (done, total)))
        return cb

    def _simple(self, name, fn):
        self.worker.submit(name, fn)

    def _ping(self):
        def fn(link):
            ok = link.ping()
            self.ui_q.put(("log", "\n[app] ping: " +
                           ("A8OK\n" if ok else "NO REPLY\n")))
        self.worker.submit("ping", fn)

    def _send_file(self, run=False):
        path = filedialog.askopenfilename(
            title="Run .xex" if run else "Send file",
            filetypes=[("Atari files", "*.xex *.atr *.xfd *.car *.rom"),
                       ("Text (auto ATASCII EOLs)", "*.txt *.lst *.bas"),
                       ("All files", "*.*")])
        if not path:
            return
        data = open(path, "rb").read()
        if not run and path.lower().endswith((".txt", ".lst", ".bas")):
            # text destined for H:/ENTER needs ATASCII EOLs ($9B) — a raw \n
            # file reads from BASIC as one endless record
            data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\x9b")
        try:
            name = sd_name(path, None, self.dest.get().strip() or None)
        except LinkError as e:
            messagebox.showerror(APP_TITLE, str(e))
            return
        prog = self._progress_cb()
        if run:
            self.worker.submit(f"run {name}",
                               lambda l: l.run(data, name, prog))
        else:
            self.worker.submit(f"send {name}",
                               lambda l: l.send(data, name, prog))

    def _run_xex(self):
        self._send_file(run=True)

    def _type_text(self):
        text = self.type_box.get("1.0", "end-1c")
        if not text.strip():
            return
        prog = self._progress_cb()
        # type_lines = line-wise sessions with drop-recovery (the BL616's USB
        # link flaps under sustained per-char typing; whole-line retypes are
        # idempotent for numbered BASIC lines)
        self.worker.submit("type", lambda l: l.type_lines(text, prog))

    def _type_load(self):
        path = filedialog.askopenfilename(title="Load text/BASIC listing")
        if path:
            self.type_box.delete("1.0", "end")
            self.type_box.insert("1.0", open(path, "r", errors="replace").read())

    # live keys: focus opens a session; each KeyPress is queued as one key
    def _kbd_focus(self, _):
        if not self.connected:
            return
        self.kbd_zone.configure(background="#d0f0d0",
                                text="⌨  LIVE — keys go to the Atari")

        w = self.worker

        def fn(link):
            w.sess = link.kbd_session()
        w.submit("live keyboard on", fn)

    def _kbd_blur(self, _):
        self.kbd_zone.configure(background="#f0f0f0",
                                text="⌨  click here to type on the Atari")

        w = self.worker

        def fn(link):
            if w.sess:
                w.sess.end()
                w.sess = None
        w.submit("live keyboard off", fn)

    def _kbd_key(self, ev):
        ch = ev.char
        if ev.keysym == "Return":
            ch = "\n"
        elif ev.keysym == "BackSpace":
            ch = "\x08"
        elif ev.keysym == "Escape":
            ch = "\x1b"
        elif ev.keysym == "Tab":
            ch = "\t"
        if not ch:
            return "break"

        w = self.worker

        def fn(link):
            if w.sess:
                try:
                    w.sess.send_key(ch)
                except MenuTakeover:
                    w.sess = None
                    self.ui_q.put(("kbd_takeover", ()))
        w.submit("key", fn)
        return "break"

    def _log_append(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def _log_clear(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    def _prn_text(self):
        return self.prn.get("1.0", "end-1c")

    def _prn_save(self):
        path = filedialog.asksaveasfilename(
            defaultextension=".txt", title="Save printer output")
        if path:
            open(path, "w").write(self._prn_text())

    def _prn_pdf(self):
        text = self._prn_text()
        if not text.strip():
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".pdf", title="Save as 820-style PDF")
        if path:
            from dotmatrix_pdf import text_to_pdf
            pages = text_to_pdf(text, path)
            self._log_append(f"\n[app] PDF saved: {path} ({pages} page(s), "
                             f"5x7 dot matrix)\n")

    def _prn_print(self):
        import subprocess
        import tempfile
        text = self._prn_text()
        if not text.strip():
            return
        tmp = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
        tmp.write(text)
        tmp.close()
        try:
            if os.name == "nt":
                os.startfile(tmp.name, "print")
            else:
                subprocess.run(["lpr", tmp.name], check=True)
            self._log_append("\n[app] sent printer output to the system printer\n")
        except Exception as e:
            messagebox.showinfo(APP_TITLE,
                                f"No system printer path ({e}).\n"
                                f"Saved instead at: {tmp.name}")

    def _prn_clear(self):
        self.prn.configure(state="normal")
        self.prn.delete("1.0", "end")
        self.prn.configure(state="disabled")

    def _log_save(self):
        path = filedialog.asksaveasfilename(defaultextension=".log")
        if path:
            open(path, "w").write(self.log.get("1.0", "end"))

    # ── UI event pump ────────────────────────────────────────────────────────
    def _poll_ui(self):
        try:
            while True:
                kind, payload = self.ui_q.get_nowait()
                if kind == "connected":
                    port, alive = payload
                    self.connected = True
                    self.conn_btn.configure(text="Disconnect")
                    self.status.configure(
                        text=f"{port} — " + ("A8OK" if alive else "no ping reply"),
                        foreground="green" if alive else "orange")
                    self._set_actions_enabled(True)
                elif kind == "disconnected":
                    self.connected = False
                    self.conn_btn.configure(text="Connect")
                    self.status.configure(text="disconnected", foreground="gray")
                    self._set_actions_enabled(False)
                elif kind == "log":
                    self._log_append(payload[0])
                elif kind == "prn":
                    self.prn.configure(state="normal")
                    self.prn.insert("end", payload[0])
                    self.prn.see("end")
                    self.prn.configure(state="disabled")
                elif kind == "busy":
                    self.busy_lbl.configure(text=payload[0])
                elif kind == "done":
                    self.busy_lbl.configure(text=f"✓ {payload[0]}")
                    self.prog["value"] = 0
                elif kind == "progress":
                    done, total = payload
                    self.prog["value"] = done * 100 / max(total, 1)
                elif kind == "kbd_takeover":
                    self.root.focus_set()          # blur the capture zone
                    self._kbd_blur(None)
                    self._log_append("\n[app] Atari took the keyboard (F12)\n")
                elif kind == "error":
                    self.busy_lbl.configure(text="")
                    self.prog["value"] = 0
                    self._log_append(f"\n[app] ERROR: {payload[0]}\n")
                    if not self.connected:
                        self.status.configure(text="disconnected",
                                              foreground="gray")
        except queue.Empty:
            pass
        self.root.after(50, self._poll_ui)

    def _quit(self):
        self.worker.stop_flag = True
        self.worker.disconnect()
        self.root.after(150, self.root.destroy)


def _fix_tcl_env():
    """Defend tkinter against the Gowin IDE: it exports TCL_LIBRARY/TK_LIBRARY
    and puts its own libtcl on LD_LIBRARY_PATH, whose baked-in default script
    path (/tools/apps/tcl8.6.5/...) doesn't exist outside the IDE. Point the
    env vars at real system script dirs — an explicit TCL_LIBRARY overrides
    even a wrong compiled-in default."""
    import glob
    probes = {
        "TCL_LIBRARY": ("init.tcl", ["/usr/share/tcltk/tcl8*",
                                     "/usr/lib/tcl8*", "/usr/share/tcl8*"]),
        "TK_LIBRARY":  ("tk.tcl",   ["/usr/share/tcltk/tk8*",
                                     "/usr/lib/tk8*", "/usr/share/tk8*"]),
    }
    for var, (probe, patterns) in probes.items():
        v = os.environ.get(var)
        if v and os.path.isfile(os.path.join(v, probe)):
            continue                       # already valid
        for pat in patterns:
            hits = [d for d in sorted(glob.glob(pat))
                    if os.path.isfile(os.path.join(d, probe))]
            if hits:
                os.environ[var] = hits[-1]
                break
        else:
            if v:
                del os.environ[var]        # invalid and no replacement: drop


def main():
    _fix_tcl_env()
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
