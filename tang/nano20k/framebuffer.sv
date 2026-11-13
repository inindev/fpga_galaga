// framebuffer.sv - SDRAM frame buffer with rotation for the Galaga port on the Tang Nano 20K.
//
//   core pixels (clk_core 48 MHz) --> fb_writer --+                +--> sdram.v --> SDRAM pins
//                                                 +--> arbiter ----+
//   HDMI rgb (clk_pix 74.25 MHz) <-- fb_reader <--+    (clk_sd 32 MHz)
//
// fb_writer stages 4 core lines at a time and writes them, rotated or not, into one of three
// frame buffers in display order; fb_reader shows the latest finished buffer for a whole HDMI
// frame, scaled and centred on 1280x720, with the menu overlay. See those files.
//
// Arbiter (clk_sd): sdram.v takes one access at a time (a 1-clock rd/wr pulse while busy is
// low). The arbiter registers the pulse, so after a pulse it waits one clock for busy to rise;
// a new access can start every 7 clocks. When both the writer and the reader are waiting it
// alternates between them. All accesses are 32-bit words. Read data goes to the reader (the
// writer does not read).
//
// Stored area (SRC_W x SRC_H from pixel X0 of each active line): 288 x 224 from X0 = 0, the
// core's whole active picture (video_blankn high), which is MAME's visible area for Galaga
// (set_raw(MASTER_CLOCK/3, 384, 0, 288, 264, 0, 224)). In the core's 384 x 264 raster, counted
// from hcnt 192, vcnt 0 (gen_video.vhd), blankn is high for pixels 57..344 of lines 16..239.
// One buffer holds 288 x 224 bytes (64,512); in SDRAM each display row takes 512 bytes
// (fb_writer.sv), so the three buffers lie at FB_BASE + 0, 256 KB and 512 KB.
//
// The SDRAM clock pin is not driven here: the top level drives it with ~clk_sd through an ODDR,
// as in the System SJ port.

module framebuffer #(
    parameter integer SRC_W   = 288,
    parameter integer SRC_H   = 224,
    parameter integer X0      = 0,          // see above
    parameter integer Y0      = 0,
    parameter [22:0]  FB_BASE = 23'h000000
) (
    // core side (clk_core)
    input  logic        clk_core,
    input  logic        pix_en,
    input  logic [7:0]  pix,            // {r[2:0], g[2:0], b[1:0]}
    input  logic        blankn,         // 1 in the active picture
    input  logic        vs,             // vertical sync, active low
    input  logic        rotate,         // any clock (core_config[16])

    // SDRAM side (clk_sd)
    input  logic        clk_sd,
    input  logic        resetn,         // clk_sd domain, also resets the SDRAM controller

    // HDMI side (clk_pix)
    input  logic        clk_pix,
    input  logic [10:0] cx,
    input  logic [9:0]  cy,
    input  logic [10:0] frame_width,
    input  logic [9:0]  frame_height,
    output logic [23:0] rgb,

    // menu overlay (iosys_bl616)
    input  logic        overlay,
    input  logic        osd_strip,
    output logic [7:0]  overlay_x,
    output logic [7:0]  overlay_y,
    input  logic [14:0] overlay_color,

    // debug (clk_sd): a group was not written in time (sticky)
    output logic        overrun,

    // SDRAM pins
    inout  wire  [31:0] sdram_dq,
    output logic [10:0] sdram_a,
    output logic [1:0]  sdram_ba,
    output logic [3:0]  sdram_dqm,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic        sdram_cke
);

    logic        wreq, wack, rreq, rack;
    logic [22:0] waddr, raddr;
    logic [31:0] wdata;
    logic [1:0]  latest_buf, rd_buf;
    logic        latest_rot, have_frame;

    logic        sd_rd, sd_wr, sd_busy, sd_ready;
    logic [22:0] sd_addr;
    logic [31:0] sd_din, sd_dout;

    fb_writer #(
        .SRC_W(SRC_W), .SRC_H(SRC_H), .X0(X0), .Y0(Y0), .FB_BASE(FB_BASE)
    ) u_writer (
        .clk_core      (clk_core),
        .pix_en        (pix_en),
        .pix           (pix),
        .blankn        (blankn),
        .vs            (vs),
        .rotate        (rotate),
        .clk_sd        (clk_sd),
        .resetn        (resetn),
        .wreq          (wreq),
        .waddr         (waddr),
        .wdata         (wdata),
        .wack          (wack),
        .rd_buf        (rd_buf),
        .latest_buf    (latest_buf),
        .latest_rot    (latest_rot),
        .have_frame    (have_frame),
        .overrun       (overrun)
    );

    fb_reader #(
        .SRC_W(SRC_W), .SRC_H(SRC_H), .FB_BASE(FB_BASE)
    ) u_reader (
        .clk_sd       (clk_sd),
        .resetn       (resetn),
        .rreq         (rreq),
        .raddr        (raddr),
        .rack         (rack),
        .rdata        (sd_dout),
        .rvalid       (sd_ready),
        .latest_buf   (latest_buf),
        .latest_rot   (latest_rot),
        .have_frame   (have_frame),
        .rd_buf       (rd_buf),
        .clk_pix      (clk_pix),
        .cx           (cx),
        .cy           (cy),
        .frame_width  (frame_width),
        .frame_height (frame_height),
        .rgb          (rgb),
        .overlay      (overlay),
        .osd_strip    (osd_strip),
        .overlay_x    (overlay_x),
        .overlay_y    (overlay_y),
        .overlay_color(overlay_color)
    );

    // ------------------------------------------------------------------ arbiter
    logic prio_r = 1'b0;            // 1: the reader goes first when both wait

    always_ff @(posedge clk_sd) begin
        sd_rd <= 1'b0;
        sd_wr <= 1'b0;
        rack  <= 1'b0;
        wack  <= 1'b0;
        if (resetn && !sd_busy && !sd_rd && !sd_wr) begin
            if (rreq && (!wreq || prio_r)) begin
                sd_rd   <= 1'b1;
                sd_addr <= raddr;
                rack    <= 1'b1;
                prio_r  <= 1'b0;
            end else if (wreq) begin
                sd_wr   <= 1'b1;
                sd_addr <= waddr;
                sd_din  <= wdata;
                wack    <= 1'b1;
                prio_r  <= 1'b1;
            end
        end
    end

    sdram u_sdram (
        .clk        (clk_sd),
        .resetn     (resetn),
        .rd         (sd_rd),
        .wr         (sd_wr),
        .word       (1'b1),
        .addr       (sd_addr),
        .din        (sd_din),
        .dout       (sd_dout),
        .busy       (sd_busy),
        .data_ready (sd_ready),
        .sdram_dq   (sdram_dq),
        .sdram_a    (sdram_a),
        .sdram_ba   (sdram_ba),
        .sdram_dqm  (sdram_dqm),
        .sdram_cs_n (sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n (sdram_we_n),
        .sdram_cke  (sdram_cke)
    );

endmodule
