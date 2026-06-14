// =============================================================================
//  3D-printed case for the Atari800 Tang Nano 20K port
//  Houses a Sipeed Tang Nano 20K + a CH9350 USB-host keyboard module,
//  wired as described in the project README (one data wire to Pin 53,
//  GND + 5V, DB9 joysticks on GPIO pins).
//
//  Parametric OpenSCAD model.  EVERY dimension below is a variable so you
//  can calibrate it to your exact boards.  The defaults come from the
//  published datasheets:
//     Tang Nano 20K PCB  : 54.04 x 22.55 x ~1.6 mm
//     CH9350 module PCB  : 22.0  x 17.0  x ~1.6 mm
//
//  >>> READ case/README.md BEFORE PRINTING <<<
//  Print the "fitcheck" part first (a thin frame, ~10 min) to verify the
//  board pocket and the connector cutouts line up with YOUR hardware,
//  then print base + lid.
//
//  Render a single part from the command line, e.g.:
//     openscad -D 'part="base"'     -o base.stl  tang_nano_20k_ch9350_case.scad
//     openscad -D 'part="lid"'      -o lid.stl   tang_nano_20k_ch9350_case.scad
//     openscad -D 'part="fitcheck"' -o fit.stl   tang_nano_20k_ch9350_case.scad
//     openscad -D 'part="assembly"' ...                 (preview only)
// =============================================================================

part = "assembly";   // "base" | "lid" | "fitcheck" | "assembly"

$fn = 56;

// -----------------------------------------------------------------------------
//  BOARD DIMENSIONS  (measure yours and adjust if needed)
// -----------------------------------------------------------------------------
tn_len    = 54.04;   // Tang Nano 20K length  (X, HDMI end .. USB-C end)
tn_wid    = 22.55;   // Tang Nano 20K width   (Y)
tn_thick  = 1.6;     // Tang Nano 20K PCB thickness

ch_len    = 22.0;    // CH9350 module length  (X)
ch_wid    = 17.0;    // CH9350 module width   (Y)
ch_thick  = 1.6;     // CH9350 module PCB thickness

// -----------------------------------------------------------------------------
//  CONNECTOR / FEATURE CUTOUTS  (opening size = connector + clearance)
//  All offsets are measured along the relevant edge from the board's
//  reference corner; positive = toward +X / +Y / +Z. Tune to taste.
// -----------------------------------------------------------------------------
// Tang Nano 20K : HDMI Type-A on the -X short end (centred on width)
hdmi_w      = 16.5;  // opening width  (along Y)
hdmi_h      = 9.0;   // opening height (along Z)
hdmi_y_off  = 0;     // shift along Y from board centre (+ = toward back)

// Tang Nano 20K : USB-C on the +X short end (centred on width)
usbc_w      = 12.0;
usbc_h      = 6.0;
usbc_y_off  = 0;

// Tang Nano 20K : microSD / TF slot, also on the +X end, below the PCB
//   (card is inserted under the board). Slot sits at the board bottom.
sd_w        = 14.0;  // opening width  (along Y)
sd_h        = 3.0;   // opening height (along Z)
sd_y_off    = 0;
sd_enable   = true;

// CH9350 : USB-A female host port faces the +Y (back) wall
usba_w      = 14.0;
usba_h      = 8.0;
usba_z_off  = 0;     // raise/lower the opening relative to the CH9350 PCB top

// Top-lid push holes over the Tang Nano S1 / S2 buttons (near the USB-C end).
// Positions are in Tang board coordinates (x from HDMI end, y from front edge).
btn_hole_d  = 4.5;
btn1_x      = 49.0;  btn1_y = 6.0;    // S1 (reset)  -- ESTIMATE, calibrate
btn2_x      = 49.0;  btn2_y = 16.0;   // S2 (OSD)    -- ESTIMATE, calibrate
btn_enable  = true;

// LED viewing window in the lid (the 4 status LEDs sit near the USB-C end).
led_win_x   = 40.0;  // start (Tang X)   -- ESTIMATE, calibrate
led_win_len = 12.0;  // length along X
led_win_y   = 2.0;   // start (Tang Y)
led_win_wid = 18.5;  // width along Y
led_enable  = true;

// Rear cable-exit slot (for DB9 joystick wires + the keyboard data wire that
// plug onto the GPIO header pins). Open notch in the top of the back wall.
cable_slot_w     = 30.0;
cable_slot_depth = 14.0;   // how far down from the wall top the notch goes
cable_slot_frac  = 0.30;   // centre along the back wall (0=HDMI end, 1=USB-C end)
cable_enable     = true;

// -----------------------------------------------------------------------------
//  CASE BODY
// -----------------------------------------------------------------------------
wall      = 2.4;    // side-wall thickness
floor_th  = 1.8;    // base floor thickness
lid_th    = 2.0;    // lid top-plate thickness

standoff  = 4.0;    // gap under the boards (clears underside parts/solder/SD)
headroom  = 18.0;   // clear height ABOVE the Tang PCB top: room for soldered
                    // pin headers + Dupont connectors + wire bend.
                    // Lower this (e.g. 8-10) if you use low-profile/no headers.

clear     = 0.4;    // XY fit clearance around each board
gap_y     = 3.0;    // gap between the Tang board and the CH9350 board

ledge_w   = 2.0;    // width of the perimeter shelf the boards rest on
rib_h     = 2.5;    // height of locating ribs above the board top
fillet    = 2.0;    // outer vertical edge rounding

lip_depth = 6.0;    // how deep the lid lip plugs into the base
lip_clear = 0.35;   // clearance so the lid lip slides in

// -----------------------------------------------------------------------------
//  DERIVED GEOMETRY
// -----------------------------------------------------------------------------
// Interior cavity (boards laid out: Tang along the front, CH9350 behind it)
inner_x = tn_len + 2*clear;                       // along X
inner_y = tn_wid + gap_y + ch_wid + 2*clear;      // along Y
inner_h = standoff + tn_thick + headroom;         // floor-top .. wall-top

out_x = inner_x + 2*wall;
out_y = inner_y + 2*wall;
base_h = floor_th + inner_h;

// Board reference origins (board's -X/-Y corner) in case interior coords,
// where interior coords start at (wall, wall, floor_th).
tn_x0 = wall + clear;
tn_y0 = wall + clear;
tn_z0 = floor_th + standoff;                 // PCB underside height
tn_top = tn_z0 + tn_thick;                   // PCB top height

ch_x0 = out_x - wall - clear - ch_len - 4;   // near the +X / USB-C end
ch_y0 = tn_y0 + tn_wid + gap_y;              // behind the Tang board
ch_z0 = floor_th + standoff;
ch_top = ch_z0 + ch_thick;

// =============================================================================
//  HELPER MODULES
// =============================================================================

// Rounded-rectangle vertical prism (for the outer shell)
module rrect_prism(sx, sy, sz, r) {
    hull() for (mx = [r, sx-r], my = [r, sy-r])
        translate([mx, my, 0]) cylinder(h = sz, r = r);
}

// A flat shelf the board rests on: an outer frame minus an inner window,
// so only the board perimeter is supported (centre stays open).
module support_ledge(x0, y0, bx, by, z_bottom, z_top, w) {
    translate([x0 - w, y0 - w, z_bottom])
        difference() {
            cube([bx + 2*w, by + 2*w, z_top - z_bottom]);
            translate([w, w, -1])
                cube([bx, by, z_top - z_bottom + 2]);
        }
}

// Thin locating rib running along one board edge, sitting just outside the
// board so the PCB cannot slide. side: "xmin" "xmax" "ymin" "ymax".
module locate_rib(x0, y0, bx, by, z_bottom, z_top, side, len_frac=1) {
    t = 1.4;                                  // rib thickness
    if (side == "ymax")
        translate([x0, y0 + by + clear, z_bottom])
            cube([bx, t, z_top - z_bottom]);
    if (side == "ymin")
        translate([x0, y0 - clear - t, z_bottom])
            cube([bx, t, z_top - z_bottom]);
    if (side == "xmax")
        translate([x0 + bx + clear, y0, z_bottom])
            cube([t, by, z_top - z_bottom]);
    if (side == "xmin")
        translate([x0 - clear - t, y0, z_bottom])
            cube([t, by, z_top - z_bottom]);
}

// =============================================================================
//  CUTOUTS  (subtracted from the base walls)
// =============================================================================
module wall_cutouts() {
    // --- Tang HDMI : -X wall, centred on Tang width ---
    hdmi_cy = tn_y0 + tn_wid/2 + hdmi_y_off;
    translate([-1, hdmi_cy - hdmi_w/2, tn_top - hdmi_h + 1.0])
        cube([wall + 2, hdmi_w, hdmi_h]);

    // --- Tang USB-C : +X wall ---
    usbc_cy = tn_y0 + tn_wid/2 + usbc_y_off;
    translate([out_x - wall - 1, usbc_cy - usbc_w/2, tn_top - usbc_h + 1.0])
        cube([wall + 2, usbc_w, usbc_h]);

    // --- Tang microSD : +X wall, at board underside ---
    if (sd_enable) {
        sd_cy = tn_y0 + tn_wid/2 + sd_y_off;
        translate([out_x - wall - 1, sd_cy - sd_w/2, tn_z0 - sd_h/2])
            cube([wall + 2, sd_w, sd_h + 1]);
    }

    // --- CH9350 USB-A : +Y (back) wall ---
    usba_cx = ch_x0 + ch_len/2;
    translate([usba_cx - usba_w/2, out_y - wall - 1, ch_top + usba_z_off - usba_h + 1.0])
        cube([usba_w, wall + 2, usba_h]);

    // --- Rear cable-exit notch : open slot in the top of the +Y wall ---
    if (cable_enable) {
        slot_cx = tn_x0 + tn_len*cable_slot_frac;
        translate([slot_cx - cable_slot_w/2, out_y - wall - 1,
                   base_h - cable_slot_depth])
            cube([cable_slot_w, wall + 2, cable_slot_depth + 1]);
    }
}

// =============================================================================
//  BASE
// =============================================================================
module base() {
    difference() {
        union() {
            // outer shell, hollowed into a tray
            difference() {
                rrect_prism(out_x, out_y, base_h, fillet);
                translate([wall, wall, floor_th])
                    cube([inner_x, inner_y, base_h]);   // open-top cavity
            }
            // board support shelves
            support_ledge(tn_x0, tn_y0, tn_len, tn_wid, floor_th, tn_z0, ledge_w);
            support_ledge(ch_x0, ch_y0, ch_len, ch_wid, floor_th, ch_z0, ledge_w);
            // locating ribs (keep boards from sliding; leave connector edges clear)
            locate_rib(tn_x0, tn_y0, tn_len, tn_wid, tn_z0, tn_top + rib_h, "ymax");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "ymin");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "xmin");
        }
        wall_cutouts();
    }
}

// =============================================================================
//  LID  (plate + downward lip that plugs into the base cavity)
// =============================================================================
module lid() {
    difference() {
        union() {
            rrect_prism(out_x, out_y, lid_th, fillet);          // top plate
            translate([wall + lip_clear, wall + lip_clear, -lip_depth])
                cube([inner_x - 2*lip_clear, inner_y - 2*lip_clear, lip_depth]);
        }
        // hollow the lip so it is a thin rim (saves plastic, clears parts)
        translate([wall + lip_clear + 2, wall + lip_clear + 2, -lip_depth - 1])
            cube([inner_x - 2*lip_clear - 4, inner_y - 2*lip_clear - 4,
                  lip_depth + 1]);

        // S1 / S2 button push-holes
        if (btn_enable) {
            translate([tn_x0 + btn1_x, tn_y0 + btn1_y, -1])
                cylinder(h = lid_th + 2, d = btn_hole_d);
            translate([tn_x0 + btn2_x, tn_y0 + btn2_y, -1])
                cylinder(h = lid_th + 2, d = btn_hole_d);
        }
        // LED window
        if (led_enable)
            translate([tn_x0 + led_win_x, tn_y0 + led_win_y, -1])
                cube([led_win_len, led_win_wid, lid_th + 2]);
        // keep the rear cable notch open through the lid lip too
        if (cable_enable) {
            slot_cx = tn_x0 + tn_len*cable_slot_frac;
            translate([slot_cx - cable_slot_w/2, out_y - wall - lip_clear - 3,
                       -lip_depth - 1])
                cube([cable_slot_w, wall + lip_clear + 5, lip_depth + 2]);
        }
    }
}

// =============================================================================
//  FIT-CHECK  (thin test frame: floor + low walls + shelves + cutouts)
//  Print this first to confirm board fit & connector alignment.
// =============================================================================
module fitcheck() {
    fc_h = floor_th + standoff + tn_thick + 3;   // just above the PCB top
    intersection() {
        base();
        translate([-1, -1, -1]) cube([out_x + 2, out_y + 2, fc_h + 1]);
    }
}

// =============================================================================
//  ASSEMBLY PREVIEW
// =============================================================================
module assembly() {
    color("DarkSlateGray") base();
    // ghost boards
    color([0.1, 0.5, 0.2, 0.85])
        translate([tn_x0, tn_y0, tn_z0]) cube([tn_len, tn_wid, tn_thick]);
    color([0.2, 0.2, 0.7, 0.85])
        translate([ch_x0, ch_y0, ch_z0]) cube([ch_len, ch_wid, ch_thick]);
    // lid floating above
    color([0.6, 0.6, 0.6, 0.55])
        translate([0, 0, base_h + 14]) lid();
}

// -----------------------------------------------------------------------------
if (part == "base")          base();
else if (part == "lid")      lid();
else if (part == "fitcheck") fitcheck();
else                         assembly();
