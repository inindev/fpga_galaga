// fb_writer.sv - frame buffer writer for the Galaga port on the Tang Nano 20K.
//
// Takes the core's pixels (RGB 3:3:2, one byte per pixel) and writes each frame into one of
// three frame buffers in SDRAM, in display order, rotated or not.
//
// CAPTURE (clk_core = 48 MHz). On every clock with pix_en high (one clock after the core's
// video_ce, see top.sv), the core's pixel, blankn and vs are sampled: the values its registers
// took at the video_ce edge, which all describe the same pixel. The stored area is the core's
// active picture (blankn high), from pixel X0 and line Y0 of it, SRC_W x SRC_H pixels. A frame starts at the vertical sync (vs low, galaga's
// lines 260-3, inside the vertical blank): the line count restarts and the rotate option is
// taken there, so it applies to whole frames. A line ends where blankn falls. Each line is
// written into a staging block RAM of 8 lines (two groups of 4). When the 4th line of a group
// ends, grp_tgl toggles and grp_g / grp_rot say which group it was (they stay put for the 4
// lines it takes to fill the next group).
//
// DRAIN (clk_sd = 32 MHz). grp_tgl is synchronised (grp_meta) and each finished group is
// written to the frame buffer as 32-bit words, four pixels per word (pixel 0 in bits 7:0),
// read byte by byte from the staging RAM:
//   not rotated  display = source: rows 4g..4g+3, SRC_W/4 words each (rounded up)
//   rotated, CW  display (dx, dy) = (SRC_H-1-y, x): word column SRC_H/4-1-g of every row
//                dy = 0..SRC_W-1, lanes 0..3 from source lines 4g+3..4g
// so the reader always reads display rows straight through. The picture is always turned
// clockwise (the cabinet's monitor); a cocktail cabinet's flip for player 2 is drawn by the
// game itself and stored as it is. A group must be drained before the next one is complete
// (4 source lines, 250 us); it needs SRC_W words, or 4 x SRC_W/4 (about 130 us with the
// reader and refresh sharing the SDRAM). If it is not, `overrun` is set (sticky, a debug
// output) and the frame is dropped.
//
// BUFFERS (clk_sd). Group 0 starts a frame in the buffer that is neither the latest finished
// one (latest_buf) nor the one the reader shows (rd_buf, from fb_reader in the same clock);
// with three buffers there is always one. When the last group has been written, the buffer
// becomes latest_buf, with latest_rot = the rotate flag it was written with, and have_frame
// goes high. A frame with a missing group (a pause of the source does not lose one; a restart
// of the video timing mid-frame would) is dropped.
//
// Frame buffer layout (byte address):
//   FB_BASE + {buffer[1:0], display row[8:0], word[6:0], 2'b00}
// so SRC_W and SRC_H can each be up to 512 pixels, at most 128 words (512 pixels) per row.
// SRC_H must be a multiple of 4.
//
// Clock crossings: the staging RAM is a dual-clock block RAM (written on clk_core, read on
// clk_sd; a group is read only after it is complete and before it is written again); grp_tgl
// goes through a 2-flop synchroniser (grp_meta), and grp_g/grp_rot are read only after it,
// when they have been stable for at least 2 clk_sd cycles. `rotate` is synchronised into
// clk_core (rot_meta).

module fb_writer #(
    parameter integer SRC_W   = 288,        // stored pixels per source line
    parameter integer SRC_H   = 224,        // stored source lines (multiple of 4)
    parameter integer X0      = 0,          // first stored pixel of an active line
    parameter integer Y0      = 0,          // first stored active line
    parameter [22:0]  FB_BASE = 23'h000000  // SDRAM byte address of buffer 0 (1 MB aligned)
) (
    // core side
    input  logic        clk_core,
    input  logic        pix_en,         // core pixel enable, 1-clock pulse (6.144 MHz average)
    input  logic [7:0]  pix,            // {r[2:0], g[2:0], b[1:0]}
    input  logic        blankn,         // 1 in the active picture
    input  logic        vs,             // vertical sync, active low
    input  logic        rotate,         // any clock (core_config[16]), synchronised here

    // SDRAM side
    input  logic        clk_sd,
    input  logic        resetn,         // clk_sd domain
    output logic        wreq,           // write request (level), held until wack
    output logic [22:0] waddr,
    output logic [31:0] wdata,
    input  logic        wack,           // 1-clock pulse: the request has been taken

    // buffer exchange with fb_reader (clk_sd)
    input  logic [1:0]  rd_buf,
    output logic [1:0]  latest_buf,
    output logic        latest_rot,
    output logic        have_frame,
    output logic        overrun         // sticky: a group was not drained in time (debug)
);

    localparam integer NGRP  = SRC_H / 4;           // groups (and rotated words per row)
    localparam integer WPR_N = (SRC_W + 3) / 4;     // words per row, not rotated

    initial begin
        if (SRC_H % 4 != 0 || SRC_H > 512 || SRC_W > 512)
            $error("fb_writer: SRC_H must be a multiple of 4, SRC_W and SRC_H at most 512");
    end

    // ================================================================= capture (clk_core)
    logic rot_meta = 1'b0, rot_c = 1'b0;
    always_ff @(posedge clk_core) {rot_c, rot_meta} <= {rot_meta, rotate};

    logic [9:0]  px      = 10'd0;           // pixel index in the active line (saturates)
    logic [9:0]  ly      = 10'd0;           // active line index in the frame (saturates)
    logic        in_line = 1'b0;
    logic        f_rot   = 1'b0;
    logic        st_we   = 1'b0;
    logic [11:0] st_wa   = 12'd0;
    logic [7:0]  st_wd   = 8'd0;
    logic        grp_tgl = 1'b0;
    logic [6:0]  grp_g   = 7'd0;
    logic        grp_rot = 1'b0;

    wire  [9:0]  sl   = ly - 10'(Y0);      // stored line
    wire  [9:0]  sx   = px - 10'(X0);      // stored pixel
    wire         in_y = ly >= 10'(Y0) && ly < 10'(Y0 + SRC_H);
    wire         in_x = px >= 10'(X0) && px < 10'(X0 + SRC_W);

    always_ff @(posedge clk_core) begin
        st_we <= 1'b0;
        if (pix_en) begin
            if (!vs) begin                          // vertical sync: a new frame
                ly      <= 10'd0;
                px      <= 10'd0;
                in_line <= 1'b0;
                f_rot   <= rot_c;
            end else if (!blankn) begin
                px <= 10'd0;
                if (in_line) begin                  // a line has just ended
                    in_line <= 1'b0;
                    if (ly != 10'h3FF) ly <= ly + 1'b1;
                    if (in_y && sl[1:0] == 2'd3) begin
                        grp_tgl <= ~grp_tgl;
                        grp_g   <= sl[8:2];
                        grp_rot <= f_rot;
                    end
                end
            end else begin
                in_line <= 1'b1;
                if (px != 10'h3FF) px <= px + 1'b1;
                if (in_x && in_y) begin
                    st_we <= 1'b1;
                    st_wa <= {sl[2:0], sx[8:0]};    // {group parity, line in group, x}
                    st_wd <= pix;
                end
            end
        end
    end

    // staging RAM: 2 groups x 4 lines x 512 pixels (two block RAMs)
    (* syn_ramstyle = "block_ram" *)
    logic [7:0] stg [0:4095];
    logic [11:0] st_ra;
    logic [7:0]  st_q;

    always_ff @(posedge clk_core)
        if (st_we) stg[st_wa] <= st_wd;

    always_ff @(posedge clk_sd)
        st_q <= stg[st_ra];

    // ================================================================= drain (clk_sd)
    logic grp_meta = 1'b0, grp_s = 1'b0, grp_d = 1'b0;
    always_ff @(posedge clk_sd) {grp_d, grp_s, grp_meta} <= {grp_s, grp_meta, grp_tgl};
    wire grp_ev = grp_s ^ grp_d;

    localparam [1:0] D_IDLE = 2'd0, D_RD = 2'd1, D_LAST = 2'd2, D_REQ = 2'd3;
    logic [1:0] dst;
    logic [6:0] dg;                 // group being drained
    logic       drot;               // its frame's rotate flag
    logic [8:0] dx9;                // rotated: source x; not rotated: word column
    logic [1:0] dj;                 // not rotated: line in the group
    logic [1:0] lane, lane_d;
    logic       lv_d;
    logic [31:0] wbuf;

    logic       fr_ok;              // a frame is being written and is complete so far
    logic [6:0] exp_g;
    logic [1:0] wb;                 // buffer being written

    // buffer that is neither a nor b
    function automatic [1:0] other(input [1:0] a, input [1:0] b);
        if (a != 2'd0 && b != 2'd0)      other = 2'd0;
        else if (a != 2'd1 && b != 2'd1) other = 2'd1;
        else                             other = 2'd2;
    endfunction

    // staging read address for the current lane
    wire [1:0] rline = drot ? 2'd3 - lane : dj;
    wire [8:0] rx    = drot ? dx9 : {dx9[6:0], lane};
    assign st_ra = {dg[0], rline, rx};

    // display position of the current word
    wire [8:0] row = drot ? dx9 : {dg, dj};
    wire [6:0] col = drot ? 7'(NGRP - 1) - dg : dx9[6:0];

    // last word of the group
    wire last_word = drot ? (dx9 == 9'(SRC_W - 1))
                          : (dj == 2'd3 && dx9 == 9'(WPR_N - 1));

    always_ff @(posedge clk_sd) begin
        if (!resetn) begin
            dst        <= D_IDLE;
            wreq       <= 1'b0;
            fr_ok      <= 1'b0;
            exp_g      <= 7'd0;
            wb         <= 2'd1;
            latest_buf <= 2'd0;
            latest_rot <= 1'b0;
            have_frame <= 1'b0;
            overrun    <= 1'b0;
            lv_d       <= 1'b0;
        end else begin
            // byte lanes come back one clock after their address
            lv_d   <= dst == D_RD;
            lane_d <= lane;
            if (lv_d) wbuf[8*lane_d +: 8] <= st_q;

            if (grp_ev) begin
                // a new group is complete
                if (dst != D_IDLE) begin
                    overrun <= 1'b1;            // the previous one is not written yet
                    wreq    <= 1'b0;
                end
                exp_g <= grp_g + 1'b1;
                if (grp_g == 7'd0) begin
                    fr_ok <= 1'b1;
                    wb    <= other(latest_buf, rd_buf);
                    drot  <= grp_rot;
                end else if (!(fr_ok && grp_g == exp_g && dst == D_IDLE))
                    fr_ok <= 1'b0;
                if (grp_g == 7'd0 || (fr_ok && grp_g == exp_g && dst == D_IDLE)) begin
                    dg   <= grp_g;
                    dx9  <= 9'd0;
                    dj   <= 2'd0;
                    lane <= 2'd0;
                    dst  <= D_RD;
                end else
                    dst <= D_IDLE;
            end else case (dst)
                D_RD: begin
                    lane <= lane + 1'b1;
                    if (lane == 2'd3) dst <= D_LAST;
                end
                D_LAST: begin                   // lane 3 is written into wbuf at this edge
                    wreq  <= 1'b1;
                    waddr <= FB_BASE + {3'd0, wb, row, col, 2'b00};
                    dst   <= D_REQ;
                end
                D_REQ: begin
                    if (wack) begin
                        wreq <= 1'b0;
                        lane <= 2'd0;
                        if (last_word) begin
                            dst <= D_IDLE;
                            if (dg == 7'(NGRP - 1)) begin
                                // frame complete
                                latest_buf <= wb;
                                latest_rot <= drot;
                                have_frame <= 1'b1;
                                fr_ok      <= 1'b0;
                            end
                        end else begin
                            dst <= D_RD;
                            if (drot)
                                dx9 <= dx9 + 1'b1;
                            else if (dx9 == 9'(WPR_N - 1)) begin
                                dx9 <= 9'd0;
                                dj  <= dj + 1'b1;
                            end else
                                dx9 <= dx9 + 1'b1;
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    assign wdata = wbuf;

endmodule
