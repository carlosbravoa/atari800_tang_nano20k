// =============================================================================
//  Atari-style console case for the Atari800 Tang Nano 20K port
//  Houses a Sipeed Tang Nano 20K + a CH9350 USB-host keyboard module,
//  wired as described in the project README (one data wire to Pin 53,
//  GND + 5V, DB9 joysticks on GPIO pins).
//
//  DESIGN NOTES
//  ------------
//  * The Tang Nano stands ON EDGE behind the front panel, component side
//    facing FORWARD.  The status LEDs and both buttons therefore live on the
//    front panel where you can see and reach them, and the GPIO headers point
//    backwards so the Dupont jumpers lie flat instead of stacking under a lid.
//  * CLAMSHELL: a bottom tray and a top cover meeting at a parting line that
//    runs THROUGH the connectors.  Every port opening is a notch open at that
//    parting line, so both boards drop straight in from above and the cover
//    closes over them - no end caps, no snap clips, no fighting a board into
//    a closed box.
//  * Styling (clamshell, wedge front, vent bands, split ports) is an homage to
//    wt808's "Atari-Compatible eclaire Mini" enclosures on Thingiverse
//    (thing:3562690, CC BY-NC-SA).  All geometry here is generated from
//    scratch by this script; no model data is copied from that work, so this
//    file stays under the repository's own licence.
//
//  Board defaults are datasheet + measured values:
//     Tang Nano 20K PCB : 54.04 x 22.55 x ~1.6 mm
//     CH9350 module PCB : 49.6  x 20.5  x ~1.6 mm (stacked dual USB-A)
//
//  >>> READ case/README.md BEFORE PRINTING <<<
//  Print "fitcheck" first (a low slice of the tray, ~15 min) to verify the
//  card slot and the connector cutouts line up with YOUR hardware.
//
//  PARTS (both print flat on their outer face, no supports):
//     openscad -D 'part="bottom"'   -o bottom.stl   <file>
//     openscad -D 'part="top"'      -o top.stl      <file>
//     openscad -D 'part="fitcheck"' -o fitcheck.stl <file>   (test first)
//     openscad -D 'part="assembly"' ...                      (preview only)
// =============================================================================

part = "assembly";  // bottom | top | fitcheck | assembly | section | closed
show_top = true;    // assembly preview: false drops the floating cover

$fn = 48;

// -----------------------------------------------------------------------------
//  BOARD DIMENSIONS  (measure yours and adjust)
// -----------------------------------------------------------------------------
tn_len    = 54.04;  // Tang Nano 20K length (HDMI end .. USB-C end) -> case X
tn_wid    = 22.55;  // Tang Nano 20K width  -> becomes HEIGHT (board stands up)
tn_th     = 1.6;    // PCB thickness

ch_len    = 49.6;   // CH9350 length (X)
ch_wid    = 20.5;   // CH9350 width  (Y, lies flat)
ch_th     = 1.6;

// Board-local coordinates used throughout:
//   u = along the Tang's length, 0 at the HDMI end       -> X = tn_x0 + u
//   v = across the Tang's width, 0 at the LED / S1 edge  -> Z = tn_z0 + v
// The LED/S1 edge points DOWN, so the LEDs sit low on the front panel and the
// board rests on its opposite long edge in the card slot.

// -----------------------------------------------------------------------------
//  TANG NANO FEATURES  (measured from the board)
//  Openings are sized for the mating PLUG, not the bare connector: FDM holes
//  print undersized and the first prototype had to be opened up by hand.
// -----------------------------------------------------------------------------
hdmi_v      = 14.0;  // HDMI opening across the board width  (-> vertical)
hdmi_d      = 10.0;  // HDMI opening perpendicular to the PCB (-> depth, Y)
hdmi_stand  = 6.0;   // how far the HDMI body stands off the component face
hdmi_v_off  = 0;

usbc_v      = 11.0;  // USB-C opening across the board width
usbc_stand  = 2.5;   // USB-C body stand-off from the component face
sd_v        = 16.0;  // microSD opening across the board width
sd_stand    = 2.5;   // SD cage stand-off from the PIN face
sd_v_off    = -1.5;  // the SD slot is not centred on the board width
sd_enable   = true;

// Status LEDs: a 6-LED row on the component face, in line with S1.
led_u       = 35.25;
led_u_len   = 8.5;
led_v       = 4.0;
led_v_wid   = 2.0;
led_enable  = true;

// S1 / S2: both 5 mm in from the USB-C end, on OPPOSITE long edges, so they
// become two front-panel wells one above the other. They are plain wide holes:
// the board sits ~6.5 mm behind the panel (the HDMI body sets that gap), so a
// narrow hole would be unreachable - 8 mm lets a fingertip in.
btn_u       = 49.0;
btn1_v      = 5.0;    // S1 - low, on the LED line
btn2_v      = 17.55;  // S2 - high
btn_d       = 8.0;
btn_cham    = 1.0;    // lead-in chamfer on the outer face
btn_enable  = true;

jumper_len  = 17.0;   // pin header + Dupont plug reach behind the PCB

// -----------------------------------------------------------------------------
//  CH9350 : STACKED DUAL USB-A host port (keyboard), on its +X short end
// -----------------------------------------------------------------------------
usba_w      = 16.0;
usba_h      = 18.0;
usba_z_off  = -1.0;   // relative to the CH9350 PCB top
ch_stand    = 3.0;    // gap under the CH9350 (clears its underside solder)

// -----------------------------------------------------------------------------
//  DB9 JOYSTICK PORTS  (panel-mount female D-sub, one per side wall)
//  Both sit entirely in the BOTTOM tray so the sockets can be screwed in
//  before the cover goes on.
// -----------------------------------------------------------------------------
db9_enable      = true;
db9_zone        = 33.0;   // rear bay depth (Y) reserved for the two sockets
db9_apt_w       = 18.5;
db9_apt_w2      = 16.2;
db9_apt_h       = 11.0;
db9_screw_pitch = 24.99;
db9_screw_d     = 3.2;
db9_body_depth  = 14.0;   // inward protrusion (clearance reference; not printed)
db9_z           = 8.0;    // aperture centre height (keeps it under the split)

// -----------------------------------------------------------------------------
//  CASE BODY
// -----------------------------------------------------------------------------
wall       = 2.4;
wall_front = 4.0;   // thicker: carries the LED window, button wells and logo,
                    // and gives the front wedge something to bite into
floor_th   = 2.0;
top_th     = 2.0;
clear      = 0.4;   // XY fit clearance around the boards
conn_gap   = 0.6;   // slack between the front wall and the deepest connector
gap_tj     = 2.5;   // gap between the jumper stack and the CH9350
gap_jd     = 2.0;   // gap between the CH9350 and the DB9 bay
head_gap   = 1.5;   // clear space above the tallest internal item
fillet     = 3.0;   // outer vertical corner radius
base_cham  = 1.2;   // chamfer around the bottom edge

// Front wedge: a 45-degree chamfer along the front-top edge. Its leg must stay
// below top_th + wall_front so it cannot eat through the front wall and open a
// slot into the cavity (that bug made the first version look broken).
front_wedge = 4.5;
wedge_inset = -2.0;  // negative = run the chamfer past the rounded corners

// Parting line height (absolute Z). Must sit ABOVE the DB9 aperture (so the
// sockets stay in the tray) and BELOW the top of every board connector that
// overhangs its board edge (so the boards can descend past the tray walls).
split_z   = 15.0;

// Card slot holding the Tang's lower long edge. Deliberately loose: the header
// pins sit only ~1 mm in from that edge, so their solder fillets reach almost
// to it and a tight slot would jam on solder rather than on PCB.
slot_w    = 3.0;
slot_h    = 2.6;
slot_rib  = 1.6;

press_w   = 8.0;    // cover pads that press the Tang's upper edge
press_cl  = 0.25;

lip_h     = 2.5;    // parting-line lip on the cover
lip_t     = 1.2;
lip_cl    = 0.35;

// Shell screws: M3, driven UP from underneath into posts moulded to the cover,
// so nothing shows on top. One at the front centre, two in the rear bay.
screw_enable  = true;
screw_pilot_d = 2.6;
screw_clear_d = 3.4;
screw_head_d  = 6.4;
screw_head_h  = 2.2;
post_r        = 2.9;   // leaves 1.6 mm of meat around the pilot bore, and stays
                       // clear of the Tang's front face and the DB9 bodies
post_gap      = 7.0;   // the front card-slot rib is broken by this much so the
                       // front post can reach the floor

// -----------------------------------------------------------------------------
//  VENTILATION
// -----------------------------------------------------------------------------
// Louvre, XE style: a raised plinth on the cover, cut across by oblique slots.
// The material left between the slots forms a comb of FINS standing proud of
// the lid - that is what gives the vent its depth; slots cut into a flat lid
// just read as scored lines. It sits directly OVER the Tang and its jumper bay
// - where the FPGA's heat comes off - with matching intake slots in the floor.
vent_enable   = true;
vent_slot_w   = 1.8;
vent_pitch    = 3.4;
vent_angle    = 45;
vent_raise    = 2.6;    // how far the louvre stands PROUD of the cover
vent_cham     = 1.0;    // taper on the plinth's edge
vent_border   = 3.0;    // solid rim left round the slots so the fins stay tied
                        // to the lid at both ends (cut them free and the ribs
                        // between the slots would be loose pieces)
vent_side_in  = 12.5;   // inset from the side walls (clears the press pads)
vent_corner   = 2.5;    // plinth corner radius

side_vent_enable = true;  // upright slits around the cover's rear flanks
side_vent_w      = 1.8;
side_vent_pitch  = 4.4;
side_vent_h      = 6.5;
side_vent_z      = 4.5;   // above the parting line

floor_vent_enable = true; // slots in the tray floor, under the rear bay

// -----------------------------------------------------------------------------
//  BRANDING
// -----------------------------------------------------------------------------
brand_enable = true;      // "ATARI 800" recessed strip on the cover
brand_text   = "ATARI 800";
brand_w      = 46.0;
brand_h      = 9.0;
brand_depth  = 0.8;
brand_txt_sz = 5.6;

logo_enable  = true;      // Fuji mark on the FRONT panel, left of the LEDs
logo_w       = 14.0;
logo_h       = 11.0;
logo_cx      = 15.0;
logo_cz      = 8.0;
logo_depth   = 0.8;

// =============================================================================
//  DERIVED GEOMETRY
// =============================================================================
// ---- X: pinned by the Tang, whose two ends carry HDMI and USB-C ----
inner_x = tn_len + 2*clear;
out_x   = inner_x + 2*wall;
tn_x0   = wall + clear;                        // board's -X (HDMI) end

// ---- Y: front wall -> connectors -> PCB -> jumpers -> CH9350 -> DB9 bay ----
conn_zone = hdmi_stand + conn_gap;             // deepest forward-facing part
tn_y0   = wall_front + conn_zone;              // component (front) face
tn_y1   = tn_y0 + tn_th;                       // pin face
jump_y  = tn_y1 + jumper_len;
ch_y0   = jump_y + gap_tj;
ch_y1   = ch_y0 + ch_wid;
bay_y0  = ch_y1 + gap_jd;
bay_y1  = bay_y0 + db9_zone;
out_y   = bay_y1 + wall;

// ---- Z ----
tn_z0   = floor_th;                            // lower board edge, on the floor
tn_z1   = tn_z0 + tn_wid;                      // upper board edge
ch_z0   = floor_th + ch_stand;
ch_top  = ch_z0 + ch_th;
usba_z0 = ch_top + usba_z_off;
inner_z = max(tn_z1, usba_z0 + usba_h) + head_gap;
out_z   = inner_z + top_th;

function ux(u) = tn_x0 + u;
function vz(v) = tn_z0 + v;
function ch_x0() = out_x - wall - clear - ch_len;   // USB stack against +X wall

// Vent panel bounds: spans the Tang and its jumper bay, inset from the sides
// so it never crosses the cover's press pads.
vent_x0 = vent_side_in;
vent_x1 = out_x - vent_side_in;
vent_y0 = tn_y0 + 0.4;
vent_y1 = ch_y0 - 1.5;

tn_vc = tn_z0 + tn_wid/2;                      // board's vertical centre
ch_cy = ch_y0 + ch_wid/2;
db9_y = (bay_y0 + bay_y1)/2;

// Shell screws: front centre plus two in the rear bay. All are clear of the
// DB9 bodies (which hug the side walls), the HDMI/USB-C bodies and the LED
// light path.
// X of the front post is chosen to fall in a gap between the cover's press
// pads, and Y of the rear pair keeps them clear of the top vent band.
scr_pts = [[22.0,        wall_front + 3.0],
           [out_x*0.34,  bay_y0 + 6.8],
           [out_x*0.66,  bay_y0 + 6.8]];

// =============================================================================
//  HELPERS
// =============================================================================
module rrect(sx, sy, sz, r) {
    hull() for (mx = [r, sx-r], my = [r, sy-r])
        translate([mx, my, 0]) cylinder(h = sz, r = r);
}

module front_wedge_cut() {
    if (front_wedge > 0) {
        s = front_wedge * sqrt(2);
        translate([out_x/2, 0, out_z]) rotate([45, 0, 0])
            cube([out_x - 2*wedge_inset, s, s], center = true);
    }
}

// Outer solid of the whole closed case; each shell is a Z slice of this.
module shell_solid() {
    difference() {
        rrect(out_x, out_y, out_z, fillet);
        if (base_cham > 0)
            difference() {
                translate([-1, -1, -0.01]) cube([out_x+2, out_y+2, base_cham]);
                translate([base_cham, base_cham, -0.02])
                    rrect(out_x - 2*base_cham, out_y - 2*base_cham,
                          base_cham + 0.04, max(0.1, fillet - base_cham));
            }
        front_wedge_cut();
    }
}

// Interior cavity (front wall is thicker than the rest).
module cavity() {
    translate([wall, wall_front, floor_th])
        cube([inner_x, out_y - wall_front - wall, out_z]);
}

module slab(z0, z1) { translate([-2, -2, z0]) cube([out_x+4, out_y+4, z1-z0]); }

// The raised plinth. Tapered on all four sides so it grows out of the lid
// instead of sitting on it like a slab.
module vent_plinth() {
    w = vent_x1 - vent_x0;
    h = vent_y1 - vent_y0;
    r = vent_corner;
    c = vent_cham;
    hull() {
        translate([vent_x0, vent_y0, out_z - 0.01])
            linear_extrude(0.01)
                translate([r, r]) offset(r = r) square([w - 2*r, h - 2*r]);
        translate([vent_x0 + c, vent_y0 + c, out_z + vent_raise])
            linear_extrude(0.01)
                translate([r, r]) offset(r = r)
                    square([w - 2*c - 2*r, h - 2*c - 2*r]);
    }
}

// Oblique slots straight through the plinth AND the lid beneath it. What is
// left standing between them are the fins.
module vent_slots_cut() {
    w  = vent_x1 - vent_x0;
    h  = vent_y1 - vent_y0;
    bi = vent_border;
    ri = max(0.1, vent_corner - bi/2);
    z0 = inner_z - 1;
    zh = (out_z + vent_raise + 2) - z0;
    intersection() {
        union() {
            dx = vent_pitch / sin(vent_angle);
            L  = w + h + 20;
            for (x = [vent_x0 - h : dx : vent_x1 + h])
                translate([x, (vent_y0 + vent_y1)/2, z0])
                    linear_extrude(zh)
                        rotate(vent_angle)
                            hull() for (s = [-L/2, L/2])
                                translate([s, 0]) circle(vent_slot_w/2);
        }
        translate([vent_x0 + bi, vent_y0 + bi, z0 - 1])
            linear_extrude(zh + 2)
                translate([ri, ri]) offset(r = ri)
                    square([w - 2*bi - 2*ri, h - 2*bi - 2*ri]);
    }
}

// Upright slits around the cover's rear flanks (kept behind the port cluster).
module side_vents() {
    z0 = split_z + side_vent_z;
    y0 = bay_y0 - 10;
    y1 = out_y - fillet - 4;
    n  = floor((y1 - y0) / side_vent_pitch);
    for (i = [0 : n]) {
        yy = y0 + i*side_vent_pitch;
        translate([-1, yy, z0])            cube([wall + 2, side_vent_w, side_vent_h]);
        translate([out_x - wall - 1, yy, z0]) cube([wall + 2, side_vent_w, side_vent_h]);
    }
    nx = floor((out_x - 2*(fillet + 5)) / side_vent_pitch);
    for (i = [0 : nx])
        translate([fillet + 5 + i*side_vent_pitch, out_y - wall - 1, z0])
            cube([side_vent_w, wall + 2, side_vent_h]);
}

// Atari "Fuji" mark (stylised: centre bar + two flaring prongs on a base).
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

// Fuji debossed into the FRONT panel (stands upright in the XZ plane).
module front_fuji_cut() {
    if (logo_enable)
        translate([logo_cx, logo_depth, logo_cz]) rotate([90, 0, 0])
            linear_extrude(logo_depth + 0.2)
                resize([logo_w, logo_h], auto = true) fuji_2d();
}

module brand_cut() {
    by = (vent_y1 + out_y)/2;    // centred in the plain area behind the louvre
    translate([out_x/2, by, out_z - brand_depth])
        linear_extrude(brand_depth + 1)
            offset(r = 1.2) square([brand_w - 2.4, brand_h - 2.4], center = true);
    if (brand_text != "")
        translate([out_x/2, by, out_z - brand_depth - 0.45])
            linear_extrude(brand_depth + 1.45)
                text(brand_text, size = brand_txt_sz,
                     font = "Liberation Sans:style=Bold",
                     halign = "center", valign = "center");
}

// D-sub DB9 cutout built along +X (depth d), centred on local Y=0, Z=0.
module db9_shape(d) {
    hull() {
        translate([0, -db9_apt_w/2,  db9_apt_h/2 - 1]) cube([d, db9_apt_w, 1]);
        translate([0, -db9_apt_w2/2, -db9_apt_h/2])    cube([d, db9_apt_w2, 1]);
    }
    for (s = [-1, 1])
        translate([0, s*db9_screw_pitch/2, 0]) rotate([0, 90, 0])
            cylinder(h = d, d = db9_screw_d);
}

// =============================================================================
//  PORT CUTOUTS
//  One module, subtracted from BOTH shells. Each shell keeps only the part in
//  its own Z range, so every opening straddling `split_z` is halved - which is
//  exactly what lets the boards drop in from above.
// =============================================================================
module port_cuts() {
    // ---- Tang HDMI : -X wall ----
    translate([-1, tn_y0 - hdmi_stand - conn_gap, tn_vc + hdmi_v_off - hdmi_v/2])
        cube([wall + 2, hdmi_d, hdmi_v]);

    // ---- Tang USB-C + microSD : +X wall, merged into one stepped opening so
    //      no fragile sliver of wall is left between them ----
    translate([out_x - wall - 1, tn_y0 - usbc_stand - conn_gap, tn_vc - usbc_v/2])
        cube([wall + 2, usbc_stand + conn_gap + tn_th + 0.6, usbc_v]);
    if (sd_enable)
        translate([out_x - wall - 1, tn_y0 - 0.6,
                   tn_vc + sd_v_off - sd_v/2])
            cube([wall + 2, tn_th + sd_stand + 1.2, sd_v]);

    // ---- CH9350 stacked dual USB-A : +X wall ----
    translate([out_x - wall - 1, ch_cy - usba_w/2, usba_z0])
        cube([wall + 2, usba_w, usba_h]);

    // ---- Tang status LEDs : front panel window ----
    if (led_enable)
        translate([ux(led_u), -1, vz(led_v)])
            cube([led_u_len, wall_front + 2, led_v_wid]);

    // ---- S1 / S2 : front panel wells, with an outer lead-in chamfer ----
    if (btn_enable)
        for (v = [btn1_v, btn2_v]) {
            translate([ux(btn_u), wall_front + 1, vz(v)]) rotate([90, 0, 0])
                cylinder(h = wall_front + 2, d = btn_d);
            translate([ux(btn_u), btn_cham, vz(v)]) rotate([90, 0, 0])
                cylinder(h = btn_cham + 0.1, d1 = btn_d, d2 = btn_d + 2*btn_cham);
        }

    // ---- DB9 joystick ports : both side walls, rear bay ----
    if (db9_enable) {
        translate([-1, db9_y, db9_z]) db9_shape(wall + 2);
        translate([out_x - wall - 1, db9_y, db9_z]) db9_shape(wall + 2);
    }
}

// =============================================================================
//  INTERNAL FURNITURE  (added AFTER the cavity is cut, or it gets erased)
// =============================================================================
// Card slot for the Tang's lower long edge. The FRONT rib is broken where the
// cover's front screw post has to come down to the floor; the board's X travel
// is limited by the side walls themselves (0.4 mm either side), so no separate
// end stops are needed - and stops there would foul the board anyway.
module tang_slot() {
    y_front = tn_y0 - (slot_w - tn_th)/2 - slot_rib;
    y_back  = tn_y0 + tn_th + (slot_w - tn_th)/2;
    gx0 = scr_pts[0][0] - post_gap;
    gx1 = scr_pts[0][0] + post_gap;
    // back rib: continuous
    translate([wall, y_back, floor_th]) cube([inner_x, slot_rib, slot_h]);
    // front rib: two segments either side of the post
    translate([wall, y_front, floor_th])
        cube([max(0.1, gx0 - wall), slot_rib, slot_h]);
    translate([gx1, y_front, floor_th])
        cube([max(0.1, (wall + inner_x) - gx1), slot_rib, slot_h]);
}

// CH9350 pocket: a low shelf frame that reaches under the board perimeter,
// plus locating ribs on all four sides.
module ch9350_seat() {
    h = ch_z0 - floor_th;
    difference() {
        translate([ch_x0() - 1.6, ch_y0 - 1.6, floor_th])
            cube([ch_len + 3.2, ch_wid + 3.2, h]);
        translate([ch_x0() + 1.2, ch_y0 + 1.2, floor_th - 1])
            cube([ch_len - 2.4, ch_wid - 2.4, h + 2]);
    }
    for (r = [[ch_x0() - 1.6 - clear,    ch_y0 - 1.6,         1.6,     ch_wid + 3.2],
              [ch_x0() + ch_len + clear, ch_y0 - 1.6,         1.6,     ch_wid + 3.2],
              [ch_x0(),                  ch_y0 - 1.4 - clear, ch_len,  1.4],
              [ch_x0(),                  ch_y0 + ch_wid + clear, ch_len, 1.4]])
        translate([r[0], r[1], floor_th]) cube([r[2], r[3], h + ch_th + 1.6]);
}

// =============================================================================
//  BOTTOM TRAY
// =============================================================================
module bottom() {
    union() {
        difference() {
            intersection() { shell_solid(); slab(-1, split_z); }
            cavity();
            port_cuts();
            front_fuji_cut();
            if (screw_enable)
                for (p = scr_pts) {
                    translate([p[0], p[1], -1])
                        cylinder(h = floor_th + 2, d = screw_clear_d);
                    translate([p[0], p[1], -0.01])
                        cylinder(h = screw_head_h, d = screw_head_d);
                }
            if (floor_vent_enable) {
                for (i = [0 : 2])   // intake directly under the Tang's bay
                    translate([out_x*0.25, tn_y1 + 3.5 + i*4.4, -1])
                        cube([out_x*0.5, 2.2, floor_th + 2]);
                for (i = [0 : 3])   // behind the rear screw bosses
                    translate([out_x*0.2, bay_y0 + 12.8 + i*4.4, -1])
                        cube([out_x*0.6, 2.2, floor_th + 2]);
            }
        }
        // furniture, added after the cavity so it survives
        difference() {
            union() { tang_slot(); ch9350_seat(); }
            port_cuts();
            if (screw_enable)
                for (p = scr_pts)
                    translate([p[0], p[1], -1])
                        cylinder(h = split_z + 2, d = screw_clear_d);
        }
    }
}

// =============================================================================
//  TOP COVER
// =============================================================================
module top() {
    union() {
        difference() {
            union() {
                intersection() { shell_solid(); slab(split_z, out_z + 1); }
                if (vent_enable) vent_plinth();
            }
            // hollow the cover interior, leaving the top plate
            translate([wall, wall_front, split_z - 1])
                cube([inner_x, out_y - wall_front - wall, inner_z - split_z + 1]);
            port_cuts();
            if (vent_enable) vent_slots_cut();
            if (side_vent_enable) side_vents();
            if (brand_enable) brand_cut();
        }
        // Everything below is added AFTER the hollow so it survives, and each
        // piece overlaps solid cover material so the result stays manifold.
        difference() {
            union() { lip_bars(); press_pads(); posts(); }
            port_cuts();
            if (screw_enable)
                for (p = scr_pts)
                    translate([p[0], p[1], floor_th - 1])
                        cylinder(h = inner_z - floor_th + 2.5, d = screw_pilot_d);
        }
    }
}

// Alignment lips on the FRONT and REAR walls only. There is no room for lips on
// the side walls - the Tang spans the full interior width with just 0.4 mm to
// spare - so the sides are located by the port openings and the screws instead.
module lip_bars() {
    x0 = wall + 5;  xw = inner_x - 10;
    // front
    translate([x0, wall_front - 0.6, split_z - lip_h])
        cube([xw, 0.6 + lip_cl + lip_t, lip_h + 1.0]);
    // rear
    translate([x0, out_y - wall - lip_cl - lip_t, split_z - lip_h])
        cube([xw, 0.6 + lip_cl + lip_t, lip_h + 1.0]);
}

// Pads that press the Tang's upper edge down into its slot.
module press_pads() {
    for (fx = [0.08, 0.92])
        translate([tn_x0 + tn_len*fx - press_w/2, tn_y0 - 0.7, tn_z1 + press_cl])
            cube([press_w, tn_th + 1.4, inner_z - tn_z1 - press_cl + 0.6]);
}

// Screw posts reaching down to the tray floor.
module posts() {
    if (screw_enable)
        for (p = scr_pts)
            translate([p[0], p[1], floor_th])
                cylinder(h = inner_z - floor_th + 0.6, r = post_r);
}

// =============================================================================
//  FIT-CHECK  (a low slice of the tray: floor, card slot, CH9350 seat and the
//  bottom half of every opening - enough to prove the boards drop in and the
//  ports line up, for a fraction of the plastic)
// =============================================================================
module fitcheck() {
    intersection() { bottom(); slab(-1, split_z); }
}

// =============================================================================
//  PREVIEWS
// =============================================================================
module boards_ghost() {
    color([0.10, 0.55, 0.20, 0.9])                        // Tang, standing
        translate([tn_x0, tn_y0, tn_z0]) cube([tn_len, tn_th, tn_wid]);
    color([0.20, 0.20, 0.75, 0.9])                        // CH9350, flat
        translate([ch_x0(), ch_y0, ch_z0]) cube([ch_len, ch_wid, ch_th]);
    color([0.75, 0.65, 0.15, 0.45])                       // Dupont jumper zone
        translate([tn_x0, tn_y1, tn_z0 + 1.5])
            cube([tn_len, jumper_len, tn_wid - 3]);
    if (db9_enable)                                       // DB9 socket bodies
        color([0.3, 0.3, 0.3, 0.55])
            for (sx = [wall, out_x - wall - db9_body_depth])
                translate([sx, db9_y - 15.5, db9_z - 6.5])
                    cube([db9_body_depth, 31, 13]);
}

module assembly() {
    color("DarkSlateGray") bottom();
    boards_ghost();
    if (show_top)
        color([0.72, 0.72, 0.72, 0.55]) translate([0, 0, 18]) top();
}

module section() {
    cut_x = out_x*0.55;   // keep the -X half; look at the front-to-back stack
    difference() {
        union() {
            color("DarkSlateGray") bottom();
            color([0.75, 0.75, 0.75]) top();
            boards_ghost();
        }
        translate([cut_x, -60, -1]) cube([out_x, out_y + 120, out_z + 2]);
    }
}

// -----------------------------------------------------------------------------
if      (part == "bottom")   bottom();
else if (part == "top")      top();
else if (part == "fitcheck") fitcheck();
else if (part == "section")  section();
else if (part == "closed") { color("DarkSlateGray") bottom();
                             color([0.75,0.75,0.75]) top(); }
else                         assembly();
