// Single-master SDRAM controller for the Tang SDRAM module (W9825G6KH class: 16-bit data,
// 4 banks x 8K rows x 512 columns x 16 bits = 32 MB), with the host port of sdram.v (the
// Tang Nano 20K's embedded 32-bit SDRAM), so the board layer uses either.
//
// Timing follows fpga_nestang's sdram_nes.v and fpga_snestang's sdram_cl2_2ch.v, the
// controllers that work on the Tang Console with this module and these pins:
//   - clk is about 64.5 MHz (gowin_pll_sdram, 50 MHz * 40 / 31);
//   - the SDRAM clock pin is a second output of the same PLL, 225 degrees behind clk
//     (the top level connects it; nothing here drives it);
//   - CAS latency 2, burst length 1, auto precharge;
//   - ACTIVATE at clock 0, READ/WRITE at clock 1, read data sampled at clock 4.
//
// One 16-bit access ("half"):
//
//   edge  E0  ACTIVATE (row)
//   edge  E1  READ/WRITE with A10=1 (auto precharge); a write drives DQ and DQM here
//   edge  E4  read data registered in dq_r (I/O block register), as sdram_nes.v's cycle 4
//   edge  E5  the half is done: a word's second half starts here with its ACTIVATE,
//             otherwise dout / data_ready (reads), back to IDLE, busy drops
//
// A 32-bit word is two halves (the low 16 bits at an even column, the high 16 bits at the
// next), 10 clocks; a byte is one half with DQM selecting the byte, 5 clocks.
//
//   T_RCD = 1 clock (15.5 ns), as sdram_nes.v
//   T_RC  = 5 clocks (77.5 ns) >= 60 ns; a write's recovery and precharge (T_DAL) end
//           before the next ACTIVATE
//
// Address map of the 23-bit byte address (8 MB of the 32 MB, bank 0):
//     [22:10] row (13 bits)   [9:1] column (9 bits)   [0] byte in 16-bit column
// Byte address a is column a[9:1], byte a[0] (0 = DQ[7:0]), so a word at a (a[1:0] = 0)
// holds bytes a..a+3 as in sdram.v.
//
// Refresh: AUTO REFRESH from IDLE every REFRESH_CYCLES clocks (default 480 = 7.4 us at
// 64.5 MHz; 8192 rows need a refresh command at most every 7.8 us). busy is raised as soon
// as a refresh is pending; a host pulse and a pending refresh in IDLE: the host goes first.
// No CKE output: the Tang SDRAM module sets CKE itself (the Console's header has no CKE pin).
//
// Host port protocol (as sdram.v):
//   rd / wr : 1-cycle pulse, only when busy == 0. addr / din / word must be valid in that
//             cycle. For a word access addr[1:0] is ignored.
//   data_ready : 1-cycle pulse, dout valid in the same cycle (reads only).
//   busy : 1 during init, during a transaction, and while a refresh is pending/running.
//
// FPGA notes: single clock domain; DQ, DQM, address and command are registers with nothing
// between them and the pins, so build.tcl's -ireg_in_iob / -oreg_in_iob / -ioreg_in_iob put
// them in the I/O blocks.

module sdram16 #(
    parameter integer CLK_HZ         = 64_516_129,
    parameter integer REFRESH_CYCLES = 480
) (
    input             clk,          // gowin_pll_sdram CLKOUT1 (64.5 MHz)
    input             resetn,       // clk domain

    // host port
    input             rd,
    input             wr,
    input             word,         // 1 = 32-bit word access, 0 = byte access
    input      [22:0] addr,
    input      [31:0] din,          // byte writes use din[7:0]
    output reg [31:0] dout,         // byte reads return the byte in dout[7:0]
    output            busy,
    output reg        data_ready,

    // SDRAM pins
    inout      [15:0] sdram_dq,
    output reg [12:0] sdram_a,
    output reg [1:0]  sdram_ba,
    output reg [1:0]  sdram_dqm,
    output            sdram_cs_n,
    output            sdram_ras_n,
    output            sdram_cas_n,
    output            sdram_we_n
);

    // {CS#, RAS#, CAS#, WE#}
    localparam [3:0] CMD_NOP    = 4'b0111;
    localparam [3:0] CMD_ACTIVE = 4'b0011;
    localparam [3:0] CMD_READ   = 4'b0101;
    localparam [3:0] CMD_WRITE  = 4'b0100;
    localparam [3:0] CMD_PRE    = 4'b0010;
    localparam [3:0] CMD_REF    = 4'b0001;
    localparam [3:0] CMD_MRS    = 4'b0000;

    // CAS latency 2 (A6:4=010), sequential (A3=0), burst length 1 (A2:0=000) -> 0x020,
    // as sdram_nes.v
    localparam [12:0] MODE_REG = 13'b000_0_00_010_0_000;

    localparam integer INIT_WAIT = (CLK_HZ / 1000) * 200 / 1000;   // 200 us

    reg [3:0] cmd = CMD_NOP;
    assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd;

    reg         dq_oen = 1'b1;          // 0 = FPGA drives DQ
    reg  [15:0] dq_out;
    assign sdram_dq = dq_oen ? 16'hzzzz : dq_out;

    // DQ is registered on every edge with nothing between pad and register (I/O block).
    // At the step 5 edge it holds the data sampled at the step 4 edge.
    reg  [15:0] dq_r;
    always @(posedge clk) dq_r <= sdram_dq;

    // ------------------------------------------------------------------ init
    reg [14:0] init_cnt = 0;
    reg        init_wait_done = 1'b0;
    reg [4:0]  ic = 0;
    reg        init_run = 1'b0;
    reg        init_done = 1'b0;

    // ------------------------------------------------------------------ transaction
    localparam [1:0] OP_RD = 2'd0, OP_WR = 2'd1, OP_REF = 2'd2;

    reg        busy_r = 1'b0;
    reg [2:0]  step = 0;                // 0 = idle
    reg [1:0]  op;
    reg [22:0] addr_l;
    reg [31:0] din_l;
    reg        word_l;
    reg        hi;                      // word: 0 = low half, 1 = high half
    reg [15:0] lo_data;                 // word read: the low half

    reg        ref_pend = 1'b0;
    reg [9:0]  ref_cnt = 0;

    assign busy = busy_r | ref_pend | ~init_done;

    // column of the current half: a word's halves are at an even column and the next one
    wire [8:0] col = word_l ? {addr_l[9:2], hi} : addr_l[9:1];

    always @(posedge clk) begin
        // defaults
        cmd        <= CMD_NOP;
        sdram_dqm  <= 2'b11;
        dq_oen     <= 1'b1;
        data_ready <= 1'b0;

        if (!resetn) begin
            init_cnt       <= 0;
            init_wait_done <= 1'b0;
            init_run       <= 1'b0;
            init_done      <= 1'b0;
            ic             <= 0;
            busy_r         <= 1'b0;
            step           <= 0;
            ref_pend       <= 1'b0;
            ref_cnt        <= 0;
        end else begin
            // refresh timer
            if (ref_cnt == REFRESH_CYCLES - 1) begin
                ref_pend <= 1'b1;
                ref_cnt  <= 0;
            end else begin
                ref_cnt <= ref_cnt + 1'b1;
            end

            if (!init_done) begin
                // ---------------- power-up sequence (T_RP 2, T_RFC 8, T_MRD 3 clocks)
                ref_pend <= 1'b0;
                if (!init_wait_done) begin
                    if (init_cnt == INIT_WAIT) begin
                        init_wait_done <= 1'b1;
                        init_run       <= 1'b1;
                        ic             <= 0;
                    end else
                        init_cnt <= init_cnt + 1'b1;
                end else if (init_run) begin
                    ic <= ic + 1'b1;
                    case (ic)
                        5'd0:  begin cmd <= CMD_PRE; sdram_a <= 13'h0400; sdram_ba <= 2'b00; end
                        5'd3:  cmd <= CMD_REF;
                        5'd11: cmd <= CMD_REF;
                        5'd19: begin cmd <= CMD_MRS; sdram_a <= MODE_REG; sdram_ba <= 2'b00; end
                        5'd22: begin init_run <= 1'b0; init_done <= 1'b1; ref_cnt <= 0; end
                        default: ;
                    endcase
                end
            end else if (step == 0) begin
                // ---------------- IDLE
                if (rd | wr) begin
                    op       <= wr ? OP_WR : OP_RD;
                    addr_l   <= addr;
                    din_l    <= din;
                    word_l   <= word;
                    hi       <= 1'b0;
                    cmd      <= CMD_ACTIVE;
                    sdram_ba <= 2'b00;
                    sdram_a  <= addr[22:10];
                    busy_r   <= 1'b1;
                    step     <= 3'd1;
                end else if (ref_pend) begin
                    op       <= OP_REF;
                    cmd      <= CMD_REF;
                    ref_pend <= 1'b0;
                    ref_cnt  <= 0;
                    busy_r   <= 1'b1;
                    step     <= 3'd1;
                end
            end else begin
                // ---------------- inside a transaction
                step <= step + 1'b1;
                case (step)
                    3'd1: begin
                        case (op)
                            OP_RD: begin
                                cmd       <= CMD_READ;
                                sdram_a   <= {2'b00, 1'b1, 1'b0, col};   // A10 = auto precharge
                                sdram_ba  <= 2'b00;
                                sdram_dqm <= 2'b00;
                            end
                            OP_WR: begin
                                cmd       <= CMD_WRITE;
                                sdram_a   <= {2'b00, 1'b1, 1'b0, col};
                                sdram_ba  <= 2'b00;
                                if (word_l) begin
                                    sdram_dqm <= 2'b00;
                                    dq_out    <= hi ? din_l[31:16] : din_l[15:0];
                                end else begin
                                    sdram_dqm <= addr_l[0] ? 2'b01 : 2'b10;
                                    dq_out    <= {2{din_l[7:0]}};
                                end
                                dq_oen    <= 1'b0;
                            end
                            default: ;
                        endcase
                    end
                    3'd5: begin
                        // dq_r holds the data sampled at the step 4 edge
                        if (op != OP_REF && word_l && !hi) begin
                            // second half of a word: ACTIVATE again, same row
                            lo_data  <= dq_r;
                            hi       <= 1'b1;
                            cmd      <= CMD_ACTIVE;
                            sdram_ba <= 2'b00;
                            sdram_a  <= addr_l[22:10];
                            step     <= 3'd1;
                        end else begin
                            if (op == OP_RD) begin
                                if (word_l)
                                    dout <= {dq_r, lo_data};
                                else
                                    dout <= {24'h0, addr_l[0] ? dq_r[15:8] : dq_r[7:0]};
                                data_ready <= 1'b1;
                            end
                            step   <= 0;
                            busy_r <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
