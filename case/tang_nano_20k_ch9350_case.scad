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
//  PRINT FOUR PARTS: base + lid + the two removable END CAPS (the short walls
//  are separate so the board can actually be fitted). Render each with:
//     openscad -D 'part="base"'        -o base.stl        <file>
//     openscad -D 'part="lid"'         -o lid.stl         <file>
//     openscad -D 'part="endcap_hdmi"' -o endcap_hdmi.stl <file>   (-X end)
//     openscad -D 'part="endcap_usbc"' -o endcap_usbc.stl <file>   (+X end)
//     openscad -D 'part="fitcheck"'    -o fit.stl         <file>   (test first)
//     openscad -D 'part="assembly"' ...                 (preview only)
// =============================================================================

part = "assembly";   // base | lid | endcap_hdmi | endcap_usbc | fitcheck |
                     // assembly | section | closed
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
// Tang Nano 20K : HDMI on the -X short end (centred on width). Openings are
// sized to clear the mating PLUG/cable, not just the board connector, and FDM
// prints tend to come out undersized — so these are deliberately generous.
hdmi_w      = 17.0;  // opening width  (along Y)
hdmi_h      = 11.0;  // opening height (along Z)
hdmi_y_off  = 0;     // shift along Y from board centre (+ = toward back)

// Tang Nano 20K : USB-C on the +X short end (centred on width)
usbc_w      = 13.0;  // clears the USB-C plug + its overmould
usbc_h      = 7.0;
usbc_y_off  = 0;

// Tang Nano 20K : microSD / TF slot. On the underside at the USB-C (+X) END;
//   with the board flipped pins-up it faces UP, so the opening sits just ABOVE
//   the PCB on the +X wall. It is NOT centred: its right edge ~aligns with the
//   USB-C socket and it extends to the side (hence sd_y_off). The opening also
//   reaches DOWN to overlap the USB-C cutout, so no thin wall is left between
//   them (one clean stepped opening). Confirm sd_y_off sign/size on the fitcheck.
sd_w        = 15.0;  // opening width  (along Y) — generous for card + fingers
sd_h        = 3.5;   // how far the opening rises above the PCB top (along Z)
sd_y_off    = -1.5;  // offset from board centre (right edge aligns with USB-C)
sd_enable   = true;

// CH9350 : STACKED DUAL USB-A host port (two ports one above the other)
usba_w      = 16.0;  // connector width + plug clearance
usba_h      = 18.0;  // connector height (tall: two stacked ports)
usba_z_off  = 0;     // raise/lower the opening relative to the CH9350 PCB top

// FLOOR push holes for the Tang Nano S1 / S2 buttons. The board is mounted
// component-side-DOWN, so the buttons face the floor and are poked from below.
// From the board photo: both buttons sit at the USB-C end on OPPOSITE long
// edges. Coords are board-local (x from HDMI end, y from the front/-Y edge);
// the pins-up mount preserves board Y, so they map straight through (no mirror).
// S1 is on the FRONT (-Y) edge with the LEDs; S2 on the back edge.
btn_hole_d  = 4.5;
btn1_x      = 49.0;  btn1_y = 5.0;     // S1: 5 mm from USB-C end, 5 mm off front edge
btn2_x      = 49.0;  btn2_y = 17.55;   // S2: 5 mm from USB-C end, 5 mm off back edge
btn_enable  = true;

// LED row in the FLOOR, IN LINE with S1: after S1, a 3.5 mm gap, then 6 LEDs
// spanning 8.5 mm toward the HDMI end. Same Y as S1 (collinear), front edge.
led_win_x   = 35.25; // start (Tang X, from HDMI end) -> row runs 35.25..43.75
led_win_len = 8.5;   // length along X (the 6-LED span)
led_win_y   = 4.0;   // start (Tang Y) -> centred on the S1 line (btn1_y = 5)
led_win_wid = 2.0;   // width along Y
led_enable  = true;
// Extra slot in the FRONT (-Y) wall aligned with the LED row, to also see the
// down-facing LEDs from the side. Reaches back through the shelf to the LEDs.
led_side_enable = true;
led_side_h      = 6.0;   // slot height (Z), top aligned with the PCB underside

// Rear cable-exit slot (handy for the GND/5V/Pin-53 wires, or external wiring).
// Open notch in the top of the back wall.
cable_slot_w     = 18.0;
cable_slot_depth = 12.0;   // how far down from the wall top the notch goes
cable_slot_frac  = 0.24;   // centre along the back wall (0=HDMI end, 1=USB-C end)
cable_enable     = false;  // OFF: power is via USB-C and the GND/5V/Pin-53 lines
                           // are internal jumpers between the two boards, so no
                           // wires need to leave the case. Set true to reopen it.

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
db9_apt_w       = 18.5;   // D aperture: wide dimension (along the screw axis / Y)
db9_apt_w2      = 16.2;   // D aperture: narrow side (the chamfered "D")
db9_apt_h       = 11.0;   // D aperture height (along Z)
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

standoff  = 8.0;    // gap UNDER the Tang PCB. The board is component-side-down,
                    // so this gap houses the down-facing HDMI / USB-C connectors
                    // (HDMI is the tallest) plus the buttons/LEDs. Must be >=
                    // ~ hdmi_h - conn_drop - floor_th for the HDMI hole to clear
                    // the floor. The CH9350 shares this height (kept coplanar).
headroom  = 20.0;   // clear height ABOVE the Tang PCB top: the GPIO pin headers
                    // now point UP into here. Measured pin+Dupont stack ~17 mm,
                    // so 20 leaves ~3 mm for the wire bend under the lid.

clear     = 0.4;    // XY fit clearance around each board
gap_y     = 3.0;    // gap between the Tang board and the CH9350 board
conn_drop = 1.0;    // margin: the connector opening starts this far past the
                    // PCB face and runs the connector's height toward the floor

ledge_w   = 2.0;    // width of the perimeter shelf the boards rest on
shelf_grip= 1.5;    // how far the Tang shelf reaches UNDER the board edge
rib_h     = 2.5;    // height of locating ribs above the board top
fillet    = 2.0;    // outer vertical edge rounding

// Board retention is now handled by the REMOVABLE END CAPS (see below): each cap
// carries small clamp lips that hook over the board's short-edge corners, and
// you fit the board with the caps OFF, then screw them on. The old in-base snap
// clips are removed (they blocked the board from seating). Left here disabled.
clip_enable = false;
clip_w = 6.0; clip_t = 2.0; clip_ov = 0.8; clip_h = 1.8;
clip_x = [10, 30]; clip_end = false; clip_end_w = 3.5;

// -----------------------------------------------------------------------------
//  REMOVABLE END CAPS
//  The board has connectors on BOTH short ends (HDMI on -X, USB-C on +X) that
//  hang below the flipped PCB, so it cannot be dropped or slid into a closed
//  box. The two short walls are therefore separate bolt-on caps: fit the board
//  onto the shelf (both ends open), slide each cap on over its connectors, and
//  screw it down. Each cap carries that end's connector cutouts + clamp lips
//  that hold the board's short-edge corners down.
// -----------------------------------------------------------------------------
endcap_enable = true;
endcap_corner = 6.0;    // Y kept as solid base corner at each end; the span
                        // between the two corners is the cap opening
endcap_clear  = 0.35;   // fit clearance around the cap
endcap_lip_ov = 1.6;    // how far a clamp lip reaches over the board top edge
endcap_lip_w  = 6.0;    // clamp-lip width (Y) at each board corner
endcap_foot   = 8.0;    // inward foot length carrying the hold-down screw boss

// Rear ventilation grill: the same 45-degree slot band as the lid, on the back
// (+Y) wall (vertical). Uses the vent_* parameters above.
rear_vent_enable = true;
rear_vent_h      = 14.0;  // band height on the wall (Z)
rear_vent_z_top  = 4.0;   // gap from the wall top down to the band

// Feet: lift the case so the floor button holes / LED window clear the desk
// (and the down-facing LEDs are visible). Four pads under the corner lugs.
foot_enable = true;
foot_h      = 4.0;

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
tn_z0 = floor_th + standoff;                 // PCB underside = COMPONENT face
tn_top = tn_z0 + tn_thick;                   // PCB top = pins/SD face

// Mounting pins-up (component-side-down) while keeping HDMI on the -X wall
// mirrors board X but PRESERVES board Y, so feature Y-coords map straight
// through (no mirroring). It just turns the component face toward the floor.

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

// End-cap opening Y-span (between the solid base corners) and the hold-down
// screw-boss X positions (just inside each cap, under the boards at floor level).
cap_y0    = endcap_corner;
cap_y1    = out_y - endcap_corner;
cap_boss_x = [wall + endcap_foot/2, out_x - wall - endcap_foot/2];  // [-X, +X]
cap_boss_h = floor_th + 5;                                          // boss height

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

// Tang shelf: two strips along the LONG (front/back) edges only, reaching
// shelf_grip under the board so it actually rests on them. The SHORT ends are
// left clear because the down-facing HDMI / USB-C connectors live there.
module tang_support() {
    h = tn_z0 - floor_th;
    for (yy = [tn_y0 - ledge_w,                 // front (-Y) strip
               tn_y0 + tn_wid - shelf_grip])    // back  (+Y) strip
        translate([tn_x0 - ledge_w, yy, floor_th])
            cube([tn_len + 2*ledge_w, ledge_w + shelf_grip, h]);
}

// Retention clips that hook over the Tang's TOP edge (board captured in base).
// Front (-Y): rigid hooks off the front wall. Back (+Y): free-standing flexible
// fingers rising from the floor. Hook overhang = clip_ov (calibrate vs headers).
module tang_clips() {
    if (clip_enable) {
        // long-edge clips (HDMI half): hold the board down along both long edges
        for (lx = clip_x) {
            x = tn_x0 + lx;
            // front (-Y): rigid hook off the wall, over the board front edge
            translate([x - clip_w/2, wall, tn_top])
                cube([clip_w, (tn_y0 + clip_ov) - wall, clip_h]);
            // back (+Y): free-standing finger up from the floor + inward hook
            translate([x - clip_w/2, tn_y0 + tn_wid + clear, floor_th])
                cube([clip_w, clip_t, (tn_top + clip_h) - floor_th]);
            translate([x - clip_w/2, tn_y0 + tn_wid - clip_ov, tn_top])
                cube([clip_w, clip_ov + clear + clip_t, clip_h]);
        }
        // USB-C (+X) short-edge hold-downs near each corner: hooks off the +X
        // wall over the board's +X edge, holding the BUTTON end down. Placed at
        // the corners so they clear the centred microSD opening (and S1/S2 sit
        // ~3 mm inboard, below the floor, so the hooks never touch them).
        if (clip_end) {
            ex = tn_x0 + tn_len;                 // board +X edge
            for (yy = [tn_y0 + 0.5, tn_y0 + tn_wid - 0.5 - clip_end_w])
                translate([ex - clip_ov, yy, tn_top])
                    cube([(out_x - wall) - (ex - clip_ov), clip_end_w, clip_h]);
        }
    }
}

// Four feet under the corner lugs so the floor button/LED openings clear the
// desk and the down-facing LEDs stay visible.
module feet() {
    if (foot_enable)
        for (p = lug_pts)
            translate([p[0], p[1], -foot_h]) cylinder(h = foot_h + 0.01, r = lug_r);
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

// Vertical 45-degree vent band on the back (+Y) wall (mirrors the lid grill).
// Built in a local frame (localX = case X, localY = case Z, localZ = depth),
// then stood up onto the +Y wall with rotate([90,0,0]) (depth runs into -Y).
module rear_vent(depth) {
    vz1 = base_h - rear_vent_z_top;
    vz0 = vz1 - rear_vent_h;
    vx0 = vent_margin;
    vx1 = out_x - vent_margin;
    r   = vent_slot_w/2;
    dx  = vent_pitch / sin(vent_angle);
    L   = (vx1 - vx0) + rear_vent_h + 10;
    zc  = (vz0 + vz1)/2;
    translate([0, out_y + 1, 0]) rotate([90, 0, 0])
        intersection() {
            union()
                for (x = [vx0 - rear_vent_h : dx : vx1 + rear_vent_h])
                    translate([x, zc, -1])
                        linear_extrude(depth + 2)
                            rotate(vent_angle)
                                hull() for (s=[-L/2, L/2]) translate([s,0]) circle(r);
            translate([vx0, vz0, -2]) cube([vx1 - vx0, vz1 - vz0, depth + 4]);
        }
}

// =============================================================================
//  CUTOUTS
// =============================================================================
// Cut into the BASE: floor button/LED holes, the front LED side slot, and the
// rear vent grill. (The short-end connectors live on the removable end caps.)
module base_cutouts() {
    if (btn_enable)
        for (b = [[btn1_x, btn1_y], [btn2_x, btn2_y]])
            translate([tn_x0 + b[0], tn_y0 + b[1], -1])
                cylinder(h = floor_th + 2, d = btn_hole_d);
    if (led_enable)
        translate([tn_x0 + led_win_x, tn_y0 + led_win_y, -1])
            cube([led_win_len, led_win_wid, floor_th + 2]);
    if (led_enable && led_side_enable)
        translate([tn_x0 + led_win_x, -1, tn_z0 - led_side_h])
            cube([led_win_len, tn_y0 + shelf_grip + 3, led_side_h]);
    if (rear_vent_enable) rear_vent(wall + 2);
}

// Connector cutouts carried by an END CAP.  s = -1 (HDMI/-X) or +1 (USB-C/+X).
module endcap_cutouts(s) {
    conn_top = tn_z0 + conn_drop;
    ix = (s < 0) ? -1 : (out_x - wall - 1);      // cutout x-origin for that wall
    if (s < 0) {
        // HDMI (centred on Tang width), dropping from the under-face
        translate([ix, tn_y0 + tn_wid/2 + hdmi_y_off - hdmi_w/2, conn_top - hdmi_h])
            cube([wall + 2, hdmi_w, hdmi_h]);
    } else {
        // USB-C
        translate([ix, tn_y0 + tn_wid/2 + usbc_y_off - usbc_w/2, conn_top - usbc_h])
            cube([wall + 2, usbc_w, usbc_h]);
        // microSD (up-face; reaches down to overlap USB-C -> one stepped opening)
        if (sd_enable)
            translate([ix, tn_y0 + tn_wid/2 + sd_y_off - sd_w/2, tn_z0])
                cube([wall + 2, sd_w, (tn_top + sd_h) - tn_z0]);
        // CH9350 stacked dual USB-A
        translate([ix, ch_y0 + ch_wid/2 - usba_w/2, ch_top + usba_z_off - conn_drop])
            cube([wall + 2, usba_w, usba_h]);
    }
    // DB9 joystick port for this end (rear bay)
    if (db9_enable) translate([ix, db9_y, db9_z]) db9_shape(wall + 2);
}

// =============================================================================
//  REMOVABLE END CAP.  s = -1 (HDMI/-X end) or +1 (USB-C/+X end).
// =============================================================================
module endcap(s) {
    cap_x0  = (s < 0) ? 0 : out_x - wall;                 // cap outer-face x
    inner_x_face = (s < 0) ? wall : (out_x - wall);       // cap inner face
    board_edge   = (s < 0) ? tn_x0 : (tn_x0 + tn_len);    // board short edge
    lip_len = endcap_lip_ov + clear;
    lip_x0  = (s < 0) ? wall : (out_x - wall - lip_len);
    foot_x0 = (s < 0) ? wall : (out_x - wall - endcap_foot);
    fx      = cap_boss_x[(s < 0) ? 0 : 1];
    difference() {
        union() {
            // cap plate (fits between the base corners, floor -> wall top)
            translate([cap_x0, cap_y0, floor_th])
                cube([wall, cap_y1 - cap_y0, base_h - floor_th]);
            // clamp lips over the board's two short-edge corners (hold it down)
            for (yy = [tn_y0, tn_y0 + tn_wid - endcap_lip_w])
                translate([lip_x0, yy, tn_top])
                    cube([lip_len, endcap_lip_w, 2]);
            // hold-down ear sitting on the base boss (screw goes down into it)
            translate([foot_x0, out_y/2 - 4.5, cap_boss_h])
                cube([endcap_foot, 9, 1.6]);
        }
        endcap_cutouts(s);
        // hold-down screw clearance hole through the ear
        translate([fx, out_y/2, cap_boss_h - 1])
            cylinder(h = 4, d = screw_clear_d);
    }
}

// =============================================================================
//  BASE
// =============================================================================
module base() {
    difference() {
        union() {
            // outer shell -> tray; the two SHORT walls are opened (between the
            // corners) so the removable end caps can be fitted after the board.
            difference() {
                rrect_prism(out_x, out_y, base_h, fillet);
                translate([wall, wall, floor_th])
                    cube([inner_x, inner_y, base_h]);   // open-top cavity
                if (endcap_enable)
                    for (s = [-1, 1])
                        translate([(s < 0) ? -1 : (out_x - wall),
                                   cap_y0 - endcap_clear, floor_th])
                            cube([wall + 1, (cap_y1 - cap_y0) + 2*endcap_clear,
                                  base_h + 1]);
            }
            corner_lugs(base_h);
            feet();
            tang_support();                              // board rests on these
            if (clip_enable) tang_clips();
            // CH9350 (component-up): perimeter shelf + locating ribs.
            support_ledge(ch_x0, ch_y0, ch_len, ch_wid, floor_th, ch_z0, ledge_w);
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "ymin");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "ymax");
            locate_rib(ch_x0, ch_y0, ch_len, ch_wid, ch_z0, ch_top + rib_h, "xmin");
            // end-cap hold-down bosses (rise from the floor, under the CH9350)
            if (endcap_enable)
                for (fx = cap_boss_x)
                    translate([fx, out_y/2, floor_th])
                        cylinder(h = cap_boss_h - floor_th, r = 3.4);
        }
        base_cutouts();
        front_bevel_cut();
        // pilot holes: corner lugs (lid) + end-cap bosses
        if (screw_enable)
            for (p = lug_pts) translate([p[0], p[1], floor_th])
                cylinder(h = base_h, d = screw_pilot_d);
        if (endcap_enable)
            for (fx = cap_boss_x) translate([fx, out_y/2, floor_th - 1])
                cylinder(h = cap_boss_h + 1, d = screw_pilot_d);
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

        // (S1/S2 button holes and the LED window are now in the BASE FLOOR —
        //  the board is mounted component-side-down — so the lid is a plain cover.)
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
    // tall enough to include the capture clips, and the DB9 ports when enabled
    fc_h = max(tn_top + clip_h + 1,
               db9_enable ? (db9_z + db9_apt_h/2 + db9_screw_d/2 + 3)
                          : (floor_th + standoff + tn_thick + 3));
    intersection() {
        union() {
            base();
            if (endcap_enable) { endcap(-1); endcap(1); }   // test connector fit
        }
        translate([-1, -1, -foot_h - 1])
            cube([out_x + 2, out_y + 2, fc_h + foot_h + 1]);
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
            if (endcap_enable) color("SteelBlue") { endcap(-1); endcap(1); }
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
    // removable end caps (exploded outward along X so you can see them)
    if (endcap_enable) {
        ex = show_lid ? 12 : 0;                 // explode distance
        color("SteelBlue") translate([-ex, 0, 0]) endcap(-1);
        color("SteelBlue") translate([ ex, 0, 0]) endcap(1);
    }
    // ghost boards
    color([0.1, 0.5, 0.2, 0.85])
        translate([tn_x0, tn_y0, tn_z0]) cube([tn_len, tn_wid, tn_thick]);
    color([0.2, 0.2, 0.7, 0.85])
        translate([ch_x0, ch_y0, ch_z0]) cube([ch_len, ch_wid, ch_thick]);
    // lid floating above
    if (show_lid)
        color([0.6, 0.6, 0.6, 0.55])
            translate([0, 0, base_h + 14]) lid();
}

// -----------------------------------------------------------------------------
if (part == "base")             base();
else if (part == "lid")         lid();
else if (part == "endcap_hdmi") endcap(-1);   // -X end cap (HDMI + DB9)
else if (part == "endcap_usbc") endcap(1);    // +X end cap (USB-C/SD + USB-A + DB9)
else if (part == "fitcheck")    fitcheck();
else if (part == "section")     section();
else if (part == "closed") { color("DarkSlateGray") base();
                             if (endcap_enable) color("SteelBlue") { endcap(-1); endcap(1); }
                             color([0.7,0.7,0.7]) translate([0,0,base_h]) lid(); }
else                            assembly();
