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

part = "assembly";   // base | lid | fitcheck | assembly | section | closed
show_lid = true;     // assembly preview: set false to drop the floating lid

$fn = 56;

// -----------------------------------------------------------------------------
//  BOARD DIMENSIONS  (measure yours and adjust if needed)
// -----------------------------------------------------------------------------
tn_len    = 54.04;   // Tang Nano 20K length  (X, HDMI end .. USB-C end)
tn_wid    = 22.55;   // Tang Nano 20K width   (Y)
tn_thick  = 1.6;     // Tang Nano 20K PCB thickness

ch_len    = 49.6;    // CH9350 module length  (X)
ch_wid    = 20.5;    // CH9350 module width   (Y)
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

// CH9350 : STACKED DUAL USB-A host port (two ports one above the other)
usba_w      = 14.5;  // connector width
usba_h      = 16.5;  // connector height (tall: two stacked ports)
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

// Rear cable-exit slot (handy for the GND/5V/Pin-53 wires, or external wiring).
// Open notch in the top of the back wall.
cable_slot_w     = 18.0;
cable_slot_depth = 12.0;   // how far down from the wall top the notch goes
cable_slot_frac  = 0.24;   // centre along the back wall (0=HDMI end, 1=USB-C end)
cable_enable     = true;

// -----------------------------------------------------------------------------
//  LID STYLING (top view, rear -> front):
//    diagonal vent band  /  "ATARI 800" brand strip  /  Fuji logo + LED window
// -----------------------------------------------------------------------------
// Ventilation: a full-width band of 45-degree slots across the rear/top.
vent_enable   = true;
vent_margin   = 7.0;    // inset from the side edges (X)
vent_rear_gap = 6.0;    // gap from the rear edge (Y)
vent_band_h   = 14.0;   // band height (Y)
vent_slot_w   = 2.0;    // slot width
vent_pitch    = 3.6;    // perpendicular spacing between slots
vent_angle    = 45;     // slot angle (degrees)

// Brand strip (recessed panel + debossed text) just below the vents.
brand_enable = true;
brand_text   = "ATARI 800";
brand_cx     = 0;       // 0 = auto-centre on the lid
brand_cy     = 62.0;    // just below the rear vent band
brand_w      = 48.0;
brand_h      = 10.0;
brand_depth  = 0.8;
brand_txt_sz = 6.0;

// Fuji logo (lower centre/left, near the front).
logo_enable = true;
logo_w      = 19.0;
logo_h      = 15.0;
logo_cx     = 21.0;     // 0 = auto-centre
logo_cy     = 20.0;
logo_depth  = 0.8;
logo_raised = false;    // false = debossed (prints clean lid-face-down)

// Sloped/beveled front-top edge.
front_bevel = 4.5;      // 45-degree chamfer leg on the front-top edge (0 = none)
front_inset = 9.0;      // keep the bevel clear of the front corner screw lugs

// -----------------------------------------------------------------------------
//  DB9 JOYSTICK PORTS  (panel-mount female D-sub, one per side wall)
//  Joy1 -> left short wall (-X, HDMI end), Joy2 -> right short wall (+X).
//  Each cutout = a D-shaped aperture + two M3 screw holes (24.99 mm pitch).
//  Wire the socket solder cups internally to the GPIO joystick pins
//  (see the main README "Atari DB9 Joystick" wiring table).
// -----------------------------------------------------------------------------
db9_enable      = true;
db9_zone        = 38.0;   // depth (Y) of the rear bay that holds the DB9s + CH9350
db9_apt_w       = 16.8;   // D aperture: wide dimension (along the screw axis / Y)
db9_apt_w2      = 14.6;   // D aperture: narrow side (the chamfered "D")
db9_apt_h       = 9.8;    // D aperture height (along Z)
db9_screw_pitch = 24.99;  // mounting-hole centre-to-centre (D-sub standard)
db9_screw_d     = 3.2;    // mounting-hole diameter (M3 / #4-40 clearance)
db9_y_off       = 0;      // nudge both ports along the wall (Y)
db9_z_frac      = 0.55;   // vertical centre of the ports as a fraction of height
db9_body_depth  = 14.0;   // how far the connector body protrudes inward (preview
                          // + CH9350 clearance reference; not printed)

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
conn_drop = 1.0;    // edge connectors sit ABOVE the PCB; opening starts this
                    // far below the PCB top and extends up by its height

ledge_w   = 2.0;    // width of the perimeter shelf the boards rest on
rib_h     = 2.5;    // height of locating ribs above the board top
fillet    = 2.0;    // outer vertical edge rounding

lip_depth = 6.0;    // how deep the lid lip plugs into the base
lip_clear = 0.35;   // clearance so the lid lip slides in

// -----------------------------------------------------------------------------
//  SCREW-DOWN LID  (four external corner lugs; M3 self-tapping)
//  The interior is packed (boards + DB9 bodies), so the lugs sit OUTSIDE the
//  corners. Base lugs get a pilot hole; lid lugs a counterbored clearance hole.
//  Use 4x M3 self-tapping screws ~12-16 mm long (or M3 machine screws into
//  heat-set inserts — open up screw_pilot_d to the insert's bore).
// -----------------------------------------------------------------------------
screw_enable  = true;
lug_r         = 4.4;    // corner lug radius
lug_off       = 1.6;    // how far the lug centre sits outside each corner (/axis)
screw_pilot_d = 2.6;    // base pilot hole (M3 self-tap into PLA/PETG)
screw_clear_d = 3.4;    // lid through-hole (M3 clearance)
screw_head_d  = 6.2;    // lid counterbore diameter (screw head)
screw_head_h  = 2.4;    // lid counterbore depth

// -----------------------------------------------------------------------------
//  DERIVED GEOMETRY
// -----------------------------------------------------------------------------
// Interior cavity. Front-to-back: Tang (front) | CH9350 (middle) | DB9 bay
// (rear). Tang ends are pinned to the -X/+X walls for HDMI / USB-C. The CH9350
// is nearly full width, so the DB9 joystick ports get their own bay behind it.
inner_x = tn_len + 2*clear;                       // along X (pinned to board)
inner_y = db9_enable ? (tn_wid + gap_y + ch_wid + db9_zone + 2*clear)
                     : (tn_wid + gap_y + ch_wid + 2*clear);
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

// CH9350: long axis along X, right-aligned so its short-end dual-USB stack sits
// against the +X wall; placed in the middle band behind the Tang.
ch_x0 = out_x - wall - clear - ch_len;
ch_y0 = tn_y0 + tn_wid + gap_y;
ch_z0 = floor_th + standoff;
ch_top = ch_z0 + ch_thick;

// DB9 ports: centred in the rear bay (behind the CH9350), on both side walls.
db9_y = ((ch_y0 + ch_wid) + (wall + inner_y)) / 2 + db9_y_off;
db9_z = base_h * db9_z_frac;

// Corner screw-lug centres (just outside each corner so they miss the boards).
lug_pts = [[-lug_off, -lug_off], [out_x + lug_off, -lug_off],
           [out_x + lug_off, out_y + lug_off], [-lug_off, out_y + lug_off]];

// =============================================================================
//  HELPER MODULES
// =============================================================================

// Rounded-rectangle vertical prism (for the outer shell)
module rrect_prism(sx, sy, sz, r) {
    hull() for (mx = [r, sx-r], my = [r, sy-r])
        translate([mx, my, 0]) cylinder(h = sz, r = r);
}

// Four solid corner lugs (height h), blended into the corner with a small gusset.
module corner_lugs(h) {
    if (screw_enable)
        for (p = lug_pts) translate([p[0], p[1], 0]) cylinder(h = h, r = lug_r);
}

// Full-width band of parallel 45-degree ventilation slots across the rear/top,
// clipped to the band rectangle.
module vent_slots(depth) {
    vy1 = out_y - vent_rear_gap;
    vy0 = vy1 - vent_band_h;
    vx0 = vent_margin;
    vx1 = out_x - vent_margin;
    r   = vent_slot_w/2;
    dx  = vent_pitch / sin(vent_angle);          // horizontal step for slot pitch
    L   = (vx1 - vx0) + vent_band_h + 10;        // slot length (clipped to band)
    yc  = (vy0 + vy1)/2;
    intersection() {
        union()
            for (x = [vx0 - vent_band_h : dx : vx1 + vent_band_h])
                translate([x, yc, -1])
                    linear_extrude(depth + 2)
                        rotate(vent_angle)
                            hull() for (s = [-L/2, L/2]) translate([s, 0]) circle(r);
        translate([vx0, vy0, -2]) cube([vx1 - vx0, vy1 - vy0, depth + 4]);
    }
}

// Atari "Fuji" logo (straight centre bar + two flaring side prongs on a base),
// resize()-d to logo_w x logo_h where it is used.
module fuji_2d() {
    d = 11; H = 15; Ri = d; Ro = d + H; off = 15; hw = 6.0; cw = 3.0;
    intersection() {
        union() {
            translate([-cw/2, 0]) square([cw, H]);
            for (s = [-1, 1]) {
                ac = 90 + s*off;
                intersection() {
                    difference() {
                        translate([0, -d]) circle(Ro);
                        translate([0, -d]) circle(Ri);
                    }
                    polygon([[0, -d],
                             [Ro*1.5*cos(ac - hw), -d + Ro*1.5*sin(ac - hw)],
                             [Ro*1.5*cos(ac + hw), -d + Ro*1.5*sin(ac + hw)]]);
                }
            }
            translate([0, 1.1]) square([2*Ro*cos(90 - off - hw) + 1, 2.2], center = true);
        }
        translate([-Ro*1.5, 0]) square([Ro*3, H*1.3]);
    }
}
module fuji_solid(h) {
    cx = (logo_cx == 0) ? out_x/2 : logo_cx;
    translate([cx, logo_cy, 0])
        linear_extrude(height = h)
            resize([logo_w, logo_h], auto = true)
                translate([0, 0.4]) fuji_2d();
}

// 45-degree chamfer along the front-top edge of the CLOSED case (absolute Z),
// kept clear of the corner lugs. Applied to base() and (shifted) to lid().
module front_bevel_cut() {
    if (front_bevel > 0) {
        zt = base_h + lid_th;
        s  = front_bevel * sqrt(2);
        translate([out_x/2, 0, zt]) rotate([45, 0, 0])
            cube([out_x - 2*front_inset, s, s], center = true);
    }
}

// Recessed brand strip (rounded panel + debossed text) cut into the lid top.
module brand_cut() {
    if (brand_enable) {
        bx = (brand_cx == 0) ? out_x/2 : brand_cx;
        translate([bx, brand_cy, lid_th - brand_depth])
            linear_extrude(brand_depth + 1)
                offset(r = 1.2) square([brand_w - 2.4, brand_h - 2.4], center = true);
        if (brand_text != "")
            translate([bx, brand_cy, lid_th - brand_depth - 0.4])
                linear_extrude(brand_depth + 1.4)
                    text(brand_text, size = brand_txt_sz, font = "Liberation Sans:style=Bold",
                         halign = "center", valign = "center");
    }
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

// D-sub DB9 cutout, built along +X (depth d), centred at local Y=0, Z=0:
// a D-shaped aperture (wide top, narrow bottom) + two screw holes on the
// horizontal centreline at the standard 24.99 mm pitch.
module db9_shape(d) {
    hull() {
        translate([0, -db9_apt_w/2,   db9_apt_h/2 - 1]) cube([d, db9_apt_w, 1]);
        translate([0, -db9_apt_w2/2, -db9_apt_h/2])     cube([d, db9_apt_w2, 1]);
    }
    for (s = [-1, 1])
        translate([0, s*db9_screw_pitch/2, 0]) rotate([0, 90, 0])
            cylinder(h = d, d = db9_screw_d);
}

// =============================================================================
//  CUTOUTS  (subtracted from the base walls)
// =============================================================================
module wall_cutouts() {
    // --- Tang HDMI : -X wall, centred on Tang width (opening above PCB) ---
    hdmi_cy = tn_y0 + tn_wid/2 + hdmi_y_off;
    translate([-1, hdmi_cy - hdmi_w/2, tn_top - conn_drop])
        cube([wall + 2, hdmi_w, hdmi_h]);

    // --- Tang USB-C : +X wall (opening above PCB) ---
    usbc_cy = tn_y0 + tn_wid/2 + usbc_y_off;
    translate([out_x - wall - 1, usbc_cy - usbc_w/2, tn_top - conn_drop])
        cube([wall + 2, usbc_w, usbc_h]);

    // --- Tang microSD : +X wall, at board underside ---
    if (sd_enable) {
        sd_cy = tn_y0 + tn_wid/2 + sd_y_off;
        translate([out_x - wall - 1, sd_cy - sd_w/2, tn_z0 - sd_h/2])
            cube([wall + 2, sd_w, sd_h + 1]);
    }

    // --- CH9350 dual USB-A : +X side wall, in the CH9350 band (above PCB) ---
    usba_cy = ch_y0 + ch_wid/2;
    translate([out_x - wall - 1, usba_cy - usba_w/2, ch_top + usba_z_off - conn_drop])
        cube([wall + 2, usba_w, usba_h]);

    // --- Rear cable-exit notch : open slot in the top of the +Y wall ---
    if (cable_enable) {
        slot_cx = tn_x0 + tn_len*cable_slot_frac;
        translate([slot_cx - cable_slot_w/2, out_y - wall - 1,
                   base_h - cable_slot_depth])
            cube([cable_slot_w, wall + 2, cable_slot_depth + 1]);
    }

    // --- DB9 joystick ports : one on each short side wall, in the rear bay ---
    if (db9_enable) {
        translate([-1,             db9_y, db9_z]) db9_shape(wall + 2);  // Joy1 (-X)
        translate([out_x - wall - 1, db9_y, db9_z]) db9_shape(wall + 2);  // Joy2 (+X)
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
            corner_lugs(base_h);
            // board support shelves
            support_ledge(tn_x0, tn_y0, tn_len, tn_wid, floor_th, tn_z0, ledge_w);
            support_ledge(ch_x0, ch_y0, ch_len, ch_wid, floor_th, ch_z0, ledge_w);
            // locating ribs (keep boards from sliding; leave connector edges clear)
            locate_rib(tn_x0, tn_y0, tn_len, tn_wid, tn_z0, tn_top + rib_h, "ymax");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "ymin");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "ymax");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "xmin");
        }
        wall_cutouts();
        front_bevel_cut();
        // pilot holes in the corner lugs (leave the floor solid)
        if (screw_enable)
            for (p = lug_pts) translate([p[0], p[1], floor_th])
                cylinder(h = base_h, d = screw_pilot_d);
    }
}

// =============================================================================
//  LID  (plate + downward lip that plugs into the base cavity)
// =============================================================================
module lid() {
    difference() {
        union() {
            rrect_prism(out_x, out_y, lid_th, fillet);          // top plate
            corner_lugs(lid_th);                                // screw lugs
            translate([wall + lip_clear, wall + lip_clear, -lip_depth])
                cube([inner_x - 2*lip_clear, inner_y - 2*lip_clear, lip_depth]);
            // embossed (raised) Fuji logo on the top face
            if (logo_enable && logo_raised)
                translate([0, 0, lid_th - 0.01]) fuji_solid(logo_depth);
        }
        // ventilation slots (through the plate)
        if (vent_enable) vent_slots(lid_th);
        // 65XE front bevel + recessed brand strip
        translate([0, 0, -base_h]) front_bevel_cut();
        brand_cut();
        // debossed (recessed) Fuji logo in the top face
        if (logo_enable && !logo_raised)
            translate([0, 0, lid_th - logo_depth]) fuji_solid(logo_depth + 1);
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
        // counterbored clearance holes through the corner lugs
        if (screw_enable)
            for (p = lug_pts) translate([p[0], p[1], -1]) {
                cylinder(h = lid_th + 2, d = screw_clear_d);
                translate([0, 0, lid_th - screw_head_h + 1])
                    cylinder(h = screw_head_h + 1, d = screw_head_d);
            }
    }
}

// =============================================================================
//  FIT-CHECK  (thin test frame: floor + low walls + shelves + cutouts)
//  Print this first to confirm board fit & connector alignment.
// =============================================================================
module fitcheck() {
    // tall enough to include the DB9 ports when they are enabled
    fc_h = db9_enable ? (db9_z + db9_apt_h/2 + db9_screw_d/2 + 3)
                      : (floor_th + standoff + tn_thick + 3);
    intersection() {
        base();
        translate([-1, -1, -1]) cube([out_x + 2, out_y + 2, fc_h + 1]);
    }
}

// =============================================================================
//  SECTION  (cutaway through the Tang, lid closed) — shows how it all stacks:
//  floor -> standoff gap -> shelf + PCB -> headroom -> closed lid.
// =============================================================================
module boards_ghost() {
    color([0.10, 0.55, 0.20]) translate([tn_x0, tn_y0, tn_z0])
        cube([tn_len, tn_wid, tn_thick]);
    color([0.20, 0.20, 0.75]) translate([ch_x0, ch_y0, ch_z0])
        cube([ch_len, ch_wid, ch_thick]);
}
module section() {
    cut_y = tn_y0 + tn_wid*0.6;
    difference() {
        union() {
            color("DarkSlateGray") base();
            boards_ghost();
            color([0.7, 0.7, 0.7]) translate([0, 0, base_h]) lid();  // closed
        }
        translate([-60, cut_y, -60])
            cube([out_x + 120, out_y + 120, base_h + 120]);          // keep front
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
    // ghost DB9 connector bodies (shows inward protrusion / CH9350 clearance)
    if (db9_enable)
        color([0.3, 0.3, 0.3, 0.7]) for (sx = [wall, out_x - wall - db9_body_depth])
            translate([sx, db9_y - 15.5, db9_z - 6.5])
                cube([db9_body_depth, 31, 13]);
    // lid floating above
    if (show_lid)
        color([0.6, 0.6, 0.6, 0.55])
            translate([0, 0, base_h + 14]) lid();
}

// -----------------------------------------------------------------------------
if (part == "base")          base();
else if (part == "lid")      lid();
else if (part == "fitcheck") fitcheck();
else if (part == "section")  section();
else if (part == "closed") { color("DarkSlateGray") base();
                             color([0.7,0.7,0.7]) translate([0,0,base_h]) lid(); }
else                         assembly();
