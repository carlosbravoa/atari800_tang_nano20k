// fat_reader.sv — FAT32 root-directory scanner + file byte streamer
// Finds OS.ROM then BASIC.ROM in the root dir, streams bytes to caller.
// Assumptions: FAT32, 512 B/sector, files in root dir only.

module fat_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,       // pulse after sd_card.ready

    output reg         done,
    output reg         error,

    output reg         byte_valid,  // 1-cycle pulse per ROM byte
    output reg  [7:0]  byte_data,
    output reg         is_basic,    // 0=OS.ROM  1=BASIC.ROM

    // SD card read port
    output reg         sd_req,
    output reg  [31:0] sd_lba,
    input  wire        sd_valid,
    input  wire [7:0]  sd_byte,
    input  wire        sd_done,
    input  wire        sd_error
);

typedef enum logic [3:0] {
    ST_IDLE, ST_MBR, ST_BPB,
    ST_DIR,  ST_DIR_FAT,
    ST_FILE, ST_FILE_FAT,
    ST_DONE, ST_ERROR
} st_t;

st_t st;

// FAT32 volume layout
reg [31:0] part_lba, fat_lba, data_lba, root_clust;
reg [7:0]  spc;
// BPB temporaries
reg [15:0] rsvd;
reg [7:0]  nfat;
reg [31:0] fat_sz;

// Cluster navigation
reg [31:0] cur_clust;
reg [7:0]  cur_sect;
reg [9:0]  byte_pos;  // 0..511 within current sector

// Directory entry parse
reg [7:0]  ename[0:10];
reg [7:0]  eattr;
reg [31:0] eclust;
reg [31:0] os_clust, basic_clust;
reg        found_os, found_basic, eod;

// FAT chain lookup
reg [31:0] fat_entry;
reg [8:0]  fat_off;   // fat_clust[6:0]<<2

// File streaming
reg reading_basic;

// ── Combinational helpers ─────────────────────────────────────────────────────
wire [4:0]  eb   = byte_pos[4:0];   // byte within 32-byte dir entry

wire name_is_os =
    ename[0]==8'h4F && ename[1]==8'h53 && ename[2]==8'h20 && ename[3]==8'h20 &&
    ename[4]==8'h20 && ename[5]==8'h20 && ename[6]==8'h20 && ename[7]==8'h20 &&
    ename[8]==8'h52 && ename[9]==8'h4F && ename[10]==8'h4D;

wire name_is_basic =
    ename[0]==8'h42 && ename[1]==8'h41 && ename[2]==8'h53 && ename[3]==8'h49 &&
    ename[4]==8'h43 && ename[5]==8'h20 && ename[6]==8'h20 && ename[7]==8'h20 &&
    ename[8]==8'h52 && ename[9]==8'h4F && ename[10]==8'h4D;

// Data sector LBA for (cur_clust, cur_sect)
wire [31:0] clust_lba = data_lba + (cur_clust - 32'd2) * {24'd0, spc} + {24'd0, cur_sect};

// FAT sector read: is current byte inside the 4-byte entry for fat_off?
wire        in_fat = (byte_pos >= {1'b0, fat_off}) && (byte_pos < ({1'b0, fat_off} + 10'd4));
wire [1:0]  fat_bi = byte_pos[1:0];

// ── Main ──────────────────────────────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= ST_IDLE;  done <= 0;  error <= 0;
        byte_valid <= 0;  byte_data <= 0;  is_basic <= 0;
        sd_req <= 0;  sd_lba <= 0;
        byte_pos <= 0;
        part_lba <= 0;  fat_lba  <= 0;  data_lba   <= 0;
        root_clust <= 2; spc <= 1;
        rsvd <= 0;  nfat <= 2;  fat_sz <= 0;
        cur_clust <= 0;  cur_sect <= 0;
        eattr <= 0;  eclust <= 0;  eod <= 0;
        fat_entry <= 0;  fat_off <= 0;
        os_clust <= 0;  basic_clust <= 0;
        found_os <= 0;  found_basic <= 0;
        reading_basic <= 0;
        for (int i = 0; i < 11; i++) ename[i] <= 8'h20;
    end else begin
        sd_req     <= 1'b0;
        byte_valid <= 1'b0;

        if (sd_error) st <= ST_ERROR;
        else case (st)

        // ── Wait for start pulse ──────────────────────────────────────────────
        ST_IDLE:
            if (start) begin
                sd_lba <= 32'd0;  sd_req <= 1'b1;
                byte_pos <= 0;  st <= ST_MBR;
            end

        // ── Read MBR: bytes 454-457 = partition 0 LBA start ──────────────────
        ST_MBR: begin
            if (sd_valid) begin
                byte_pos <= byte_pos + 1;
                case (byte_pos)
                    454: part_lba[ 7: 0] <= sd_byte;
                    455: part_lba[15: 8] <= sd_byte;
                    456: part_lba[23:16] <= sd_byte;
                    457: part_lba[31:24] <= sd_byte;
                endcase
            end
            if (sd_done) begin
                sd_lba <= part_lba;  sd_req <= 1'b1;
                byte_pos <= 0;  st <= ST_BPB;
            end
        end

        // ── Read BPB: extract FAT32 parameters ───────────────────────────────
        ST_BPB: begin
            if (sd_valid) begin
                byte_pos <= byte_pos + 1;
                case (byte_pos)
                    13: spc           <= sd_byte;
                    14: rsvd[ 7:0]    <= sd_byte;
                    15: rsvd[15:8]    <= sd_byte;
                    16: nfat          <= sd_byte;
                    36: fat_sz[ 7: 0] <= sd_byte;
                    37: fat_sz[15: 8] <= sd_byte;
                    38: fat_sz[23:16] <= sd_byte;
                    39: fat_sz[31:24] <= sd_byte;
                    44: root_clust[ 7: 0] <= sd_byte;
                    45: root_clust[15: 8] <= sd_byte;
                    46: root_clust[23:16] <= sd_byte;
                    47: root_clust[31:24] <= sd_byte;
                endcase
            end
            if (sd_done) begin
                fat_lba  <= part_lba + {16'd0, rsvd};
                data_lba <= part_lba + {16'd0, rsvd} + {8'd0, nfat} * fat_sz;
                cur_clust <= root_clust;  cur_sect <= 0;
                byte_pos <= 0;  eod <= 0;
                st <= ST_DIR;
            end
        end

        // ── Scan root directory cluster chain ─────────────────────────────────
        ST_DIR: begin
            // Issue read for current dir sector
            if (byte_pos == 0 && !sd_req)
                { sd_lba, sd_req } <= { clust_lba, 1'b1 };

            if (sd_valid && !eod) begin
                byte_pos <= byte_pos + 1;
                if (eb <= 10)         ename[eb] <= sd_byte;
                if (eb == 11)         eattr      <= sd_byte;
                if (eb ==  0)         eclust     <= 32'd0;   // clear on new entry
                if (eb == 20)         eclust[23:16] <= sd_byte;
                if (eb == 21)         eclust[31:24] <= sd_byte;
                if (eb == 26)         eclust[ 7: 0] <= sd_byte;
                if (eb == 27)         eclust[15: 8] <= sd_byte;

                // First byte of entry: 0x00 = end of directory
                if (eb == 0 && sd_byte == 8'h00) eod <= 1'b1;

                // Last byte of entry: check for name match
                if (eb == 31 && eattr != 8'h0F && !eattr[4]) begin
                    if (!found_os    && name_is_os)
                        { os_clust,    found_os    } <= { eclust, 1'b1 };
                    if (!found_basic && name_is_basic)
                        { basic_clust, found_basic } <= { eclust, 1'b1 };
                end
            end else if (sd_valid) begin
                byte_pos <= byte_pos + 1;  // keep counting even after eod
            end

            if (sd_done) begin
                byte_pos <= 0;
                if (found_os && found_basic) begin
                    cur_clust <= os_clust;  cur_sect <= 0;
                    reading_basic <= 0;  st <= ST_FILE;
                end else if (eod) st <= ST_ERROR;
                else if (cur_sect + 1 < spc)
                    cur_sect <= cur_sect + 1;
                else begin
                    // Follow FAT chain for next dir cluster
                    fat_off   <= {cur_clust[6:0], 2'b00};
                    fat_entry <= 0;
                    sd_lba    <= fat_lba + (cur_clust >> 7);
                    sd_req    <= 1'b1;
                    cur_sect  <= 0;
                    st        <= ST_DIR_FAT;
                end
            end
        end

        // ── Read FAT sector → next directory cluster ──────────────────────────
        ST_DIR_FAT: begin
            if (sd_valid) begin
                byte_pos <= byte_pos + 1;
                if (in_fat) case (fat_bi)
                    0: fat_entry[ 7: 0] <= sd_byte;
                    1: fat_entry[15: 8] <= sd_byte;
                    2: fat_entry[23:16] <= sd_byte;
                    3: fat_entry[31:24] <= sd_byte;
                endcase
            end
            if (sd_done) begin
                byte_pos <= 0;
                if (fat_entry[27:0] >= 28'hFFFFFF8) st <= ST_ERROR;
                else begin cur_clust <= {4'd0, fat_entry[27:0]}; st <= ST_DIR; end
            end
        end

        // ── Stream file data sectors ──────────────────────────────────────────
        ST_FILE: begin
            if (byte_pos == 0 && !sd_req)
                { sd_lba, sd_req } <= { clust_lba, 1'b1 };

            if (sd_valid) begin
                byte_pos   <= byte_pos + 1;
                byte_valid <= 1'b1;
                byte_data  <= sd_byte;
                is_basic   <= reading_basic;
            end

            if (sd_done) begin
                byte_pos <= 0;
                if (cur_sect + 1 < spc) cur_sect <= cur_sect + 1;
                else begin
                    fat_off   <= {cur_clust[6:0], 2'b00};
                    fat_entry <= 0;
                    sd_lba    <= fat_lba + (cur_clust >> 7);
                    sd_req    <= 1'b1;
                    cur_sect  <= 0;
                    st        <= ST_FILE_FAT;
                end
            end
        end

        // ── Read FAT sector → next file cluster ───────────────────────────────
        ST_FILE_FAT: begin
            if (sd_valid) begin
                byte_pos <= byte_pos + 1;
                if (in_fat) case (fat_bi)
                    0: fat_entry[ 7: 0] <= sd_byte;
                    1: fat_entry[15: 8] <= sd_byte;
                    2: fat_entry[23:16] <= sd_byte;
                    3: fat_entry[31:24] <= sd_byte;
                endcase
            end
            if (sd_done) begin
                byte_pos <= 0;
                if (fat_entry[27:0] >= 28'hFFFFFF8) begin
                    // End of file cluster chain
                    if (!reading_basic) begin
                        cur_clust <= basic_clust;  cur_sect <= 0;
                        reading_basic <= 1'b1;  st <= ST_FILE;
                    end else begin
                        done <= 1'b1;  st <= ST_DONE;
                    end
                end else begin
                    cur_clust <= {4'd0, fat_entry[27:0]};  st <= ST_FILE;
                end
            end
        end

        ST_DONE:  ;   // hold done=1
        ST_ERROR: error <= 1'b1;
        default:  st <= ST_ERROR;
        endcase
    end
end

endmodule
