//============================================================================
// oscope_keys.sv -- QWERTY keyboard decoding for the scope
//
// hps_io delivers ps2_key[10:0]: [7:0] scancode (set 2), [8] extended (the E0
// prefix), [9] pressed, [10] toggles on every press and release. The pattern
// below -- strobe on [10] changing, read direction from [9] -- is the one
// used elsewhere in this author's cores, and it gives held-key auto-repeat for
// free: the keyboard sends repeated make codes, so a held key sweeps.
//
// Comparisons are against {extended, scancode} as a 9-bit value, matching
// Phosphor.sv's own decoding (9'h031 for 'N', 9'h04d for 'P').
//
// Events are suppressed while the OSD is open, so browsing the file list
// cannot move the trigger or change the timebase underneath you.
//
// This module only decodes. Deciding what each event means -- step sizes, and
// where a setting lives -- belongs to oscope_ctrl_frames.sv.
//
// There is deliberately no "comparison traces" key: the upstream protocol has
// no such control. The phone's comparison feature is just enabling more than
// one channel, which 1-6 already do. Binding a key to nothing would be a lie.
//============================================================================
module oscope_keys (
    input  wire        clk,
    input  wire        reset,
    input  wire        osd_open,   // OSD_STATUS: keys belong to the OSD
    input  wire [10:0] ps2_key,

    output reg         shift,      // level: held, not an event

    // vertical position / scale of the focus trace
    output reg         vpos_up,
    output reg         vpos_down,
    output reg         vscale_up,
    output reg         vscale_down,

    // horizontal
    output reg         tb_faster,
    output reg         tb_slower,
    output reg         trigpos_next,
    output reg         trigpos_prev,

    // trigger level
    output reg         trig_up,
    output reg         trig_down,

    // channels
    output reg  [5:0]  ch_toggle,
    output reg         focus_next,
    output reg         focus_prev,

    // acquisition
    output reg         run_toggle,
    output reg         single_shot,

    // calibration
    output reg         cal_up,
    output reg         cal_down
);

    // Set-2 make codes. Letters and digits are non-extended, so the 9-bit
    // comparison value is just the scancode.
    localparam [8:0] K_A=9'h01C, K_D=9'h023, K_S=9'h01B, K_W=9'h01D,
                     K_R=9'h02D, K_TAB=9'h00D, K_SPACE=9'h029,
                     K_LBRACK=9'h054, K_RBRACK=9'h05B,
                     K_1=9'h016, K_2=9'h01E, K_3=9'h026,
                     K_4=9'h025, K_5=9'h02E, K_6=9'h036,
                     K_LSHIFT=9'h012, K_RSHIFT=9'h059,
                     // extended (E0-prefixed)
                     K_UP=9'h175, K_DOWN=9'h172, K_LEFT=9'h16B, K_RIGHT=9'h174;

    // Only the toggle bit matters; the frame is re-read on each event.
    reg        key_toggle_previous;

    always @(posedge clk) begin
        if (reset) begin
            key_toggle_previous <= 1'b0;
            shift           <= 1'b0;
            vpos_up         <= 1'b0;  vpos_down    <= 1'b0;
            vscale_up       <= 1'b0;  vscale_down  <= 1'b0;
            tb_faster       <= 1'b0;  tb_slower    <= 1'b0;
            trigpos_next    <= 1'b0;  trigpos_prev <= 1'b0;
            trig_up         <= 1'b0;  trig_down    <= 1'b0;
            ch_toggle       <= 6'd0;
            focus_next      <= 1'b0;  focus_prev   <= 1'b0;
            run_toggle      <= 1'b0;  single_shot  <= 1'b0;
            cal_up          <= 1'b0;  cal_down     <= 1'b0;
        end
        else begin
            // Every event is a one-cycle pulse.
            vpos_up <= 1'b0;  vpos_down    <= 1'b0;
            vscale_up <= 1'b0; vscale_down <= 1'b0;
            tb_faster <= 1'b0; tb_slower   <= 1'b0;
            trigpos_next <= 1'b0; trigpos_prev <= 1'b0;
            trig_up <= 1'b0;  trig_down    <= 1'b0;
            ch_toggle <= 6'd0;
            focus_next <= 1'b0; focus_prev <= 1'b0;
            run_toggle <= 1'b0; single_shot <= 1'b0;
            cal_up <= 1'b0;   cal_down    <= 1'b0;

            key_toggle_previous <= ps2_key[10];

            if (ps2_key[10] != key_toggle_previous) begin
                // Shift is a level, tracked on both make and break.
                if (ps2_key[8:0] == K_LSHIFT || ps2_key[8:0] == K_RSHIFT)
                    shift <= ps2_key[9];

                if (ps2_key[9] && !osd_open) begin
                    case (ps2_key[8:0])
                        K_W:        vpos_up       <= 1'b1;
                        K_S:        vpos_down     <= 1'b1;
                        K_D:        vscale_up     <= 1'b1;
                        K_A:        vscale_down   <= 1'b1;

                        // Shift takes the arrows away from the timebase and
                        // gives them the pre-trigger position instead, so the
                        // two never fire together.
                        K_RIGHT: if (shift) trigpos_next <= 1'b1;
                                 else       tb_faster    <= 1'b1;
                        K_LEFT:  if (shift) trigpos_prev <= 1'b1;
                                 else       tb_slower    <= 1'b1;

                        K_UP:       trig_up       <= 1'b1;
                        K_DOWN:     trig_down     <= 1'b1;

                        K_1:        ch_toggle     <= 6'b000001;
                        K_2:        ch_toggle     <= 6'b000010;
                        K_3:        ch_toggle     <= 6'b000100;
                        K_4:        ch_toggle     <= 6'b001000;
                        K_5:        ch_toggle     <= 6'b010000;
                        K_6:        ch_toggle     <= 6'b100000;
                        K_TAB:      if (shift) focus_prev <= 1'b1;
                                    else       focus_next <= 1'b1;

                        K_R:        run_toggle    <= 1'b1;
                        K_SPACE:    single_shot   <= 1'b1;

                        K_LBRACK:   cal_down      <= 1'b1;
                        K_RBRACK:   cal_up        <= 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule
