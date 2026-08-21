# `ref/` — transplanted geometry (third-party)

`louvre_tile.stl` is **not original work**. It is one 4.0 mm pitch of the
ventilation comb, cut directly out of

> **Enclosure v1.12, Atari-Compatible eclaire Mini** — by **wt808**
> https://www.thingiverse.com/thing:3562690
> Licensed **CC BY-NC-SA** (Attribution — NonCommercial — ShareAlike)

specifically from `v1.12eclaire800top.stl`.

**Changes made:** the mesh was repaired to watertight (a handful of unclosed
edges in the original), then sliced to a single 4.0 mm pitch through the centre
of a rib at each end so it tiles seamlessly, and trimmed in depth and height to
suit this much smaller case. It is re-tiled and re-oriented by
`tang_nano_20k_ch9350_case.scad`; the geometry itself is unmodified.

**Consequence:** the enclosure in `case/` is an **Adapted Work** and is licensed
**CC BY-NC-SA 4.0 only**. ShareAlike requires it, and the repository's
`GPL-3.0-or-later` option therefore does **not** extend to `case/`.
See `../README.md` for the full notice.
