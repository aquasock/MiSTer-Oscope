//============================================================================
// oscope_ctrl_frames.sv -- turns key events into the scope's own UART frames
//
// The scope's control surface is a byte parser (oscilloscope.vhd:684, the
// uart_rx_parser_proc), not a bank of registers. So this module does not touch
// control logic at all: it emits exactly the frames the Pico W would send, and
// the parser validates and applies them. Range checks, XOR checksums and the
// commit rules are all upstream's, already exercised by the author's own
// testing. The keyboard is simply a second client on the same protocol.
//
// Frame formats, from docs/upstream-oscilloscope/UART_PROTOCOL.md and the
// parser itself. Every terminator is the XOR of all preceding bytes.
//
//   A9  MM FF VV                       channel mask, focus, value
//   A6  TB VS VP TM LH LL FF           timebase, scale, position, trigger,
//                                      level hi/lo, display flags
//   A7  MH ML                          ADC full-scale calibration in mV
//
// A6's flag byte: bit0 grid, bit1 run, bits3:2 pre-trigger position,
// bit4 single shot, bits6:5 averaging, bit7 stabilization.
//
// The Pico sends three copies of each frame for reliability; the FPGA does not
// require them (it commits on one validated frame), so one is sent per change.
//
// All three frames are emitted on every change. That is a handful of clocks
// (18 bytes, one per clock) against a 50 MHz clock, and it means the builder
// cannot get out of step with the scope: there is no "which setting changed"
// bookkeeping to go wrong.
//============================================================================
module oscope_ctrl_frames (
    input  wire        clk,
    input  wire        reset,
    input  wire        busy,        // scope's legacy_parser_busy
    input  wire [6:0]  status,      // OSD settings; bit 7 (manual) drives SW0 at the top level

    input  wire        shift,       // held: coarse steps
    input  wire        vpos_up,
    input  wire        vpos_down,
    input  wire        vscale_up,
    input  wire        vscale_down,
    input  wire        tb_faster,
    input  wire        tb_slower,
    input  wire        trigpos_next,
    input  wire        trigpos_prev,
    input  wire        trig_up,
    input  wire        trig_down,
    input  wire [5:0]  ch_toggle,
    input  wire        focus_next,
    input  wire        focus_prev,
    input  wire        run_toggle,
    input  wire        single_shot,
    input  wire        cal_up,
    input  wire        cal_down,

    output reg  [7:0]  ctrl_byte,
    output reg         ctrl_valid,

    // How many channels the scope is set to scan. wav_source needs this to
    // pace a scan at the file's frame rate.
    output wire [2:0]  channel_count
);

    localparam integer FRAME_LEN = 18;   // A9 (5) + A6 (9) + A7 (4)

    // ---- settings, defaulted to the scope's own reset values ----
    reg [5:0]  ch_mask;
    reg [2:0]  focus;
    reg [3:0]  timebase;
    reg [1:0]  vscale;
    reg [6:0]  vposition;
    reg [1:0]  trig_mode;
    reg [11:0] trig_level;
    reg [1:0]  trigpos;
    reg [1:0]  averaging;
    reg        flag_grid;
    reg        flag_run;
    reg        flag_single;
    reg        flag_stab;
    reg [15:0] cal_mv;

    wire [7:0] flags_byte = {flag_stab, averaging, flag_single, trigpos,
                             flag_run, flag_grid};

    // Population count of the enable mask. Constant-bound loop, so it folds.
    reg [2:0] ch_count;
    integer   mk;
    always @* begin
        ch_count = 3'd0;
        for (mk = 0; mk < 6; mk = mk + 1)
            if (ch_mask[mk]) ch_count = ch_count + 3'd1;
    end
    assign channel_count = ch_count;

    // ---- helpers ----
    // Channel stepping. Written as explicit cases and a one-at-a-time walk
    // rather than modular arithmetic, so no operand is widened and nothing has
    // to be truncated to fit.
    function [2:0] next_of;
        input [2:0] v;
        begin
            case (v)
                3'd0: next_of = 3'd1;
                3'd1: next_of = 3'd2;
                3'd2: next_of = 3'd3;
                3'd3: next_of = 3'd4;
                3'd4: next_of = 3'd5;
                default: next_of = 3'd0;
            endcase
        end
    endfunction

    function [2:0] prev_of;
        input [2:0] v;
        begin
            case (v)
                3'd0: prev_of = 3'd5;
                3'd1: prev_of = 3'd0;
                3'd2: prev_of = 3'd1;
                3'd3: prev_of = 3'd2;
                3'd4: prev_of = 3'd3;
                default: prev_of = 3'd4;
            endcase
        end
    endfunction

    // Lowest enabled channel, or 0 when the mask is empty (which cannot
    // happen: the mask update below refuses to reach zero).
    function [2:0] first_enabled;
        input [5:0] mask;
        begin
            first_enabled = 3'd5;          // fallback; the mask is never empty
            if      (mask[0]) first_enabled = 3'd0;
            else if (mask[1]) first_enabled = 3'd1;
            else if (mask[2]) first_enabled = 3'd2;
            else if (mask[3]) first_enabled = 3'd3;
            else if (mask[4]) first_enabled = 3'd4;
            else if (mask[5]) first_enabled = 3'd5;
        end
    endfunction

    // Next/previous enabled channel, walking at most one full lap.
    function [2:0] step_focus;
        input [5:0] mask;
        input [2:0] from;
        input       forward;
        integer   k;
        reg [2:0] c;
        reg       found;
        begin
            // Latch the first hit rather than breaking out of the loop: Quartus
            // rejects a loop whose variable is assigned inside its own body,
            // because it cannot prove the bound. The full six steps always run.
            c = from;
            found = 1'b0;
            step_focus = from;
            for (k = 0; k < 6; k = k + 1) begin
                c = forward ? next_of(c) : prev_of(c);
                if (!found && mask[c]) begin
                    step_focus = c;
                    found = 1'b1;
                end
            end
        end
    endfunction

    // ---- OSD-controlled settings ----
    // Four settings belong to the OSD rather than the keyboard: they are
    // set-and-forget, and the keyboard carries the things you twiddle while
    // watching a trace. The keyboard never touches these, so there is no
    // precedence question between the two.
    //
    // CONF_STR is labelled so that the OSD's zero state -- a fresh config,
    // before MiSTer has saved anything -- maps exactly onto the scope's own
    // defaults: Auto trigger, no averaging, stabilized, grid shown. Two of the
    // entries are therefore inverted ("Live mode" and "Hide grid") so that an
    // unchecked box means the better default rather than the worse one.
    wire [1:0] osd_trigger_index = status[2:1];
    wire [1:0] osd_averaging     = status[4:3];
    wire       osd_live_mode     = status[5];   // 1 = live mode = stabilize OFF
    wire       osd_hide_grid     = status[6];   // 1 = grid OFF
    wire       osd_reset_pulse   = status[0] & ~status_reset_previous;

    // OSD index -> protocol trigger mode (0 free, 1 rising, 2 falling, 3 auto)
    wire [1:0] osd_trig_mode =
        (osd_trigger_index == 2'd0) ? 2'd3 :   // Auto   (index 0 = default)
        (osd_trigger_index == 2'd1) ? 2'd1 :   // Rising
        (osd_trigger_index == 2'd2) ? 2'd2 :   // Falling
                                      2'd0;    // Free

    wire       osd_flag_stab = ~osd_live_mode;
    wire       osd_flag_grid = ~osd_hide_grid;

    // Only act on an actual change, so the OSD's steady state never fights the
    // keyboard or re-emits frames every cycle.
    wire osd_changed = (osd_trig_mode  != trig_mode) |
                       (osd_averaging  != averaging) |
                       (osd_flag_stab  != flag_stab) |
                       (osd_flag_grid  != flag_grid);

    wire [6:0] step_pos = shift ? 7'd10 : 7'd1;
    wire [11:0] step_lvl = shift ? 12'd256 : 12'd16;
    wire [15:0] step_cal = shift ? 16'd100 : 16'd10;

    wire any_event = vpos_up | vpos_down | vscale_up | vscale_down |
                     tb_faster | tb_slower | trigpos_next | trigpos_prev |
                     trig_up | trig_down | (ch_toggle != 6'd0) |
                     focus_next | focus_prev | run_toggle | single_shot |
                     cal_up | cal_down;

    // mask after this cycle's toggles; never allowed to reach zero
    wire [5:0] toggled_mask = ch_mask ^ ch_toggle;
    wire [5:0] next_mask    = (toggled_mask == 6'd0) ? ch_mask : toggled_mask;

    // ---- frame assembly ----
    reg [4:0] idx;
    reg       sending;
    reg       pending;
    reg        status_reset_previous;   // only the reset button's bit is edge-detected

    function [7:0] frame_byte;
        input [4:0] i;
        reg   [5:0] m;
        reg   [2:0] f;
        reg   [7:0] a9_crc, a6_crc, a7_crc;
        begin
            m = ch_mask;
            f = focus;
            a9_crc = 8'hA9 ^ {2'b00, m} ^ {5'b00000, f} ^ 8'h00;
            a6_crc = 8'hA6 ^ {4'b0, timebase} ^ {6'b0, vscale} ^ {1'b0, vposition}
                     ^ {6'b0, trig_mode} ^ {4'b0, trig_level[11:8]}
                     ^ trig_level[7:0] ^ flags_byte;
            a7_crc = 8'hA7 ^ cal_mv[15:8] ^ cal_mv[7:0];
            case (i)
                5'd0:  frame_byte = 8'hA9;
                5'd1:  frame_byte = {2'b00, m};
                5'd2:  frame_byte = {5'b00000, f};
                5'd3:  frame_byte = 8'h00;          // per-channel value, unused
                5'd4:  frame_byte = a9_crc;
                5'd5:  frame_byte = 8'hA6;
                5'd6:  frame_byte = {4'b0, timebase};
                5'd7:  frame_byte = {6'b0, vscale};
                5'd8:  frame_byte = {1'b0, vposition};
                5'd9:  frame_byte = {6'b0, trig_mode};
                5'd10: frame_byte = {4'b0, trig_level[11:8]};
                5'd11: frame_byte = trig_level[7:0];
                5'd12: frame_byte = flags_byte;
                5'd13: frame_byte = a6_crc;
                5'd14: frame_byte = 8'hA7;
                5'd15: frame_byte = cal_mv[15:8];
                5'd16: frame_byte = cal_mv[7:0];
                default: frame_byte = a7_crc;       // 5'd17
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            ch_mask <= 6'b000001; focus <= 3'd0; timebase <= 4'd0;
            vscale <= 2'd0; vposition <= 7'd50; trig_mode <= 2'd3;
            trig_level <= 12'd2048; trigpos <= 2'd1; averaging <= 2'd0;
            flag_grid <= 1'b1; flag_run <= 1'b1; flag_single <= 1'b0;
            flag_stab <= 1'b1; cal_mv <= 16'd5000;
            idx <= 5'd0; sending <= 1'b0; pending <= 1'b0;
            status_reset_previous <= 1'b0;
            ctrl_byte <= 8'h00; ctrl_valid <= 1'b0;
        end
        else begin
            ctrl_valid <= 1'b0;

            if (any_event) begin
                pending <= 1'b1;

                // vertical position
                if (vpos_up)
                    vposition <= (vposition > 7'd100 - step_pos) ? 7'd100
                                                                 : vposition + step_pos;
                if (vpos_down)
                    vposition <= (vposition < step_pos) ? 7'd0 : vposition - step_pos;

                // vertical scale (volts/div), 0..3
                if (vscale_up   && vscale < 2'd3) vscale <= vscale + 2'd1;
                if (vscale_down && vscale > 2'd0) vscale <= vscale - 2'd1;

                // timebase, 0..10
                if (tb_faster && timebase < 4'd10) timebase <= timebase + 4'd1;
                if (tb_slower && timebase > 4'd0)  timebase <= timebase - 4'd1;

                // pre-trigger position cycles through four values
                if (trigpos_next) trigpos <= trigpos + 2'd1;
                if (trigpos_prev) trigpos <= trigpos - 2'd1;

                // trigger level, 12-bit, clamped
                if (trig_up)
                    trig_level <= (trig_level > 12'd4095 - step_lvl) ? 12'd4095
                                                                    : trig_level + step_lvl;
                if (trig_down)
                    trig_level <= (trig_level < step_lvl) ? 12'd0
                                                          : trig_level - step_lvl;

                // channels
                if (ch_toggle != 6'd0) ch_mask <= next_mask;
                if (focus_next) focus <= step_focus(next_mask, focus, 1'b1);
                if (focus_prev) focus <= step_focus(next_mask, focus, 1'b0);
                // a mask change can strand the focus on a disabled channel
                if (ch_toggle != 6'd0 && !next_mask[focus])
                    focus <= first_enabled(next_mask);

                // acquisition
                if (run_toggle)  flag_run    <= ~flag_run;
                if (single_shot) flag_single <= ~flag_single;

                // calibration
                if (cal_up && cal_mv <= 16'd9999 - step_cal) cal_mv <= cal_mv + step_cal;
                if (cal_down && cal_mv >= 16'd1000 + step_cal) cal_mv <= cal_mv - step_cal;
            end

            status_reset_previous <= status[0];

            // OSD reset button: reload every default and re-emit, so the scope
            // and the builder cannot drift apart.
            if (osd_reset_pulse) begin
                ch_mask <= 6'b000001; focus <= 3'd0; timebase <= 4'd0;
                vscale <= 2'd0; vposition <= 7'd50;
                trig_level <= 12'd2048; trigpos <= 2'd1;
                flag_run <= 1'b1; flag_single <= 1'b0;
                cal_mv <= 16'd5000;
                pending <= 1'b1;
            end
            else if (osd_changed) begin
                trig_mode <= osd_trig_mode;
                averaging <= osd_averaging;
                flag_stab <= osd_flag_stab;
                flag_grid <= osd_flag_grid;
                pending   <= 1'b1;
            end

            // Wait for the parser to be idle before starting, so an injected
            // frame can never interleave with a partially received one.
            if (!sending && pending && !busy) begin
                sending <= 1'b1;
                idx     <= 5'd0;
            end
            else if (sending) begin
                ctrl_byte  <= frame_byte(idx);
                ctrl_valid <= 1'b1;
                if (idx == FRAME_LEN[4:0] - 5'd1) begin
                    sending <= 1'b0;
                    pending <= 1'b0;
                end
                else begin
                    idx <= idx + 5'd1;
                end
            end
        end
    end

endmodule
