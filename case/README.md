# 3D-printed case — Tang Nano 20K + CH9350

A parametric, two-part enclosure for this project's hardware: a **Sipeed Tang
Nano 20K** plus a **CH9350 USB-host keyboard module**, wired as in the main
[README](../README.md) (one data wire to Pin 53, GND + 5 V, DB9 joysticks on
GPIO pins).

| | |
|---|---|
| ![assembly](img/assembly.png) | ![base](img/base.png) |
| Exploded preview (lid floating) | Base tray |

## What's here

```
case/
├── tang_nano_20k_ch9350_case.scad   # the parametric model (edit this)
├── stl/
│   ├── base.stl       # the tray that holds both boards
│   ├── lid.stl        # snap-in lid (LED window + S1/S2 button holes)
│   └── fitcheck.stl   # thin test frame — PRINT THIS FIRST
└── img/               # rendered previews
```

## ⚠️ Read this first — these are datasheet dimensions, not a measured fit

I cannot physically measure your boards, so the model is built from published
dimensions:

| Board | Size used | Source |
|-------|-----------|--------|
| Tang Nano 20K | 54.04 × 22.55 × 1.6 mm | Sipeed datasheet |
| CH9350 module | 22.0 × 17.0 × 1.6 mm | module listings |

The **exact positions of the connectors, the S1/S2 buttons and the LEDs vary**
between board revisions and CH9350 vendors. So:

1. **Print `fitcheck.stl` first.** It's just the floor + low walls + the board
   shelves + the connector cutouts (~10–15 min, little plastic). Drop your
   boards in and check that the HDMI / USB-C / microSD / USB-A openings line up.
2. Adjust the variables at the top of the `.scad` (every dimension is one), then
   re-export and print the real `base.stl` + `lid.stl`.

The connector openings are intentionally a little generous; the parameters
flagged `ESTIMATE, calibrate` (button + LED window positions) are the most
likely to need nudging.

## Layout

Both boards lie flat in one tray:

- **Tang Nano 20K** along the front. **HDMI** exits the left short wall; **USB-C
  power** and the **microSD slot** exit the right short wall; **S1/S2** are
  reached through holes in the lid; the 4 status **LEDs** show through a window
  in the lid.
- **CH9350** sits behind it; its **USB-A** port (where you plug the keyboard)
  exits the back wall.
- A **cable-exit notch** in the back wall lets the DB9 joystick wires and the
  Pin-53 keyboard data wire run out to the GPIO header pins / external
  connectors.

Boards rest on a 4 mm perimeter shelf (clears the underside microSD slot and
solder joints) and are located by thin ribs; the lid presses down on top. No
screws — the lid lip is a friction fit (no mounting holes are needed, and the
Tang Nano 20K has none anyway).

Outer size with defaults: **≈ 60 × 48 × 27 mm**.

## Key parameters to tune

Open `tang_nano_20k_ch9350_case.scad` — everything is at the top:

| Variable | Meaning | When to change |
|----------|---------|----------------|
| `headroom` | clear height above the Tang PCB | **lower to ~8–10** if you don't have tall pin headers + Dupont wires; raise for chunky connectors |
| `standoff` | gap under the boards | increase if underside parts are tall |
| `clear` | XY fit slack around boards | loosen/tighten the board fit |
| `hdmi_*`, `usbc_*`, `sd_*`, `usba_*` | connector opening size/position | align to your board |
| `btn1_x/y`, `btn2_x/y` | S1/S2 lid holes | move over your actual buttons |
| `led_win_*` | LED window | resize/move over your LED row |
| `cable_slot_*` | rear wire-exit notch | widen / reposition for your wiring |
| `lip_clear` | lid-to-base fit | increase if the lid is too tight to close |

## Printing

| Setting | Suggestion |
|---------|------------|
| Material | PLA or PETG |
| Layer height | 0.2 mm |
| Walls / perimeters | 3 |
| Infill | 15–20 % |
| Supports | **none needed** — both parts print flat (base floor-down, lid plate-down) |
| Orientation | base: cavity up; lid: top plate on the bed, lip up |

## Re-generating the STLs

Requires [OpenSCAD](https://openscad.org/).

```bash
cd case
openscad -D 'part="base"'     -o stl/base.stl     tang_nano_20k_ch9350_case.scad
openscad -D 'part="lid"'      -o stl/lid.stl      tang_nano_20k_ch9350_case.scad
openscad -D 'part="fitcheck"' -o stl/fitcheck.stl tang_nano_20k_ch9350_case.scad
```

Open the `.scad` in the OpenSCAD GUI to preview/tweak interactively (the
`part="assembly"` default shows both boards ghosted inside the case).

## Notes & ideas

- DB9 joysticks: the notch just lets the Dupont wires escape. If you want
  panel-mounted DB9 sockets, widen a side wall and add rectangular cutouts
  (easy to add as another `cube()` subtraction in `wall_cutouts()`).
- The lid is a friction fit; if you prefer screws, add four corner bosses —
  ask and I can extend the model.
