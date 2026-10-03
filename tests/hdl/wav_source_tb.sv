// Testbench for wav_source: the FIFO, the pacing, the scan-wrap frame advance,
// the 16->12 bit mapping, and the blanking-on-underrun rule.
//
// These are the things that would be invisible on a screen but wrong: a
// one-sample skew between channels, a pacing that makes music play at the wrong
// speed, a channel reading garbage instead of mid-scale, or holding the last
// sample after a stall rather than blanking.
`timescale 1ns/1ps
module wav_source_tb;

    reg clk = 0, reset = 1;
    reg        frame_wr = 0;
    reg [95:0] frame_wr_data = 0;
    wire       frame_ready;
    reg [31:0] sample_rate = 0;
    reg [2:0]  channels = 3'd1, file_channels = 3'd1;
    reg        running = 0;
    reg [4:0]  channel_select = 5'd1;
    reg        auto_scan = 1'b0;   // only the 6-channel case walks the scan
    wire       response_valid;
    wire [4:0] response_channel;
    wire [11:0] response_data;
    wire       active;

    wav_source #(.CLK_HZ(32'd50_000_000), .FIFO_FRAMES(12'd2048)) dut (
        .clk(clk), .reset(reset),
        .frame_wr(frame_wr), .frame_wr_data(frame_wr_data),
        .frame_ready(frame_ready),
        .sample_rate(sample_rate), .channels(channels),
        .file_channels(file_channels), .running(running),
        .channel_select(channel_select),
        .response_valid(response_valid), .response_channel(response_channel),
        .response_data(response_data), .active(active));

    always #10 clk = ~clk;   // 50 MHz

    integer errors = 0;
    integer now = 0, nresp = 0, last_resp = -1, gap_sum = 0, gap_count = 0;
    reg [11:0] got   [0:127];
    reg [4:0]  gotch [0:127];

    integer i2, i3, avg_gap, nresp_before;
    integer vals [0:3];
    reg [95:0] f0, f1;

    // The scope advances its scan one channel per accepted response, so mirror
    // that here rather than idling a fixed number of cycles -- a fixed idle lets
    // extra ticks through and advances the frame mid-scan.
    always @(posedge clk) begin
        if (!reset && response_valid && auto_scan)
            channel_select <= (channel_select >= 5'd6) ? 5'd1 : channel_select + 5'd1;
    end

    always @(posedge clk) begin
        now = now + 1;
        if (!reset && response_valid) begin
            if (nresp < 128) begin
                got[nresp]   = response_data;
                gotch[nresp] = response_channel;
            end
            nresp = nresp + 1;
            if (last_resp >= 0) begin
                gap_sum   = gap_sum + (now - last_resp);
                gap_count = gap_count + 1;
            end
            last_resp = now;
        end
    end

    task push_frame(input [95:0] f);
    begin
        @(negedge clk);
        while (!frame_ready) @(negedge clk);
        frame_wr_data = f;
        frame_wr      = 1;
        @(negedge clk);
        frame_wr = 0;
    end
    endtask

    // a frame carrying one value on channel 0
    task push_ch0(input [15:0] v);
    begin
        frame_wr_data = 96'd0;
        frame_wr_data[15:0] = v;
        push_frame(frame_wr_data);
    end
    endtask

    // the same reduction the DUT performs, for expectation
    function [11:0] code_of(input integer v);
        begin
            code_of = ((v / 16) + 2048) & 12'hFFF;
        end
    endfunction

    task idle(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(negedge clk);
        end
    endtask

    task clear_stats;
    begin
        nresp = 0; last_resp = -1; gap_sum = 0; gap_count = 0;
    end
    endtask

    initial begin
        repeat (4) @(posedge clk); reset = 0; @(posedge clk);

        // ---------------------------------------------------------------
        $display("-- 16-bit to 12-bit mapping, both extremes --");
        vals[0] = -32768; vals[1] = 0; vals[2] = 1600; vals[3] = 32767;
        for (i2 = 0; i2 < 4; i2 = i2 + 1) push_ch0(vals[i2][15:0]);
        sample_rate   = 32'd48000;
        channels      = 3'd1;
        file_channels = 3'd1;
        clear_stats;
        channel_select = 5'd1;
        auto_scan = 1'b0;
        running = 1'b1;
        idle(5000);
        running = 1'b0;
        if (nresp < 4) begin
            errors = errors + 1;
            $display("  FAIL only %0d responses", nresp);
        end
        else begin
            for (i2 = 0; i2 < 4; i2 = i2 + 1)
                if (got[i2] !== code_of(vals[i2])) begin
                    errors = errors + 1;
                    $display("  FAIL %0d -> %0d expected %0d",
                             vals[i2], got[i2], code_of(vals[i2]));
                end
            $display("  ok   -32768 -> %0d, 0 -> %0d, 1600 -> %0d, 32767 -> %0d",
                     got[0], got[1], got[2], got[3]);
        end

        // ---------------------------------------------------------------
        $display("-- pacing: responses at rate*channels --");
        reset = 1; repeat (4) @(posedge clk); reset = 0;
        for (i2 = 0; i2 < 64; i2 = i2 + 1) push_ch0(16'sd100 + i2[15:0]);
        sample_rate   = 32'd48000;
        channels      = 3'd1;
        file_channels = 3'd1;
        clear_stats;
        channel_select = 5'd1;
        auto_scan = 1'b0;
        running = 1'b1;
        idle(30000);
        running = 1'b0;
        if (gap_count < 10) begin
            errors = errors + 1;
            $display("  FAIL too few intervals (%0d)", gap_count);
        end
        else begin
            avg_gap = gap_sum / gap_count;
            if (avg_gap < 1041 || avg_gap > 1042) begin
                errors = errors + 1;
                $display("  FAIL average interval %0d, expected 1041..1042", avg_gap);
            end
            else $display("  ok   average interval %0d cycles (50MHz/48kHz = 1041.7)", avg_gap);
        end

        // ---------------------------------------------------------------
        $display("-- one frame per scan: every channel from the same instant --");
        reset = 1; repeat (4) @(posedge clk); reset = 0;
        f0 = {16'sd1000, 16'sd900, 16'sd800, 16'sd700, 16'sd600, 16'sd500};
        f1 = {16'sd2000, 16'sd1900, 16'sd1800, 16'sd1700, 16'sd1600, 16'sd1500};
        push_frame(f0);
        push_frame(f1);
        sample_rate    = 32'd48000;
        channels       = 3'd6;
        file_channels  = 3'd6;
        clear_stats;
        channel_select = 5'd1;
        auto_scan = 1'b1;
        running = 1'b1;
        idle(4000);                          // 12 responses at ~174 cycles each
        running = 1'b0;
        auto_scan = 1'b0;
        for (i3 = 0; i3 < 6; i3 = i3 + 1)
            if (got[i3] !== code_of(500 + i3*100)) begin
                errors = errors + 1;
                $display("  FAIL frame0 ch%0d -> %0d expected %0d",
                         i3, got[i3], code_of(500 + i3*100));
            end
        for (i3 = 6; i3 < 12; i3 = i3 + 1)
            if (got[i3] !== code_of(1500 + (i3-6)*100)) begin
                errors = errors + 1;
                $display("  FAIL frame1 ch%0d -> %0d expected %0d",
                         i3-6, got[i3], code_of(1500 + (i3-6)*100));
            end
        if (got[0] === code_of(500) && got[6] === code_of(1500))
            $display("  ok   6 channels per frame in order, frame advances on wrap");

        // ---------------------------------------------------------------
        $display("-- a channel the file does not carry reads mid-scale --");
        reset = 1; repeat (4) @(posedge clk); reset = 0;
        frame_wr_data = 96'd0;
        frame_wr_data[15:0] = 16'sd3000;
        push_frame(frame_wr_data);
        sample_rate    = 32'd48000;
        channels       = 3'd6;
        file_channels  = 3'd1;
        channel_select = 5'd4;
        clear_stats;
        running = 1'b1;
        idle(3000);
        running = 1'b0;
        if (nresp < 1 || got[0] !== 12'd2048) begin
            errors = errors + 1;
            $display("  FAIL unwired channel read %0d, expected 2048", got[0]);
        end
        else $display("  ok   unwired channel reads 2048 (an unconnected probe)");

        // ---------------------------------------------------------------
        $display("-- underrun blanks: responses stop entirely --");
        reset = 1; repeat (4) @(posedge clk); reset = 0;
        push_ch0(16'sd4000);
        sample_rate    = 32'd48000;
        channels       = 3'd1;
        file_channels  = 3'd1;
        channel_select = 5'd1;
        clear_stats;
        auto_scan = 1'b0;
        running = 1'b1;
        idle(6000);                 // drains the one frame
        nresp_before = nresp;
        idle(20000);                // FIFO is now empty
        running = 1'b0;
        if (nresp != nresp_before) begin
            errors = errors + 1;
            $display("  FAIL %0d further responses after the FIFO emptied",
                     nresp - nresp_before);
        end
        else $display("  ok   %0d responses, then silence once empty", nresp_before);

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
