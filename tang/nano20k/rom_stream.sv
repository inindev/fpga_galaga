// rom_stream.sv - ROM image loader for the Galaga Tang Nano 20K port (TangCore).
//
// The TangCore BL616 firmware reads the game's ROM zip from the USB drive, builds the image a
// MiSTer MRA builds and sends it over the UART. iosys_bl616 hands it over byte by byte:
// rom_loading goes 0 -> 1, then every image byte comes as rom_do with a one-clock rom_do_valid
// (offset 0 first), then rom_loading goes 1 -> 0. iosys passes every byte of the stream
// unchanged (no header is stripped).
//
// The whole image lives in the core's block RAM: byte n < 0x9820 is written into the core
// through its download port (dn_addr = n, see galaga.vhd), bytes from 0x9820 on are ignored.
// Image layout (as the MRA builds it):
//
//   0x0000 + 0x4000  CPU 1 program
//   0x4000 + 0x1000  CPU 2 program
//   0x5000 + 0x1000  CPU 3 program
//   0x6000 + 0x2000  sprite graphics
//   0x8000 + 0x1000  tile graphics
//   0x9000 + 0x0400  54XX program
//   0x9400 + 0x0100  tile colour lookup PROM
//   0x9500 + 0x0100  sprite colour lookup PROM
//   0x9600 + 0x0100  sound waveform PROM
//   0x9700 + 0x0100  sound sequencer PROM
//   0x9800 + 0x0020  palette PROM
//
// The core is held in reset (top.sv) from power-up until `loaded`, and again from the start
// of every load.
//
// Clock crossing (clk 32 MHz -> clk_core 48 MHz). Each byte goes over with a toggle
// handshake: in clk, the byte and its address are put in xfer_addr/xfer_data and xfer_req
// toggles in the same clock; nothing changes them until the handshake is back. In clk_core,
// xfer_req goes through a 2-flop synchroniser (req_meta, req_s); when it has changed, the
// address and data (stable for at least two clk_core cycles by then) are taken, dn_wr is
// high for one clk_core cycle (the core writes the byte at the end of it) and xfer_ack
// (= the request taken) goes back through ack_meta, ack_s into clk. The next byte is sent only once ack_s equals xfer_req. A round
// trip is under 10 clk cycles; at 2 Mbaud a byte arrives at most every 5 us (160 clk
// cycles), so one byte of buffer (rx) is enough. The core's memories are written on
// clk_core only (galaga.vhd's dpram blocks), so the download port has no clock crossing of
// its own.
//
// `loaded` is 1 once a load has ended (rom_loading 1 -> 0) with at least MIN_SIZE bytes and
// every byte written into the core; it drops when the next load starts. `short_load` is 1
// when the last load ended with fewer bytes (the core then stays in reset).

module rom_stream #(
    parameter [17:0]   MIN_SIZE = 18'h09820     // the whole image
) (
    input  logic        clk,            // clkm_32MHZ, the iosys_bl616 clock
    input  logic        resetn,         // system reset (clk), released once after power-up

    // from iosys_bl616 (clk)
    input  logic        loading,        // rom_loading != 0
    input  logic [7:0]  rom_do,
    input  logic        rom_do_valid,

    output logic        loaded,         // clk
    output logic        short_load,     // clk

    // core download port (clk_core)
    input  logic        clk_core,       // clkm_48MHZ, the core clock
    output logic [15:0] dn_addr,
    output logic [7:0]  dn_data,
    output logic        dn_wr
);

    localparam [17:0] IMAGE_END = 18'h09820;      // from here: ignored

    // ================================================================= clk (32 MHz)
    logic        loading_r;
    logic [17:0] n;                 // index of the next byte to arrive (saturates)
    logic [15:0] idx;               // address of the byte in rx
    logic [7:0]  rx;
    logic        full;              // rx holds a byte not yet sent

    logic        xfer_req = 1'b0;   // toggles once per byte sent
    logic [15:0] xfer_addr = '0;
    logic [7:0]  xfer_data = '0;
    logic        xfer_ack;          // clk_core: the last request taken
    logic        ack_meta = 1'b0, ack_s = 1'b0;

    always_ff @(posedge clk) {ack_s, ack_meta} <= {ack_meta, xfer_ack};

    wire idle = ack_s == xfer_req;  // no byte in flight

    always_ff @(posedge clk) begin
        loading_r <= loading;

        if (!resetn) begin
            loading_r  <= 1'b0;
            n          <= '0;
            full       <= 1'b0;
            loaded     <= 1'b0;
            short_load <= 1'b0;
        end else begin
            // end of a load, once the last byte is in the core
            if (!loading && loading_r)
                short_load <= n < MIN_SIZE;
            if (!loading && !loading_r && !full && idle && n != 0 && !short_load)
                loaded <= 1'b1;

            // send the byte in rx
            if (full && idle) begin
                xfer_addr <= idx;
                xfer_data <= rx;
                xfer_req  <= ~xfer_req;
                full      <= 1'b0;
            end

            // After the above, so that a byte arriving as the previous one is sent is kept.
            // Start of a load: restart at image offset 0, the core goes back into reset.
            if (loading && !loading_r) begin
                n      <= '0;
                full   <= 1'b0;
                loaded <= 1'b0;
            end else if (rom_do_valid && loading) begin
                if (n < IMAGE_END) begin
                    rx   <= rom_do;
                    idx  <= n[15:0];
                    full <= 1'b1;
                end
                if (n != 18'h3FFFF) n <= n + 1'b1;
            end
        end
    end

    // ================================================================= clk_core (48 MHz)
    logic req_meta = 1'b0, req_s = 1'b0, req_d = 1'b0;
    always_ff @(posedge clk_core) {req_d, req_s, req_meta} <= {req_s, req_meta, xfer_req};

    logic [15:0] wr_addr = '0;
    logic [7:0]  wr_data = '0;
    logic        wr      = 1'b0;
    always_ff @(posedge clk_core) begin
        wr <= 1'b0;
        if (req_s != req_d) begin
            wr_addr <= xfer_addr;
            wr_data <= xfer_data;
            wr      <= 1'b1;
        end
    end

    assign dn_addr  = wr_addr;
    assign dn_data  = wr_data;
    assign dn_wr    = wr;
    assign xfer_ack = req_d;        // req_d changes in the clock the byte is taken

endmodule
