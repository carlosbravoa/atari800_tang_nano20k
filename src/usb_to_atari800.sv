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

// ── Build atari_keyboard and special flags from current key slots ─────────────
wire [6:0] p1 = hid2atari(key1);
wire [6:0] p2 = hid2atari(key2);
wire [6:0] p3 = hid2atari(key3);
wire [6:0] p4 = hid2atari(key4);

// OR in each valid key as a one-hot bit in the 64-bit keyboard state
wire [63:0] atari_keyboard =
    ((p1[6] == 0) ? (64'd1 << p1[5:0]) : 64'd0) |
    ((p2[6] == 0) ? (64'd1 << p2[5:0]) : 64'd0) |
    ((p3[6] == 0) ? (64'd1 << p3[5:0]) : 64'd0) |
    ((p4[6] == 0) ? (64'd1 << p4[5:0]) : 64'd0) |
    // Right Alt (modifier[6]) → Atari Inverse Video (bit 39)
    (key_modifiers[6] ? 64'h0000_0080_0000_0000 : 64'd0);

// Modifiers
wire shift_pressed   = key_modifiers[1] | key_modifiers[5]; // LShift | RShift
wire arrow_pressed   = (key1 >= 8'h4F && key1 <= 8'h52) |
                       (key2 >= 8'h4F && key2 <= 8'h52) |
                       (key3 >= 8'h4F && key3 <= 8'h52) |
                       (key4 >= 8'h4F && key4 <= 8'h52);
wire control_pressed = key_modifiers[0] | key_modifiers[4] | arrow_pressed; // LCtrl  | RCtrl | arrow keys auto-Ctrl


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
       (keyboard_scan[5:4] == 2'b10 && shift_pressed)   |
       (keyboard_scan[5:4] == 2'b11 && control_pressed) );

endmodule
