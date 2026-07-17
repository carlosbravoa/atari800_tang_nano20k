# PC Link tools

Talk to the Atari over the board's own USB-C (firmware >= v2.5).

- **`atari_link.py`** — the protocol library (one implementation, shared).
- **`atari.py`** — CLI: `ports` `ping` `log` `send` `run` `type` `kbd` `eject` `reset`.
- **`atari_gui.py`** — desktop app (Linux/Windows): connect, send/run with progress,
  paste-to-BASIC, live keyboard, remote reset/eject, live firmware log pane.

## Setup

```bash
pip install pyserial
sudo apt install python3-tk        # GUI only (Windows: included with python.org builds)
sudo modprobe ftdi_sio             # Linux, if no /dev/ttyUSB* appears
python3 tools/atari_gui.py         # or tools/atari.py <command>
```

Windows: the FTDI VCP driver arrives via Windows Update automatically; the tools
auto-pick the right COM port (the second of the board's port pair).

Packaging single-file executables: `pyinstaller --onefile tools/atari_gui.py`
(planned as a CI artifact per release).
