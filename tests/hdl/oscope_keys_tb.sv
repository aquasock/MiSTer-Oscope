// Contract check for oscope_keys: drives real set-2 scancodes through the
// hps_io ps2_key format and asserts exactly the intended pulse fires, and
// nothing else does.
`timescale 1ns/1ps
module oscope_keys_tb;
    reg clk = 0, reset = 1, osd_open = 0;
    reg [10:0] pk = 0;

    wire shift, vpos_up, vpos_down, vscale_up, vscale_down;
    wire tb_faster, tb_slower, trigpos_next, trigpos_prev;
    wire trig_up, trig_down;
    wire [5:0] ch_toggle;
    wire focus_next, focus_prev;
    wire run_toggle, single_shot, cal_up, cal_down;

    oscope_keys dut (
        .clk(clk), .reset(reset), .osd_open(osd_open), .ps2_key(pk),
        .shift(shift),
        .vpos_up(vpos_up), .vpos_down(vpos_down),
        .vscale_up(vscale_up), .vscale_down(vscale_down),
        .tb_faster(tb_faster), .tb_slower(tb_slower),
        .trigpos_next(trigpos_next), .trigpos_prev(trigpos_prev),
        .trig_up(trig_up), .trig_down(trig_down),
        .ch_toggle(ch_toggle), .focus_next(focus_next), .focus_prev(focus_prev),
        .run_toggle(run_toggle), .single_shot(single_shot),
        .cal_up(cal_up), .cal_down(cal_down));

    always #10 clk = ~clk;      // 50 MHz

    // ---- scancodes (set 2; {extended, scancode}) ----
    localparam [8:0] A=9'h01C, D=9'h023, R=9'h02D, S=9'h01B, W=9'h01D,
                     TAB=9'h00D, SPACE=9'h029, LB=9'h054, RB=9'h05B,
                     K3=9'h026, K6=9'h036,
                     LSHIFT=9'h012, UP=9'h175, DOWN=9'h172,
                     LEFT=9'h16B, RIGHT=9'h174;

    // ---- pulse capture ----
    reg [22:0] seen;
    reg        capturing;
    always @(posedge clk) if (capturing) begin
        seen[0]  = seen[0]  | vpos_up;
        seen[1]  = seen[1]  | vpos_down;
        seen[2]  = seen[2]  | vscale_up;
        seen[3]  = seen[3]  | vscale_down;
        seen[4]  = seen[4]  | tb_faster;
        seen[5]  = seen[5]  | tb_slower;
        seen[6]  = seen[6]  | trigpos_next;
        seen[7]  = seen[7]  | trigpos_prev;
        seen[8]  = seen[8]  | trig_up;
        seen[9]  = seen[9]  | trig_down;
        seen[15:10] = seen[15:10] | ch_toggle;
        seen[16] = seen[16] | focus_next;
        seen[17] = seen[17] | focus_prev;
        seen[19] = seen[19] | run_toggle;
        seen[20] = seen[20] | single_shot;
        seen[21] = seen[21] | cal_up;
        seen[22] = seen[22] | cal_down;
    end

    integer errors = 0;

    task send_make(input [8:0] k);
    begin
        pk = {~pk[10], 1'b1, k};
        @(posedge clk); @(posedge clk);
    end
    endtask

    task send_break(input [8:0] k);
    begin
        pk = {~pk[10], 1'b0, k};
        @(posedge clk); @(posedge clk);
    end
    endtask

    task press(input [8:0] k);
    begin send_make(k); send_break(k); end
    endtask

    // press, and assert exactly this bitmap of events fired
    task press_expect(input [8:0] k, input [22:0] want, input [8*48:1] name);
    begin
        seen = 23'd0; capturing = 1'b1;
        press(k);
        capturing = 1'b0;
        if (seen !== want) begin
            errors = errors + 1;
            $display("  FAIL %0s: seen %b expected %b", name, seen, want);
        end else
            $display("  ok   %0s", name);
    end
    endtask

    localparam B_VPOS_UP   = 23'h000001;

    initial begin
        repeat (4) @(posedge clk); reset = 0; @(posedge clk);

        $display("-- plain keys --");
        press_expect(W,     23'h000001, "W   -> vpos_up");
        press_expect(S,     23'h000002, "S   -> vpos_down");
        press_expect(D,     23'h000004, "D   -> vscale_up");
        press_expect(A,     23'h000008, "A   -> vscale_down");
        press_expect(RIGHT, 23'h000010, "Right -> tb_faster");
        press_expect(LEFT,  23'h000020, "Left  -> tb_slower");
        press_expect(UP,    23'h000100, "Up    -> trig_up");
        press_expect(DOWN,  23'h000200, "Down  -> trig_down");
        press_expect(K3,    23'h001000, "3     -> ch_toggle[2]");
        press_expect(K6,    23'h008000, "6     -> ch_toggle[5]");
        press_expect(TAB,   23'h010000, "Tab   -> focus_next");
        press_expect(R,     23'h080000, "R     -> run_toggle");
        press_expect(SPACE, 23'h100000, "Space -> single_shot");
        press_expect(LB,    23'h400000, "[     -> cal_down");
        press_expect(RB,    23'h200000, "]     -> cal_up");

        $display("-- shift held: coarse, and arrows change meaning --");
        send_make(LSHIFT);
        if (!shift) begin errors=errors+1; $display("  FAIL shift not tracked"); end
        else $display("  ok   shift tracked");
        press_expect(W,     23'h000001, "Shift+W -> vpos_up (frame builder adds coarse)");
        press_expect(RIGHT, 23'h000040, "Shift+Right -> trigpos_next, NOT tb_faster");
        press_expect(LEFT,  23'h000080, "Shift+Left  -> trigpos_prev, NOT tb_slower");
        press_expect(TAB,   23'h020000, "Shift+Tab   -> focus_prev");
        send_break(LSHIFT);
        if (shift) begin errors=errors+1; $display("  FAIL shift stuck on"); end
        else $display("  ok   shift released");

        $display("-- OSD open: core must not act on keys --");
        osd_open = 1'b1; @(posedge clk);
        press_expect(W,     23'h000000, "W while OSD open -> nothing");
        press_expect(RIGHT, 23'h000000, "Right while OSD open -> nothing");
        osd_open = 1'b0; @(posedge clk);

        $display("-- held key auto-repeat --");
        seen = 23'd0; capturing = 1'b1;
        send_make(UP); send_break(UP);      // keyboard repeats make codes
        send_make(UP); send_break(UP);
        send_make(UP); send_break(UP);
        capturing = 1'b0;
        if (seen[8] !== 1'b1) begin errors=errors+1; $display("  FAIL repeat did not fire"); end
        else $display("  ok   three repeats produced pulses");

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
