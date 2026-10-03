// Contract check for the synthetic ADC stand-in.
//
// Verifies what oscilloscope.vhd's adc_capture_proc relies on, plus the one
// property that makes the synthetic source useful as a trigger experiment:
// the waveform's length IN SAMPLES, which is what beats against scope_vga's
// 576-sample triggered record.
`timescale 1ns/1ps
module slide_adc_tb;
    localparam integer RESPONSES = 2000;   // >> one synthetic cycle
    localparam integer PERIOD    = 64;     // must match the DUT default

    reg clk = 0, reset_n = 0;
    reg  [4:0] ch = 5'd1;                  // the design commands 1..6 for scan 0..5
    wire       adc_clk, valid;
    wire [4:0] rch;
    wire [11:0] rdata;

    // WAV path tied off: this bench covers the synthetic generator, which is
    // the source whenever no file is loaded. wav_source has its own bench.
    reg        wav_running = 0;
    wire       wav_ready;
    slide_adc #(.CLK_HZ(50_000_000), .SAMPLE_HZ(62_500), .PERIOD(PERIOD)) dut (
        .clk(clk), .reset_n(reset_n), .channel_select(ch),
        .adc_sys_clk(adc_clk), .response_valid(valid),
        .response_channel(rch), .response_data(rdata),
        .wav_frame_wr(1'b0), .wav_frame_data(96'd0), .wav_frame_ready(wav_ready),
        .wav_sample_rate(32'd0), .wav_file_channels(3'd0),
        .wav_scan_channels(3'd1), .wav_running(wav_running));

    always #10 clk = ~clk;                 // 50 MHz

    integer responses = 0, since_last = 0, min_gap = 1<<30, max_gap = 0;
    integer bad_channel = 0;
    reg [11:0] vmin = 12'hFFF, vmax = 12'h000;

    integer samples_since_cross = 0, crossings = 0;
    integer min_period = 1<<30, max_period = 0;
    reg prev_below = 1'b0;

    always @(posedge clk) if (reset_n) begin
        since_last = since_last + 1;
        if (valid) begin
            responses = responses + 1;
            // The first interval is measured from reset release rather than
            // from a previous response, so it is not part of the pacing check.
            if (responses > 1) begin
                if (since_last < min_gap) min_gap = since_last;
                if (since_last > max_gap) max_gap = since_last;
            end
            since_last = 0;
            if (rch !== ch) bad_channel = bad_channel + 1;
            if (rdata < vmin) vmin = rdata;
            if (rdata > vmax) vmax = rdata;

            // Measure the period in SAMPLES between rising mid-scale crossings.
            // Only after the channel stops changing: a channel change moves the
            // per-channel phase offset, which is a deliberate discontinuity in
            // the synthetic source and would otherwise register as a short
            // interval rather than a period.
            if (responses > RESPONSES/2 && rdata >= 12'd2048) begin
                if (prev_below) begin
                    crossings = crossings + 1;
                    if (crossings > 1) begin
                        if (samples_since_cross < min_period) min_period = samples_since_cross;
                        if (samples_since_cross > max_period) max_period = samples_since_cross;
                    end
                    samples_since_cross = 0;
                end
                prev_below = 1'b0;
            end
            else begin
                prev_below = 1'b1;
            end
            samples_since_cross = samples_since_cross + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk); reset_n = 1;
        // Change the commanded channel on a NEGEDGE. Doing it on a posedge
        // races the response the DUT registers at that same edge, which shows
        // up as a one-off channel mismatch and a one-cycle gap.
        // Offset off the divider boundary: landing exactly on a tick leaves a
        // response in flight for the old channel, which is correct behaviour but
        // looks like a mismatch here.
        repeat (RESPONSES/3 * 800 + 3) @(posedge clk);
        @(negedge clk);
        ch = 5'd4;                          // move the commanded channel, as the scan does
    end

    initial begin
        wait (responses >= RESPONSES);
        $display("responses            = %0d", responses);
        $display("pacing gap min/max   = %0d / %0d   (expect 800 / 800)", min_gap, max_gap);
        $display("data min/max         = %0d / %0d   (expect a swing > 1000)", vmin, vmax);
        $display("  (peak is ~3004 not 3060: a %0d-sample triangle quantises the top)", PERIOD);
        $display("channel mismatches   = %0d   (expect 0)", bad_channel);
        $display("period in samples    = %0d / %0d   (expect %0d / %0d)",
                 min_period, max_period, PERIOD, PERIOD);
        if (bad_channel == 0 && min_gap == 800 && max_gap == 800 &&
            (vmax - vmin) > 1000 && min_period == PERIOD && max_period == PERIOD)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
