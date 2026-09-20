// usb_to_atari800.sv — USB HID keycode → Atari 800 keyboard matrix
//
// Replicates the matrix interface of ps2_to_atari800.vhdl using USB HID
// keycodes (key1-key4 = up to 4 simultaneously pressed keys, 0 = empty slot).
//
// Matrix protocol (same as original VHDL):
//   keyboard_response[0] = 0  when atari_keyboard[~keyboard_scan] is set
//   keyboard_response[1] = 0  when:
//     scan[5:4]==00 and break is pressed
//     scan[5:4]==10 and shift is pressed
//     scan[5:4]==11 and control is pressed
//   Default response = 2'b11 (no key)

module usb_to_atari800 (
    input  wire        clk,
    input  wire        reset_n,

    // From usb_hid_host
    input  wire [7:0]  key_modifiers,  // {RGui,RAlt,RShft,RCtrl,LGui,LAlt,LShft,LCtrl}
    input  wire [7:0]  key1,
    input  wire [7:0]  key2,
    input  wire [7:0]  key3,
    input  wire [7:0]  key4,
    input  wire        pc_layout,      // 0 = Atari-positional (default), 1 = US-PC symbolic

    // Atari keyboard matrix
    input  wire [5:0]  keyboard_scan,
    output wire [1:0]  keyboard_response,

    // Atari console keys
    output wire        consol_start,
    output wire        consol_select,
    output wire        consol_option
);

// ── HID keycode → Atari matrix bit (0-63; 7'h7f = unmapped) ─────────────────
// Atari matrix bit = index into atari_keyboard[63:0]
// (core scans with NOT(keyboard_scan), so bit 63 = scan 0, bit 0 = scan 63)
function automatic [6:0] hid2atari;
    input [7:0] hid;
    case (hid)
        // Letters A-Z (USB 0x04-0x1D)
        8'h04: hid2atari = 7'd63;  // A
        8'h05: hid2atari = 7'd21;  // B
        8'h06: hid2atari = 7'd18;  // C
        8'h07: hid2atari = 7'd58;  // D
        8'h08: hid2atari = 7'd42;  // E
        8'h09: hid2atari = 7'd56;  // F
        8'h0A: hid2atari = 7'd61;  // G
        8'h0B: hid2atari = 7'd57;  // H
        8'h0C: hid2atari = 7'd13;  // I
        8'h0D: hid2atari = 7'd1;   // J
        8'h0E: hid2atari = 7'd5;   // K
        8'h0F: hid2atari = 7'd0;   // L
        8'h10: hid2atari = 7'd37;  // M
        8'h11: hid2atari = 7'd35;  // N
        8'h12: hid2atari = 7'd8;   // O
        8'h13: hid2atari = 7'd10;  // P
        8'h14: hid2atari = 7'd47;  // Q
        8'h15: hid2atari = 7'd40;  // R
        8'h16: hid2atari = 7'd62;  // S
        8'h17: hid2atari = 7'd45;  // T
        8'h18: hid2atari = 7'd11;  // U
        8'h19: hid2atari = 7'd16;  // V
        8'h1A: hid2atari = 7'd46;  // W
        8'h1B: hid2atari = 7'd22;  // X
        8'h1C: hid2atari = 7'd43;  // Y
        8'h1D: hid2atari = 7'd23;  // Z
        // Digits 1-9, 0
        8'h1E: hid2atari = 7'd31;  // 1
        8'h1F: hid2atari = 7'd30;  // 2
        8'h20: hid2atari = 7'd26;  // 3
        8'h21: hid2atari = 7'd24;  // 4
        8'h22: hid2atari = 7'd29;  // 5
        8'h23: hid2atari = 7'd27;  // 6
        8'h24: hid2atari = 7'd51;  // 7
        8'h25: hid2atari = 7'd53;  // 8
        8'h26: hid2atari = 7'd48;  // 9
        8'h27: hid2atari = 7'd50;  // 0
        // Control keys
        8'h28: hid2atari = 7'd12;  // Enter
        8'h29: hid2atari = 7'd28;  // Escape
        8'h2A: hid2atari = 7'd52;  // Backspace (Delete on Atari)
        8'h2B: hid2atari = 7'd44;  // Tab
        8'h2C: hid2atari = 7'd33;  // Space
        // Punctuation
        8'h2D: hid2atari = 7'd54;  // - (minus)
        8'h2E: hid2atari = 7'd55;  // = (equals)
        8'h2F: hid2atari = 7'd14;  // [ → Atari Up (same key on Atari keyboard)
        8'h30: hid2atari = 7'd15;  // ] → Atari Down
        8'h31: hid2atari = 7'd7;   // \ → Atari Right
        8'h32: hid2atari = 7'd7;   // ISO Non-US #/~ (key next to ISO Enter, often |\) → same as ANSI \ → Atari * key
        8'h33: hid2atari = 7'd2;   // ; (semicolon)
        8'h34: hid2atari = 7'd6;   // ' → Atari Left
        8'h36: hid2atari = 7'd32;  // , (comma)
        8'h37: hid2atari = 7'd34;  // . (period)
        8'h38: hid2atari = 7'd38;  // / (slash)
        // Caps Lock
        8'h39: hid2atari = 7'd60;  // Caps Lock
        // F1-F4 → Atari function keys
        8'h3A: hid2atari = 7'd3;   // F1
        8'h3B: hid2atari = 7'd4;   // F2
        8'h3C: hid2atari = 7'd19;  // F3
        8'h3D: hid2atari = 7'd20;  // F4
        8'h3E: hid2atari = 7'd17;  // F5 → Help
        // Insert
        8'h49: hid2atari = 7'd17;  // Insert → Help (same as F5 on Atari)
        // Arrow keys → Atari cursor keys
        8'h4F: hid2atari = 7'd7;   // Right Arrow
        8'h50: hid2atari = 7'd6;   // Left Arrow
        8'h51: hid2atari = 7'd15;  // Down Arrow
        8'h52: hid2atari = 7'd14;  // Up Arrow
        default: hid2atari = 7'h7F; // unmapped
    endcase
endfunction

// ── PC-symbolic layout (OSD "Keyboard: PC", docs/kbd_pc_layout_spec.md) ─────
// Same Atari matrix codes, but chosen by the SYMBOL a US-ANSI keyboard prints for
// (key, physical Shift), and carrying the shift state the Atari needs for it:
//   smode PASS = Atari shift follows the physical Shift (all of ATARI mode)
//   smode F0   = shift suppressed (PC Shift+8 = '*' -> bare Atari '*' key)
//   smode F1   = shift forced     (PC '\'' unshifted -> Atari Shift+7)
localparam [1:0] PASS = 2'd0, F0 = 2'd1, F1 = 2'd2;

function automatic [8:0] hid2atari_pc;     // {smode[1:0], code[6:0]}
    input [7:0] hid;
    input       sh;                        // physical Shift at press time
    case (hid)
        8'h1F: hid2atari_pc = sh ? {F1, 7'd53}   : {PASS, 7'd30}; // 2 / @  (Atari Sh+8)
        8'h23: hid2atari_pc = sh ? {F1, 7'd7}    : {PASS, 7'd27}; // 6 / ^  (Atari Sh+*)
        8'h24: hid2atari_pc = sh ? {F1, 7'd27}   : {PASS, 7'd51}; // 7 / &  (Atari Sh+6)
        8'h25: hid2atari_pc = sh ? {F0, 7'd7}    : {PASS, 7'd53}; // 8 / *  (Atari * key)
        8'h2D: hid2atari_pc = sh ? {F1, 7'd14}   : {F0, 7'd14};   // - / _  (Atari - key)
        8'h2E: hid2atari_pc = sh ? {F0, 7'd6}    : {F0, 7'd15};   // = / +  (Atari = / + keys)
        8'h2F: hid2atari_pc = sh ? {PASS, 7'h7F} : {F1, 7'd32};   // [ / {  (Atari Sh+, ; { unmapped)
        8'h30: hid2atari_pc = sh ? {PASS, 7'h7F} : {F1, 7'd34};   // ] / }  (Atari Sh+. ; } unmapped)
        8'h31,
        8'h32: hid2atari_pc = sh ? {F1, 7'd15}   : {F1, 7'd6};    // \ / |  (Atari Sh++ / Sh+=)
        8'h34: hid2atari_pc = sh ? {F1, 7'd30}   : {F1, 7'd51};   // ' / "  (Atari Sh+7 / Sh+2)
        8'h36: hid2atari_pc = sh ? {F0, 7'd54}   : {PASS, 7'd32}; // , / <  (Atari < key)
        8'h37: hid2atari_pc = sh ? {F0, 7'd55}   : {PASS, 7'd34}; // . / >  (Atari > key)
        default: hid2atari_pc = {PASS, hid2atari(hid)};           // letters, digits, specials
    endcase
endfunction

// Per-slot press-time latch: a held key's mapping is fixed at key-down (0 -> code),
// so releasing Shift before the key cannot morph its matrix code into a second
// keypress. In ATARI mode this is the positional table one sys_clk later — POKEY's
// scan/debounce makes that invisible.
wire shift_pressed   = key_modifiers[1] | key_modifiers[5]; // LShift | RShift

// The key slots and modifiers can come from the 12 MHz USB-HID host (async to this
// clock). Register them here (2 FFs) so the latch's comparator and its data see ONE
// sample: comparing the raw input while latching a mapping computed from a different
// instant of the same changing byte left a slot with hid=0 but a live mapping, i.e. a
// phantom stuck key (HW-observed 2026-09-19: endless '^', healed by the next keystroke).
reg [7:0] k1_m = 8'h00, k1_s = 8'h00, k2_m = 8'h00, k2_s = 8'h00;
reg [7:0] k3_m = 8'h00, k3_s = 8'h00, k4_m = 8'h00, k4_s = 8'h00;
reg       sh_m = 1'b0,  sh_s = 1'b0;
always_ff @(posedge clk) begin
    k1_m <= key1; k1_s <= k1_m;   k2_m <= key2; k2_s <= k2_m;
    k3_m <= key3; k3_s <= k3_m;   k4_m <= key4; k4_s <= k4_m;
    sh_m <= shift_pressed; sh_s <= sh_m;
end

// One explicit register pair per slot (no arrays: Gowin infers RAM from small arrays,
// which cannot be written 4-wide per cycle nor read 4-wide combinationally).
`define KEY_LATCH(N, KEY) \
    reg [7:0] hid_l``N = 8'h00; \
    reg [8:0] map_l``N = {PASS, 7'h7F}; \
    always_ff @(posedge clk) begin \
        if (!reset_n) begin \
            hid_l``N <= 8'h00; \
            map_l``N <= {PASS, 7'h7F}; \
        end else if (KEY != hid_l``N) begin \
            hid_l``N <= KEY; \
            map_l``N <= (KEY == 8'h00) ? {PASS, 7'h7F} \
                      : pc_layout      ? hid2atari_pc(KEY, sh_s) \
                                       : {PASS, hid2atari(KEY)}; \
        end \
    end
`KEY_LATCH(0, k1_s)
`KEY_LATCH(1, k2_s)
`KEY_LATCH(2, k3_s)
`KEY_LATCH(3, k4_s)
`undef KEY_LATCH

// ── Build atari_keyboard and special flags from the latched key slots ─────────
wire [6:0] p1 = map_l0[6:0];
wire [6:0] p2 = map_l1[6:0];
wire [6:0] p3 = map_l2[6:0];
wire [6:0] p4 = map_l3[6:0];

// Effective shift answered to POKEY: a held key needing forced/suppressed shift wins
// over the physical modifier (F1 beats F0 if two held keys disagree); with no such
// key held it is the physical Shift, so shift-only presses reach games unchanged.
wire force1 = (~p1[6] && map_l0[8:7] == F1) | (~p2[6] && map_l1[8:7] == F1) |
              (~p3[6] && map_l2[8:7] == F1) | (~p4[6] && map_l3[8:7] == F1);
wire force0 = (~p1[6] && map_l0[8:7] == F0) | (~p2[6] && map_l1[8:7] == F0) |
              (~p3[6] && map_l2[8:7] == F0) | (~p4[6] && map_l3[8:7] == F0);
wire eff_shift = force1 ? 1'b1 : (force0 ? 1'b0 : shift_pressed);

// OR in each valid key as a one-hot bit in the 64-bit keyboard state
wire [63:0] atari_keyboard =
    ((p1[6] == 0) ? (64'd1 << p1[5:0]) : 64'd0) |
    ((p2[6] == 0) ? (64'd1 << p2[5:0]) : 64'd0) |
    ((p3[6] == 0) ? (64'd1 << p3[5:0]) : 64'd0) |
    ((p4[6] == 0) ? (64'd1 << p4[5:0]) : 64'd0) |
    // Right Alt (modifier[6]) → Atari Inverse Video (bit 39)
    (key_modifiers[6] ? 64'h0000_0080_0000_0000 : 64'd0);

// Modifiers (shift_pressed is defined above, next to the latch)

// Arrow keys imply CTRL: on the Atari the cursor keys ARE -/=/+/*-with-CTRL, so a
// PC arrow key should move the cursor directly instead of typing the bare key.
// Safe by construction: this module sees keys only AFTER the joystick-mode arrow
// suppression and the OSD input mask, so the implied CTRL never fires during
// stick play or menu navigation. Real CTRL still works identically. The [ ] \ '
// raw-key mappings to the same Atari codes are unaffected (HID arrows only).
wire arrow_held = (key1 >= 8'h4F && key1 <= 8'h52) |
                  (key2 >= 8'h4F && key2 <= 8'h52) |
                  (key3 >= 8'h4F && key3 <= 8'h52) |
                  (key4 >= 8'h4F && key4 <= 8'h52);
wire control_pressed = key_modifiers[0] | key_modifiers[4] | arrow_held; // LCtrl | RCtrl | arrows

// Break: Grave/Tilde (0x35) or Num Lock (0x53)
wire break_pressed =
    (key1 == 8'h35) | (key2 == 8'h35) | (key3 == 8'h35) | (key4 == 8'h35) |
    (key1 == 8'h53) | (key2 == 8'h53) | (key3 == 8'h53) | (key4 == 8'h53);

// Console keys: F6=Start F7=Select F8=Option
assign consol_start  = (key1==8'h3F)|(key2==8'h3F)|(key3==8'h3F)|(key4==8'h3F);
assign consol_select = (key1==8'h40)|(key2==8'h40)|(key3==8'h40)|(key4==8'h40);
assign consol_option = (key1==8'h41)|(key2==8'h41)|(key3==8'h41)|(key4==8'h41);

// ── Keyboard matrix response (combinational, identical logic to VHDL) ─────────
wire       key_hit = atari_keyboard[~keyboard_scan];

assign keyboard_response[0] = ~key_hit;
assign keyboard_response[1] =
    ~( (keyboard_scan[5:4] == 2'b00 && break_pressed)   |
       (keyboard_scan[5:4] == 2'b10 && eff_shift)       |
       (keyboard_scan[5:4] == 2'b11 && control_pressed) );

endmodule
