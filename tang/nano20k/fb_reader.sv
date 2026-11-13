// fb_reader.sv - frame buffer reader and 1280x720 scan-out for the Galaga port on the
// Tang Nano 20K, with the TangCore menu overlay.
//
// FETCH (clk_sd = 32 MHz). At the start of each HDMI frame (fs_tgl, sent at HDMI line FS_LINE,
// in the vertical blank) the reader takes the latest finished buffer from fb_writer
// (latest_buf, latest_rot, have_frame) and shows it for the whole HDMI frame: rd_buf tells the
// writer not to touch it. The buffer's display rows are read from SDRAM in order into a line
// RAM of 8 rows of up to 128 words (1024 x 32 bits, two block RAMs), up to 8 rows ahead of the
// row on screen. The scan-out toggles rdn_tgl when it is done with a row, which frees that
// row's slot.
//   rotated:     SRC_W rows of SRC_H pixels (SRC_H/4 words)
//   not rotated: SRC_H rows of SRC_W pixels (SRC_W/4 words, rounded up)
// A row takes SRC_H/4 or SRC_W/4 reads (56 for 224 pixels, 72 for 288; at one read per 7
// clocks 12 or 16 us, twice that when the writer takes every other access) and is on screen
// for at least 2 HDMI lines (44.4 us).
//
// SCAN-OUT (clk_pix = 74.25 MHz), on the hdl-util hdmi counters (cx, cy; picture at cx < 1280,
// cy < 720). The picture's layout comes from the rotate flag of the buffer being shown,
// taken at the last line of the frame (so it applies to the whole HDMI frame):
//   rotated:     each pixel 3x across, rows alternately 2 and 3 lines down (even rows 2,
//                odd rows 3: 2.5x on average; SRC_H*3 x SRC_W*5/2 = 672 x 720)
//   not rotated: each pixel 3x across, each row 3x down (SRC_W*3 x SRC_H*3 = 864 x 672)
// centred on the 1280 x 720 screen, black around it. Before the first frame has been written
// the screen is black.
// rgb is produced with a lead of 3 clocks against cx/cy (line RAM read register, game pixel
// register, menu mix register), so counters are re-armed when cx == frame_width-4, as in the
// Taito System SJ port's linebuf.sv; rgb is then the pixel for the current cx/cy.
//
// MENU (TangCore overlay): iosys_bl616's textdisp draws a 256x224 picture, shown 3x across and
// 3x down in a 768 x 672 window at x 256-1023, lines 24-695: the same window as the monitor
// core and common/video/video_out.v, so the menu does not move or change size between cores.
// overlay_x steps every 3 clocks (the least textdisp needs) and textdisp returns overlay_color
// 2 clocks after a step, in the same clock as the game pixel register; the third stage mixes
// the two. xx is set to 255 at the re-arm and goes to 0 at the window's left edge, so
// overlay_x toggles bit 0 there, which is how textdisp sees a new pixel.
//   overlay & !osd_strip: menu pixels (non-zero colour) over the picture dimmed to 1/4
//   overlay &  osd_strip: the volume bar strip, text columns 8-23 of rows 23-24 (source
//                         pixels 64-191, lines 184-199): lit pixels white on a band 2 source
//                         pixels wider all round, where the picture is dimmed to 1/8 with a
//                         green tint; the rest of the picture is untouched
//
// Clock crossings: the line RAM is a dual-clock block RAM (written on clk_sd, read on clk_pix;
// a slot is written only after the scan-out has finished with it, see above). fs_tgl and
// rdn_tgl go to clk_sd through 2-flop synchronisers (fs_meta, rdn_meta); they toggle at most
// once per HDMI line and never on the same line. The frame's buffer flags (cur_rot, cur_valid)
// change in clk_sd right after fs_tgl and are synchronised into clk_pix (rot_meta, val_meta)
// and taken 27 lines later. overlay and osd_strip (iosys clock) come in through ovl_meta and
// strip_meta. The first flop of each synchroniser is named *_meta (see the .sdc).

module fb_reader #(
    parameter integer SRC_W   = 288,
    parameter integer SRC_H   = 224,
    parameter [22:0]  FB_BASE = 23'h000000,
    parameter integer FS_LINE = 722         // HDMI line on which a new frame is picked
) (
    // SDRAM side
    input  logic        clk_sd,
    input  logic        resetn,         // clk_sd domain
    output logic        rreq,           // read request (level), held until rack
    output logic [22:0] raddr,
    input  logic        rack,           // 1-clock pulse: the request has been taken
    input  logic [31:0] rdata,
    input  logic        rvalid,         // 1-clock pulse with rdata, in request order

    // buffer exchange with fb_writer (clk_sd)
    input  logic [1:0]  latest_buf,
    input  logic        latest_rot,
    input  logic        have_frame,
    output logic [1:0]  rd_buf,

    // scan-out
    input  logic        clk_pix,
    input  logic [10:0] cx,
    input  logic [9:0]  cy,
    input  logic [10:0] frame_width,
    input  logic [9:0]  frame_height,
    output logic [23:0] rgb,

    // menu overlay (iosys_bl616)
    input  logic        overlay,        // iosys clock domain
    input  logic        osd_strip,      // iosys clock domain
    output logic [7:0]  overlay_x,      // clk_pix domain
    output logic [7:0]  overlay_y,
    input  logic [14:0] overlay_color   // BGR5, 2 clocks after overlay_x/overlay_y
);

    localparam integer NGRP  = SRC_H / 4;           // words per row, rotated
    localparam integer WPR_N = (SRC_W + 3) / 4;     // words per row, not rotated

    // picture size and position on the 1280 x 720 screen
    localparam integer PW_R = 3 * SRC_H, PH_R = SRC_W * 5 / 2;
    localparam integer PW_N = 3 * SRC_W, PH_N = 3 * SRC_H;
    localparam integer X0_R = (1280 - PW_R) / 2, Y0_R = (720 - PH_R) / 2;
    localparam integer X0_N = (1280 - PW_N) / 2, Y0_N = (720 - PH_N) / 2;

    initial begin
        if (PW_R > 1280 || PH_R > 720 || PW_N > 1280 || PH_N > 720 || SRC_H % 4 != 0 ||
            SRC_W % 2 != 0 || SRC_W > 512 || SRC_H > 512)
            $error("fb_reader: picture does not fit 1280x720, or SRC_W / SRC_H unsupported");
    end

    localparam integer OVL_VSTART = 24;     // (720 - 672) / 2
    localparam integer OVL_X0     = 256;    // (1280 - 768) / 2
    localparam integer OVL_H      = 224;

    logic fs_tgl  = 1'b0;                   // clk_pix: pick a new frame
    logic rdn_tgl = 1'b0;                   // clk_pix: done with a row

    // ================================================================= fetch (clk_sd)
    logic fs_meta = 1'b0, fs_s = 1'b0, fs_d = 1'b0;
    logic rdn_meta = 1'b0, rdn_s = 1'b0, rdn_d = 1'b0;
    always_ff @(posedge clk_sd) begin
        {fs_d, fs_s, fs_meta}    <= {fs_s, fs_meta, fs_tgl};
        {rdn_d, rdn_s, rdn_meta} <= {rdn_s, rdn_meta, rdn_tgl};
    end
    wire fs_ev  = fs_s ^ fs_d;
    wire rdn_ev = rdn_s ^ rdn_d;

    logic       cur_valid = 1'b0, cur_rot = 1'b0;
    logic [9:0] nf;                 // next row to request
    logic [6:0] wc;                 // next word of it
    logic [9:0] cons;               // rows the scan-out is done with
    logic [9:0] ret_row;            // row / word of the next read data
    logic [6:0] ret_c;
    logic       pend_fs;            // new frame requested, waiting for the bus to settle
    logic [1:0] settle;
    logic       inflight;           // a read has been taken and its data is not back

    wire [9:0] dh    = cur_rot ? 10'(SRC_W) : 10'(SRC_H);
    wire [6:0] wlast = cur_rot ? 7'(NGRP - 1) : 7'(WPR_N - 1);
    wire [9:0] ahead = nf - cons;

    assign rreq  = cur_valid && !pend_fs && nf < dh && ahead < 10'd8;
    assign raddr = FB_BASE + {3'd0, rd_buf, nf[8:0], wc, 2'b00};

    always_ff @(posedge clk_sd) begin
        if (!resetn) begin
            cur_valid <= 1'b0;
            cur_rot   <= 1'b0;
            rd_buf    <= 2'd0;
            nf        <= 10'd0;
            wc        <= 7'd0;
            cons      <= 10'd0;
            ret_row   <= 10'd0;
            ret_c     <= 7'd0;
            pend_fs   <= 1'b0;
            settle    <= 2'd0;
            inflight  <= 1'b0;
        end else begin
            if (rdn_ev) cons <= cons + 1'b1;

            if (rack) begin
                inflight <= 1'b1;
                if (wc == wlast) begin
                    wc <= 7'd0;
                    nf <= nf + 1'b1;
                end else
                    wc <= wc + 1'b1;
            end

            if (rvalid) begin
                inflight <= 1'b0;
                if (ret_c == wlast) begin
                    ret_c   <= 7'd0;
                    ret_row <= ret_row + 1'b1;
                end else
                    ret_c <= ret_c + 1'b1;
            end

            // New frame: stop requesting, wait until a request taken on the last cycle has
            // shown up as rack and its data has come back, then switch buffers.
            if (fs_ev) begin
                pend_fs <= 1'b1;
                settle  <= 2'd0;
            end else if (pend_fs) begin
                if (settle != 2'd3)
                    settle <= settle + 1'b1;
                else if (!inflight && !rack) begin
                    pend_fs   <= 1'b0;
                    rd_buf    <= latest_buf;
                    cur_rot   <= latest_rot;
                    cur_valid <= have_frame;
                    nf        <= 10'd0;
                    wc        <= 7'd0;
                    cons      <= 10'd0;
                    ret_row   <= 10'd0;
                    ret_c     <= 7'd0;
                end
            end
        end
    end

    // line RAM: 8 rows x 128 words (two block RAMs)
    (* syn_ramstyle = "block_ram" *)
    logic [31:0] lb [0:1023];

    always_ff @(posedge clk_sd)
        if (rvalid) lb[{ret_row[2:0], ret_c}] <= rdata;

    // ================================================================= scan-out (clk_pix)
    logic rot_meta = 1'b0, rot_s = 1'b0, val_meta = 1'b0, val_s = 1'b0;
    always_ff @(posedge clk_pix) begin
        {rot_s, rot_meta} <= {rot_meta, cur_rot};
        {val_s, val_meta} <= {val_meta, cur_valid};
    end

    // layout of the frame on screen
    logic f_rot = 1'b0, f_val = 1'b0;
    wire [10:0] gx0   = f_rot ? 11'(X0_R) : 11'(X0_N);
    wire [10:0] gxe   = f_rot ? 11'(X0_R + PW_R) : 11'(X0_N + PW_N);
    wire [9:0]  gy0   = f_rot ? 10'(Y0_R) : 10'(Y0_N);
    wire [8:0]  gylst = f_rot ? 9'(SRC_W - 1) : 9'(SRC_H - 1);
    localparam [1:0] GXLST = 2'd2;                  // 3x across

    logic [10:0] pcnt = 11'd0;      // pixel position that will be on screen 3 clocks from now
    // overlay grid
    logic [2:0]  xsub = 3'd0;
    logic [7:0]  xx   = 8'd0;
    logic [7:0]  yy   = 8'd0;
    logic [1:0]  ysub = 2'd0;
    logic        vact = 1'b0;
    // picture grid
    logic [8:0]  gx    = 9'd0;
    logic [1:0]  gxs   = 2'd0;
    logic [8:0]  gy    = 9'd0;
    logic [1:0]  gys   = 2'd0;
    logic        gvact = 1'b0;
    // last line of the current row: rotated, even rows 2 lines and odd rows 3; else 3 lines
    wire  [1:0]  gyslst = (f_rot && !gy[0]) ? 2'd1 : 2'd2;

    wire  [9:0]  cyn = (cy == frame_height - 1'b1) ? 10'd0 : cy + 1'b1;

    always_ff @(posedge clk_pix) begin
        if (cx == frame_width - 4) begin
            pcnt <= 11'd0;
            xsub <= 3'd0;
            xx   <= 8'd255;
            gx   <= 9'd0;
            gxs  <= 2'd0;

            // vertical state for the line that starts 3 clocks from now
            if (cyn == OVL_VSTART) begin
                vact <= 1'b1;
                yy   <= 8'd0;
                ysub <= 2'd0;
            end else if (vact) begin
                if (ysub == 2'd2) begin
                    if (yy == OVL_H - 1) vact <= 1'b0;
                    else begin
                        yy   <= yy + 1'b1;
                        ysub <= 2'd0;
                    end
                end else
                    ysub <= ysub + 1'b1;
            end

            if (cyn == 10'(FS_LINE))
                fs_tgl <= ~fs_tgl;
            if (cyn == frame_height - 1'b1) begin
                f_rot <= rot_s;
                f_val <= val_s;
            end

            if (cyn == gy0 && f_val) begin
                gvact <= 1'b1;
                gy    <= 9'd0;
                gys   <= 2'd0;
            end else if (gvact) begin
                if (gys == gyslst) begin
                    rdn_tgl <= ~rdn_tgl;
                    if (gy == gylst) gvact <= 1'b0;
                    else begin
                        gy  <= gy + 1'b1;
                        gys <= 2'd0;
                    end
                end else
                    gys <= gys + 1'b1;
            end
        end else begin
            pcnt <= pcnt + 1'b1;
            // xx = (pcnt - OVL_X0) / 3 from the window's left edge on
            if (pcnt == 11'(OVL_X0 - 1)) begin
                xsub <= 3'd0;
                xx   <= 8'd0;
            end else if (pcnt >= 11'(OVL_X0)) begin
                if (xsub == 3'd2) begin
                    xsub <= 3'd0;
                    xx   <= xx + 1'b1;
                end else
                    xsub <= xsub + 1'b1;
            end
            if (pcnt >= gx0) begin
                if (gxs == GXLST) begin
                    gxs <= 2'd0;
                    gx  <= gx + 1'b1;
                end else
                    gxs <= gxs + 1'b1;
            end
        end
    end

    assign overlay_x = xx;
    assign overlay_y = yy;

    // line RAM read (registered), game pixel register, menu mix register
    wire         gact = gvact && pcnt >= gx0 && pcnt < gxe;
    logic [31:0] lq    = 32'd0;
    logic        gact0 = 1'b0;
    logic [1:0]  bsel0 = 2'd0;
    logic        oact0 = 1'b0, oact1 = 1'b0;
    logic [7:0]  x0, y0, x1, y1;
    logic [23:0] game = 24'h000000;
    wire  [7:0]  p    = lq[8*bsel0 +: 8];

    always_ff @(posedge clk_pix) begin
        lq    <= lb[{gy[2:0], gx[8:2]}];
        gact0 <= gact;
        bsel0 <= gx[1:0];
        oact0 <= vact && pcnt >= 11'(OVL_X0) && pcnt < 11'(OVL_X0 + 768);
        x0    <= xx;
        y0    <= yy;
        oact1 <= oact0;
        x1    <= x0;
        y1    <= y0;
        if (gact0)      // RGB 3:3:2 to 8:8:8, top bits repeated
            game <= {p[7:5], p[7:5], p[7:6],
                     p[4:2], p[4:2], p[4:3],
                     p[1:0], p[1:0], p[1:0], p[1:0]};
        else
            game <= 24'h000000;
    end

    // overlay and osd_strip into clk_pix (the first flop of each is *_meta)
    logic ovl_meta = 1'b0, ovl_s = 1'b0, strip_meta = 1'b0, strip_s = 1'b0;
    always_ff @(posedge clk_pix) begin
        {ovl_s, ovl_meta}     <= {ovl_meta, overlay};
        {strip_s, strip_meta} <= {strip_meta, osd_strip};
    end

    wire strip_win = x1 >= 8'd64 && x1 < 8'd192 && y1 >= 8'd184 && y1 < 8'd200;
    wire band_win  = x1 >= 8'd62 && x1 < 8'd194 && y1 >= 8'd182 && y1 < 8'd202;
    wire lit       = overlay_color != 15'd0;

    // BGR5 to RGB888, low bits repeated so that 31 becomes 255
    wire [23:0] menu_rgb = {overlay_color[4:0],   overlay_color[4:2],
                            overlay_color[9:5],   overlay_color[9:7],
                            overlay_color[14:10], overlay_color[14:12]};

    always_ff @(posedge clk_pix) begin
        if (ovl_s && !strip_s)
            rgb <= oact1 && lit ? menu_rgb
                 : {2'b0, game[23:18], 2'b0, game[15:10], 2'b0, game[7:2]};
        else if (ovl_s && oact1 && band_win)
            rgb <= strip_win && lit ? 24'hFFFFFF
                 : {3'b000, game[23:19], 3'b010, game[15:11], 3'b000, game[7:3]};
        else
            rgb <= game;
    end

endmodule
