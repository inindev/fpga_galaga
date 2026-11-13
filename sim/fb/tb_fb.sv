// tb_fb.sv - V2: frame buffer, rotation and HDMI scan-out (framebuffer.sv with sdram.v,
// fb_writer.sv, fb_reader.sv) against an SDRAM model.
//
// Clocks as on the board: 48 MHz core, 32 MHz SDRAM (exactly 3:2), 74.25 MHz HDMI.
//
// Source: the core's video timing (galaga.vhd, gen_video.vhd): ce18 on 48 of every 125 clocks
// of 48 MHz (18.432 MHz), a pixel enable on every third ce18 (6.144 MHz), 384 x 264 pixel
// enables per frame (60.61 Hz). Counted from the frame start (hcnt 192, vcnt 0), blankn is high
// for pixels 57..344 of lines 16..239 and vs is low on lines 260..263 and 0..2. Pixels come
// either from a synthetic 288x224 image (+img=<hex file>), shown in columns X0..X0+SRC_W-1 of
// each active line (parameter X0, default 0) with a filler colour (0xE3) around it, or from
// the pixel stream recorded in V1 (+stream=<stream.bin>: 2 bytes per pixel enable from the
// first pixel of a frame, byte 0 = {r[2:0], g[2:0], b[1:0]}, byte 1 bit 0 = blankn, bit 2 =
// vs; see sim/core/frames.py; replayed in a loop, from frame +skip=<n>).
// In key mode every source frame is XORed with its own byte, so that each frame differs in
// every pixel from the frames before and after it.
//
// Capture as in top.sv: the frame buffer gets pix_en one clock_48 cycle after the core's
// pixel enable (fb_pe), and the core's colour, blankn and vs at that cycle. The source drives
// these outputs (core_pix, core_blankn, core_vs) as galaga.vhd and gen_video.vhd do: the
// pixel enable is a ce18 cycle (ena_vidgen and ce18), and at its edge the colour, blankn and
// vs of the same pixel are written together; at the other ce18 edges a wrong colour (the
// pixel inverted) is written and blankn and vs stay. So a colour sampled at the wrong cycle,
// or paired with blankn and vs from before the pixel enable edge (the previous pixel's),
// shows as a wrong picture. vpix, vblankn and vvs are the pixel the source writes at the next
// pixel enable, which the recorder below uses.
//
// HDMI side: cx/cy as hdl-util's hdmi makes them for 720p (1650 x 750, picture at cx < 1280,
// cy < 720). Every HDMI frame without the menu is compared in full with the expected picture of
// each of the last source frames (and with black): it must match one of them exactly, else it
// is reported as TORN. Expected pictures (fb_reader.sv): rotated, turned clockwise, 3x across
// and rows alternately 2 and 3 lines down (672 x 720 at x 304); not rotated, 3x3 (864 x 672 at
// x 208, line 24). Frames can be written as PPM images (+out=<dir>).
//
// Scenario (HDMI frame numbers): rotate off, image; rotate on (mid-frame), image; menu and
// volume strip images; then key mode with rotate changes at random times, a source pause of
// 2.5 frames (menu pause: the pixel enables stop mid-frame) and, with the synthetic source, a
// restart of the video timing mid-frame (a frame with missing lines, which must be dropped).
//
// Monitors: drain time of each 4-line group (limit: 4 lines = 250 us), how early each display
// row is in the line RAM before it is shown (an underrun is an error), line RAM slot reuse,
// SDRAM busy share, the longest refresh gap, and the SDRAM model's protocol checks.

`timescale 1ps/1ps

module tb_fb;

    parameter  integer X0 = 0;                      // stored area: active pixels X0..X0+SRC_W-1
    localparam integer SRC_W = 288, SRC_H = 224;
    localparam integer FW = 1650, FH = 750;

    // picture layout (as fb_reader)
    localparam integer PW_R = 3 * SRC_H, PH_R = SRC_W * 5 / 2, PW_N = 3 * SRC_W, PH_N = 3 * SRC_H;
    localparam integer X0_R = (1280 - PW_R) / 2, Y0_R = (720 - PH_R) / 2;
    localparam integer X0_N = (1280 - PW_N) / 2, Y0_N = (720 - PH_N) / 2;

    // core raster (pixel enables from the frame start)
    localparam integer RW = 384, RH = 264;
    localparam integer AX0 = 57, AY0 = 16;          // first active pixel and line

    // ------------------------------------------------------------------ clocks
    logic clk48 = 1'b0, clk32 = 1'b0, clkp = 1'b0;
    always #6734 clkp = ~clkp;                      // 74.25 MHz (13468 ps)
    always #15625 clk32 = ~clk32;                   // 32 MHz
    initial begin                                   // 48 MHz, 3 periods = 62500 ps
        #2000;
        forever begin
            #10417 clk48 = 1'b1; #10416 clk48 = 1'b0;
            #10417 clk48 = 1'b1; #10417 clk48 = 1'b0;
            #10416 clk48 = 1'b1; #10417 clk48 = 1'b0;
        end
    end

    logic resetn = 1'b0;
    initial begin
        repeat (20) @(posedge clk32);
        resetn <= 1'b1;
    end

    // ------------------------------------------------------------------ DUT
    logic       pix_en = 1'b0;
    logic [7:0] vpix = 8'h00;
    logic       vblankn = 1'b0, vvs = 1'b0;
    logic       rotate = 1'b0;

    logic [10:0] cx = 11'd0;
    logic [9:0]  cy = 10'd0;
    logic [23:0] rgb;
    logic        overlay = 1'b0, osd_strip = 1'b0;
    logic [7:0]  ovl_x, ovl_y;
    logic [14:0] ovl_c = 15'd0, ovl_c_d = 15'd0;
    logic        overrun;

    wire  [31:0] sdq;
    wire  [10:0] sa;
    wire  [1:0]  sba;
    wire  [3:0]  sdqm;
    wire         scs, sras, scas, swe, scke;
    wire         sdclk = ~clk32;

    // capture front end, as in top.sv
    logic       fb_pe = 1'b0;
    logic [7:0] core_pix = 8'h00;
    logic       core_blankn = 1'b0, core_vs = 1'b0;
    always @(posedge clk48) fb_pe <= pix_en;

    framebuffer #(.SRC_W(SRC_W), .SRC_H(SRC_H), .X0(X0)) u_fb (
        .clk_core      (clk48),
        .pix_en        (fb_pe),
        .pix           (core_pix),
        .blankn        (core_blankn),
        .vs            (core_vs),
        .rotate        (rotate),
        .clk_sd        (clk32),
        .resetn        (resetn),
        .clk_pix       (clkp),
        .cx            (cx),
        .cy            (cy),
        .frame_width   (11'(FW)),
        .frame_height  (10'(FH)),
        .rgb           (rgb),
        .overlay       (overlay),
        .osd_strip     (osd_strip),
        .overlay_x     (ovl_x),
        .overlay_y     (ovl_y),
        .overlay_color (ovl_c),
        .overrun       (overrun),
        .sdram_dq      (sdq),
        .sdram_a       (sa),
        .sdram_ba      (sba),
        .sdram_dqm     (sdqm),
        .sdram_cs_n    (scs),
        .sdram_ras_n   (sras),
        .sdram_cas_n   (scas),
        .sdram_we_n    (swe),
        .sdram_cke     (scke)
    );

    sdram_model u_mem (
        .clk(sdclk), .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas), .we_n(swe),
        .ba(sba), .a(sa), .dqm(sdqm), .dq(sdq)
    );

    // textdisp stand-in: a 2-clock latency pattern on the 256x224 overlay grid
    function automatic [14:0] ovl_pattern(input [7:0] x, input [7:0] y);
        if (osd_strip)
            return (x >= 64 && x < 150 && y >= 188 && y < 196) ? 15'h7FFF : 15'd0;
        if (x == 8 || x == 247 || y == 8 || y == 215)
            return 15'b11010_11100_11100;                       // frame
        if (y[7:3] == 5'd10 && x[7:3] >= 5'd4 && x[7:3] <= 5'd27)
            return ((x[2:0] ^ y[2:0]) < 3'd2) ? 15'b11010_11100_11100 : 15'b10110_01011_00101;
        if (y[7:3] >= 5'd6 && y[7:3] <= 5'd20 && y[3] && x[7:3] >= 5'd4 && x[7:3] <= 5'd27)
            return ((x[2:0] ^ y[2:0]) < 3'd2) ? 15'b11010_11100_11100 : 15'd0;
        return 15'd0;
    endfunction
    always @(posedge clkp) begin
        ovl_c_d <= ovl_pattern(ovl_x, ovl_y);
        ovl_c   <= ovl_c_d;
    end

    // ------------------------------------------------------------------ source image / stream
    logic [7:0] img [0:SRC_W * SRC_H - 1];
    string      img_file, stream_file, out_dir;
    logic       use_stream = 1'b0;
    localparam integer FRAME_PE = RW * RH;              // pixel enables per source frame
    localparam integer ST_MAXF  = 48;                   // frames of the stream kept
    logic [7:0] st_buf [0:2 * FRAME_PE * ST_MAXF - 1];  // stream.bin: 2 bytes per pixel enable
    int         st_len = 0, st_pos = 0;                 // in pixel enables

    initial begin
        if (!$value$plusargs("out=%s", out_dir)) out_dir = ".";
        if ($value$plusargs("stream=%s", stream_file)) begin
            int fd, skip, n;
            use_stream = 1'b1;
            if (!$value$plusargs("skip=%d", skip)) skip = 0;
            fd = $fopen(stream_file, "rb");
            if (fd == 0) begin $display("ERROR: cannot open %s", stream_file); $finish; end
            void'($fseek(fd, skip * 2 * FRAME_PE, 0));
            n = $fread(st_buf, fd);
            $fclose(fd);
            st_len = (n / 2) / FRAME_PE * FRAME_PE;     // whole frames only
            if (st_len == 0) begin $display("ERROR: stream shorter than a frame"); $finish; end
            $display("stream: %0d frames from %s, from frame %0d", st_len / FRAME_PE, stream_file, skip);
        end else begin
            if (!$value$plusargs("img=%s", img_file)) img_file = "src_img.hex";
            $readmemh(img_file, img);
        end
    end

    // ------------------------------------------------------------------ source: core video timing
    logic       src_run = 1'b1;         // 0: the clock enables stop (menu pause)
    logic       src_reset = 1'b0;       // 1: restart the video timing (synthetic source only)
    logic       keymode = 1'b0;
    logic [6:0] ce_acc = 7'd0;
    logic       ce18 = 1'b0;
    logic [1:0] slot = 2'd0;
    int         hpos = 0, vpos = 0;     // position in the frame of the next pixel enable
    int         gen_f = 0;              // frames started by the source

    function automatic [7:0] key_of(input int f);
        return keymode ? 8'((f * 151 + 7) & 255) : 8'd0;
    endfunction

    // ce18 as galaga.vhd makes it (pause stops it); the pixel enable is every third ce18, on
    // the same cycle (video_ce = ena_vidgen and ce18)
    always @(posedge clk48) begin
        ce18   <= 1'b0;
        pix_en <= 1'b0;
        if (src_run) begin
            if (ce_acc >= 7'd77) begin
                ce_acc <= ce_acc - 7'd77;
                ce18   <= 1'b1;
                pix_en <= slot == 2'd2;
                slot   <= (slot == 2'd2) ? 2'd0 : slot + 1'b1;
            end else
                ce_acc <= ce_acc + 7'd48;
        end
    end

    // the core's outputs: at the pixel enable edge the colour, blankn and vs of one pixel
    // (vpix, vblankn, vvs before the edge), at the other ce18 edges a wrong colour
    always @(posedge clk48) if (ce18) begin
        if (pix_en) {core_pix, core_blankn, core_vs} <= {vpix, vblankn, vvs};
        else        core_pix <= ~vpix;
    end

    // the pixel for each pixel enable (written to the outputs at the next one)
    always @(posedge clk48) if (pix_en) begin
        int f, h, v, sx, sy;
        f = gen_f;
        if (use_stream) begin
            if (st_pos % FRAME_PE == 0) f = gen_f + 1;
            vpix    <= st_buf[2 * st_pos] ^ key_of(f);
            vblankn <= st_buf[2 * st_pos + 1][0];
            vvs     <= st_buf[2 * st_pos + 1][2];
            st_pos  <= (st_pos + 1 == st_len) ? 0 : st_pos + 1;
        end else begin
            h = src_reset ? 0 : hpos;
            v = src_reset ? 0 : vpos;
            if (h == 0 && v == 0) f = gen_f + 1;
            sx = h - AX0 - X0;
            sy = v - AY0;
            vblankn <= h >= AX0 && h < AX0 + 288 && v >= AY0 && v < AY0 + 224;
            vvs     <= !(v >= 260 || v < 3);
            if (sx >= 0 && sx < SRC_W && sy >= 0 && sy < SRC_H) vpix <= img[sy * SRC_W + sx] ^ key_of(f);
            else                                                 vpix <= 8'hE3;
            if (h == RW - 1) begin
                hpos <= 0;
                vpos <= (v == RH - 1) ? 0 : v + 1;
            end else begin
                hpos <= h + 1;
                vpos <= v;
            end
        end
        gen_f <= f;
    end

    // ------------------------------------------------------------------ recorder
    // Watches the source's pixels (vpix, vblankn and vvs at pix_en, which the writer gets one
    // clock later) and keeps the last 8 frames' stored area, with the rotate flag the writer
    // took for them.
    logic [7:0] sf [0:7][0:SRC_W * SRC_H - 1];
    int         rec_fn   [0:7];
    logic       rec_rot  [0:7];
    int         fn = 0;                 // source frames started
    int         ax = 0, ay = 0;
    logic       inl = 1'b0, in_vs = 1'b1;
    initial for (int i = 0; i < 8; i++) rec_fn[i] = -1;

    always @(posedge clk48) if (pix_en) begin
        if (!vvs) begin
            ay = 0; ax = 0; inl = 1'b0; in_vs = 1'b1;
        end else if (!vblankn) begin
            ax = 0;
            if (inl) begin ay++; inl = 1'b0; end
        end else begin
            if (in_vs) begin
                in_vs = 1'b0;
                fn++;
                rec_fn [fn % 8] = -1;                   // being written
                rec_rot[fn % 8] = u_fb.u_writer.f_rot;  // taken by the writer at the sync
            end
            inl = 1'b1;
            if (ax >= X0 && ax < X0 + SRC_W && ay < SRC_H) sf[fn % 8][ay * SRC_W + ax - X0] = vpix;
            if (ax == X0 + SRC_W - 1 && ay == SRC_H - 1) rec_fn[fn % 8] = fn;   // complete
            ax++;
        end
    end

    // ------------------------------------------------------------------ HDMI counters
    always @(posedge clkp) begin
        cx <= (cx == FW - 1) ? 11'd0 : cx + 1'b1;
        if (cx == FW - 1) cy <= (cy == FH - 1) ? 10'd0 : cy + 1'b1;
    end

    // ------------------------------------------------------------------ checker
    function automatic [23:0] rgb888(input [7:0] p);
        return {p[7:5], p[7:5], p[7:6], p[4:2], p[4:2], p[4:3], p[1:0], p[1:0], p[1:0], p[1:0]};
    endfunction

    // expected picture of source frame k (index into the record) at screen (x, y)
    function automatic [23:0] expect_px(input int k, input int x, input int y);
        int sx, sy, dx, dy, yy;
        if (rec_rot[k]) begin
            if (x < X0_R || x >= X0_R + PW_R || y < Y0_R || y >= Y0_R + PH_R) return 24'h0;
            dx = (x - X0_R) / 3;
            yy = y - Y0_R;                              // rows of 2 and 3 lines, even rows first
            dy = (yy / 5) * 2 + ((yy % 5) >= 2 ? 1 : 0);
            sx = dy;                                    // clockwise
            sy = SRC_H - 1 - dx;
        end else begin
            if (x < X0_N || x >= X0_N + PW_N || y < Y0_N || y >= Y0_N + PH_N) return 24'h0;
            sx = (x - X0_N) / 3;
            sy = (y - Y0_N) / 3;
        end
        return rgb888(sf[k][sy * SRC_W + sx]);
    endfunction

    int    hf = 0;                      // HDMI frames
    logic  c_ok [0:8];                  // 0-7: source records, 8: black
    int    c_fn [0:8];
    logic  menu_seen = 1'b0;
    int    torn = 0, checked = 0, shown_last = -1, repeats = 0, skipped_src = 0;
    int    fn_at_start = 0;
    string dump_name = "";
    int    dump_fd = 0;
    int    lag_hist [0:4];
    int    shown_rot = 0, shown_norot = 0;
    initial for (int i = 0; i < 5; i++) lag_hist[i] = 0;

    always @(posedge clkp) begin
        if (cx == 0 && cy == 0) begin
            for (int k = 0; k < 8; k++) begin
                c_fn[k] = rec_fn[k];
                c_ok[k] = rec_fn[k] >= 0;
            end
            c_ok[8]     = 1'b1;
            c_fn[8]     = -1;
            menu_seen   = overlay;
            fn_at_start = fn;
            if (dump_name != "") begin
                dump_fd = $fopen({out_dir, "/", dump_name}, "wb");
                $fwrite(dump_fd, "P6\n1280 720\n255\n");
            end
        end
        if (cx < 1280 && cy < 720) begin
            if (overlay) menu_seen = 1'b1;
            for (int k = 0; k < 8; k++)
                if (c_ok[k] && rgb != expect_px(k, cx, cy)) c_ok[k] = 1'b0;
            if (c_ok[8] && rgb != 24'h0) c_ok[8] = 1'b0;
            if (dump_fd != 0) $fwrite(dump_fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
        end
        if (cx == 1279 && cy == 719) begin
            int m, best;
            if (dump_fd != 0) begin
                $fclose(dump_fd);
                $display("  image %s", dump_name);
                dump_fd   = 0;
                dump_name = "";
            end
            m = 0; best = -2;
            for (int k = 0; k < 9; k++) if (c_ok[k]) begin
                m++;
                if (c_fn[k] > best) best = c_fn[k];
            end
            if (menu_seen) begin
                shown_last = -1;
                $display("HDMI %0d: menu shown, not compared", hf);
            end else if (m == 0) begin
                torn++;
                $display("HDMI %0d: TORN or wrong (no source frame matches)", hf);
            end else begin
                int lag;
                checked++;
                lag = fn_at_start - best;
                if (best >= 0) begin
                    automatic int k = best % 8;
                    if (best == shown_last) repeats++;
                    else if (shown_last >= 0 && best > shown_last + 1) skipped_src += best - shown_last - 1;
                    shown_last = best;
                    if (lag >= 0 && lag <= 4) lag_hist[lag]++;
                    if (rec_rot[k]) shown_rot++; else shown_norot++;
                    $display("HDMI %0d: source frame %0d (rot %0d), %0d frame(s) behind the one being captured",
                             hf, best, rec_rot[k], lag);
                end else
                    $display("HDMI %0d: black (no frame yet)", hf);
            end
            hf++;
        end
    end

    // ------------------------------------------------------------------ monitors
    // drain time of each group
    longint drain_t0 = 0, drain_max = 0;
    logic   draining = 1'b0;
    always @(posedge clk32) begin
        if (u_fb.u_writer.grp_ev) begin
            drain_t0 = longint'($time);
            draining = 1'b1;
        end else if (draining && u_fb.u_writer.dst == 2'd0) begin
            draining = 1'b0;
            if (longint'($time) - drain_t0 > drain_max) drain_max = longint'($time) - drain_t0;
        end
    end

    // display rows: time the last word is in the line RAM, and when the row is first shown
    longint row_ready [0:511];
    longint row_margin_min = 64'h7fff_ffff_ffff;
    int     underruns = 0, slot_errors = 0;
    initial for (int i = 0; i < 512; i++) row_ready[i] = -1;
    logic pend_fs_d = 1'b0;
    always @(posedge clk32) begin
        if (pend_fs_d && !u_fb.u_reader.pend_fs)
            for (int i = 0; i < 512; i++) row_ready[i] = -1;        // new frame taken
        pend_fs_d = u_fb.u_reader.pend_fs;
        if (u_fb.u_reader.rvalid) begin
            automatic int r = int'(u_fb.u_reader.ret_row);
            if (u_fb.u_reader.ret_c == u_fb.u_reader.wlast && r < 512)
                row_ready[r] = longint'($time);
            if (u_fb.u_reader.ret_c == 7'd0 && r >= 8 && int'(u_fb.u_reader.cons) < r - 7) begin
                slot_errors++;
                $display("ERROR: row %0d written into the line RAM before row %0d was done", r, r - 8);
            end
        end
    end
    logic [8:0] prev_gy = 9'd0;
    logic       prev_gv = 1'b0;
    always @(posedge clkp) begin
        if (u_fb.u_reader.gvact && (!prev_gv || u_fb.u_reader.gy != prev_gy)) begin
            automatic int r = int'(u_fb.u_reader.gy);
            if (row_ready[r] < 0) begin
                underruns++;
                if (underruns <= 10) $display("ERROR: display row %0d shown before it was read (HDMI frame %0d)", r, hf);
            end else if (longint'($time) - row_ready[r] < row_margin_min)
                row_margin_min = longint'($time) - row_ready[r];
        end
        prev_gy = u_fb.u_reader.gy;
        prev_gv = u_fb.u_reader.gvact;
    end

    // SDRAM busy share and request waits
    longint cyc32 = 0, busy32 = 0, both_wait = 0;
    longint wwait = 0, wwait_max = 0, rwait = 0, rwait_max = 0;
    always @(posedge clk32) if (resetn && u_fb.u_sdram.init_done) begin
        cyc32++;
        if (u_fb.u_sdram.busy) busy32++;
        if (u_fb.wreq && u_fb.rreq) both_wait++;
        if (u_fb.wreq && !u_fb.wack) begin wwait++; if (wwait > wwait_max) wwait_max = wwait; end
        else wwait = 0;
        if (u_fb.rreq && !u_fb.rack) begin rwait++; if (rwait > rwait_max) rwait_max = rwait; end
        else rwait = 0;
    end

    // DQ contention: the controller and the SDRAM must never drive DQ together
    int contention = 0;
    always @(posedge clk32 or negedge clk32)
        if (!u_fb.u_sdram.dq_oen && u_mem.dq_oe) contention++;

    // ------------------------------------------------------------------ scenario
    task automatic wait_frames(input int n);
        repeat (n) do @(posedge clkp); while (!(cx == 0 && cy == 0));
    endtask
    task automatic wait_line(input int l);
        do @(posedge clkp); while (!(cx == 0 && cy == 10'(l)));
    endtask
    // write the next HDMI frame as an image; returns after its last picture line
    task automatic dump(input string name);
        do @(posedge clkp); while (!(cx == 100 && cy == 740));
        dump_name = name;
        wait_frames(1);
        wait_line(725);
    endtask

    // menu pause (the clock enables stop for 2.5 frames, mid-frame) and, with the synthetic
    // source, a restart of the video timing mid-frame
    initial begin
        do @(posedge clkp); while (hf < 45);
        do @(posedge clk48); while (!(pix_en && u_fb.u_writer.ly == 10'd60));
        src_run <= 1'b0;
        $display("-- source paused (line 60)");
        #(64'd41_700_000_000);
        src_run <= 1'b1;
        $display("-- source resumed");
        if (!use_stream) begin
            do @(posedge clkp); while (hf < 60);
            do @(posedge clk48); while (!(pix_en && vpos == 120));
            src_reset <= 1'b1;
            do @(posedge clk48); while (!pix_en);
            do @(posedge clk48); while (!pix_en);
            src_reset <= 1'b0;
            $display("-- video timing restarted (line 120)");
        end
    end

    int nframes = 80;
    initial begin
        int seed;
        if (!$value$plusargs("frames=%d", nframes)) nframes = 80;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));

        // 1. not rotated
        wait_frames(4);
        dump("v2_norot.ppm");
        // 2. rotate on, in the middle of an HDMI frame
        wait_line(333);
        rotate <= 1'b1;
        $display("-- rotate on");
        wait_frames(3);
        dump("v2_rot_cw.ppm");
        // 3. menu over the rotated picture, then the volume strip
        overlay <= 1'b1;
        $display("-- menu on");
        wait_frames(2);
        dump("v2_menu_rot.ppm");
        osd_strip <= 1'b1;
        $display("-- volume strip");
        wait_frames(2);
        dump("v2_strip_rot.ppm");
        rotate    <= 1'b0;
        osd_strip <= 1'b0;
        $display("-- rotate off, menu");
        wait_frames(3);
        dump("v2_menu_norot.ppm");
        overlay <= 1'b0;
        $display("-- menu off");

        // 4. key mode: every source frame differs; rotate changes at random times (in
        // parallel: a source pause at HDMI frame 45, a timing restart at 60)
        wait_frames(1);
        keymode <= 1'b1;
        $display("-- key mode");
        while (hf < nframes) begin
            automatic int     what = $urandom_range(0, 9);
            automatic longint dly  = longint'($urandom_range(1, 2000)) * 64'd10_000_000; // 10 us..20 ms
            #(dly);
            if (what < 4) begin
                rotate <= ~rotate;
                $display("-- rotate %0d", ~rotate);
            end
        end

        $display("");
        $display("==== V2 summary ====");
        $display("HDMI frames %0d, compared %0d (rotated %0d, not rotated %0d), TORN/wrong %0d",
                 hf, checked, shown_rot, shown_norot, torn);
        $display("source frames started %0d; HDMI frames repeating the previous source frame %0d; source frames never shown %0d",
                 fn, repeats, skipped_src);
        $display("frames behind the one being captured: 0:%0d 1:%0d 2:%0d 3:%0d 4:%0d",
                 lag_hist[0], lag_hist[1], lag_hist[2], lag_hist[3], lag_hist[4]);
        $display("overrun %0d, underruns %0d, line RAM slot errors %0d, DQ contention %0d, SDRAM model errors %0d",
                 overrun, underruns, slot_errors, contention, u_mem.errors);
        $display("longest group drain %0.1f us (limit 250 us = 4 source lines)", real'(drain_max) / 1e6);
        $display("smallest lead of a display row in the line RAM before it is shown %0.1f us",
                 real'(row_margin_min) / 1e6);
        $display("SDRAM busy %0.1f%% of 32 MHz clocks; both clients waiting %0.2f%%; longest wait for the bus: writer %0d, reader %0d clocks",
                 100.0 * real'(busy32) / real'(cyc32), 100.0 * real'(both_wait) / real'(cyc32), wwait_max, rwait_max);
        $display("SDRAM commands: ACT %0d, READ %0d, WRITE %0d, REFRESH %0d; longest refresh gap %0.2f us",
                 u_mem.n_act, u_mem.n_rd, u_mem.n_wr, u_mem.n_ref, real'(u_mem.max_ref_gap) / 1e6);
        if (torn == 0 && !overrun && underruns == 0 && slot_errors == 0 && contention == 0 && u_mem.errors == 0)
            $display("V2 PASS");
        else
            $display("V2 FAIL");
        $finish;
    end

endmodule
