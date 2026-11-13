// sdram_model.sv - behavioural model of the Tang Nano 20K's embedded SDR SDRAM (8 MB,
// 32-bit, 4 banks x 2048 rows x 256 columns) for the frame buffer simulation (V2).
//
// Commands are taken on the rising edge of the SDRAM clock (the top level drives it with the
// inverted 32 MHz clock). Read data follows the timing that sdram.v is written for (see its
// header): for a READ taken at T0, DQ is driven from T0 + 2 clocks + T_AC until
// T0 + 3 clocks + T_OH, then released. Writes use DQM per byte lane.
//
// Checks (each prints "SDRAM ERROR"): ACTIVE on a bank that has a row open, READ/WRITE on a bank
// without an open row, ACTIVE to ACTIVE on a bank closer than T_RC_MIN, REFRESH or MRS with a
// row open, a mode register other than CL 2 / burst 1, CKE low. It also records the longest
// gap between two REFRESH commands after initialisation and counts commands.

`timescale 1ps/1ps

module sdram_model #(
    parameter integer TCK      = 31250,     // ps
    parameter integer T_AC     = 5000,
    parameter integer T_OH     = 2500,
    parameter integer T_RC_MIN = 63000
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [10:0] a,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);

    logic [31:0] mem [0:(1 << 21) - 1];
    logic [10:0] open_row [0:3];
    logic        row_open [0:3];
    longint      last_act [0:3];

    logic [31:0] dq_drv = 32'h0;
    logic        dq_oe  = 1'b0;
    assign dq = dq_oe ? dq_drv : 32'hzzzz_zzzz;

    logic        mode_set = 1'b0;
    longint      last_ref = -1;
    longint      max_ref_gap = 0;
    longint      n_act = 0, n_rd = 0, n_wr = 0, n_ref = 0;
    int          errors = 0;

    initial begin
        for (int i = 0; i < 4; i++) begin
            row_open[i] = 1'b0;
            last_act[i] = -1000000;
        end
        for (int i = 0; i < (1 << 21); i++) mem[i] = 32'hDEAD_BEEF;
    end

    task automatic err(input string s);
        errors++;
        if (errors <= 20) $display("SDRAM ERROR at %0t ps: %s", $time, s);
    endtask

    always @(posedge clk) begin
        automatic longint now = longint'($time);
        if (!cke) err("CKE low");
        if (!cs_n) begin
            case ({ras_n, cas_n, we_n})
                3'b011: begin                                   // ACTIVE
                    if (row_open[ba]) err($sformatf("ACTIVE on bank %0d with a row open", ba));
                    if (now - last_act[ba] < T_RC_MIN)
                        err($sformatf("tRC on bank %0d: %0d ps", ba, now - last_act[ba]));
                    open_row[ba] = a;
                    row_open[ba] = 1'b1;
                    last_act[ba] = now;
                    n_act++;
                end
                3'b101: begin                                   // READ
                    automatic logic [20:0] ad;
                    automatic logic [31:0] d;
                    if (!row_open[ba]) err("READ without an open row");
                    ad = {ba, open_row[ba], a[7:0]};
                    d  = mem[ad];
                    if (a[10]) row_open[ba] = 1'b0;
                    n_rd++;
                    fork begin
                        #(2 * TCK + T_AC);
                        dq_drv = d;
                        dq_oe  = 1'b1;
                        #(TCK - T_AC + T_OH);
                        dq_oe  = 1'b0;
                    end join_none
                end
                3'b100: begin                                   // WRITE
                    logic [20:0] ad;
                    if (!row_open[ba]) err("WRITE without an open row");
                    ad = {ba, open_row[ba], a[7:0]};
                    for (int i = 0; i < 4; i++)
                        if (!dqm[i]) mem[ad][8*i +: 8] = dq[8*i +: 8];
                    if (a[10]) row_open[ba] = 1'b0;
                    n_wr++;
                end
                3'b010: begin                                   // PRECHARGE
                    if (a[10]) for (int i = 0; i < 4; i++) row_open[i] = 1'b0;
                    else row_open[ba] = 1'b0;
                end
                3'b001: begin                                   // AUTO REFRESH
                    for (int i = 0; i < 4; i++)
                        if (row_open[i]) err("REFRESH with a row open");
                    if (mode_set) begin
                        if (last_ref >= 0 && now - last_ref > max_ref_gap)
                            max_ref_gap = now - last_ref;
                        last_ref = now;
                    end
                    n_ref++;
                end
                3'b000: begin                                   // LOAD MODE REGISTER
                    for (int i = 0; i < 4; i++)
                        if (row_open[i]) err("MRS with a row open");
                    if (a != 11'h020) err($sformatf("mode register %03h, expected 020", a));
                    mode_set = 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule
