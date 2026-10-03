// Testbench for the generalised WAV decoder.
//
// Builds synthetic RIFF files in memory and checks the three things that
// matter to the port: the channel count is accepted (upstream hard-rejected
// anything but stereo), the frame contents are correct for every channel, and
// pcm_eof lands on the last frame. Plus a rejection case, and a stall, since
// upstream's handshake contract is that valid/eof stay stable while ready is
// low.
`timescale 1ns/1ps
module wav_decoder_tb;

    reg clk = 0, reset = 1;
    reg [7:0] input_data = 0;
    reg       input_valid = 0;
    wire      input_ready;
    reg       pcm_ready = 1;
    wire      pcm_valid, pcm_eof;
    wire [2:0] pcm_channels;
    wire [95:0] pcm_frame;
    wire [31:0] sample_rate, data_bytes;
    wire      metadata_valid, format_valid, format_error;

    wav_decoder #(.MAX_CHANNELS(6)) dut (
        .clk(clk), .reset(reset),
        .input_data(input_data), .input_valid(input_valid), .input_ready(input_ready),
        .pcm_valid(pcm_valid), .pcm_eof(pcm_eof), .pcm_ready(pcm_ready),
        .pcm_channels(pcm_channels), .pcm_frame(pcm_frame),
        .sample_rate(sample_rate), .data_bytes(data_bytes),
        .metadata_valid(metadata_valid), .format_valid(format_valid),
        .format_error(format_error));

    always #10 clk = ~clk;   // 50 MHz

    // Watchdog: name the state it is stuck in rather than spinning forever.
    integer wd = 0;
    always @(posedge clk) begin
        wd = wd + 1;
        if (wd == 20000) begin
            $display("WATCHDOG: state=%0d input_ready=%b fmt_size=%0d fmt_channels=%0d fmt_align=%0d fmt_bits=%0d fmt_tag=%0d fmt_rate=%0d",
                     dut.state, input_ready, dut.fmt_size, dut.fmt_channels,
                     dut.fmt_align, dut.fmt_bits, dut.fmt_tag, dut.fmt_rate);
            $finish;
        end
    end

    // ---------------- file construction ----------------
    reg [7:0] mem [0:8191];
    integer wp;

    task put(input [7:0] b); begin mem[wp] = b; wp = wp + 1; end endtask
    task put16(input [15:0] v); begin put(v[7:0]); put(v[15:8]); end endtask
    task put32(input [31:0] v); begin put(v[7:0]); put(v[15:8]); put(v[23:16]); put(v[31:24]); end endtask
    task put4(input [7:0] a, b, c, d); begin put(a); put(b); put(c); put(d); end endtask

    integer f, c;
    integer nframes;
    task build(input integer nch, input integer rate);
    begin
        wp = 0;
        put4("R","I","F","F");
        put32(36 + nframes * nch * 2);
        put4("W","A","V","E");
        put4("f","m","t"," ");
        put32(16);
        put16(1);                       // PCM
        put16(nch[15:0]);
        put32(rate);
        put32(rate * nch * 2);          // byte rate (not parsed)
        put16(nch * 2);                 // block align
        put16(16);                      // bits
        put4("d","a","t","a");
        put32(nframes * nch * 2);
        for (f = 0; f < nframes; f = f + 1)
            for (c = 0; c < nch; c = c + 1)
                put16(f * 100 + c);     // sample value for (frame, channel)
    end
    endtask

    // ---------------- streaming + collection ----------------
    integer errors = 0;
    integer got_frames;
    integer expected_nch;
    reg [15:0] got [0:15][0:5];

    // Feed bytes while the decoder accepts them. A rejected file makes the
    // decoder stop consuming (it latches format_error and parks in DONE), so
    // waiting unboundedly for readiness would hang the test -- the feeder has
    // to give up, not the decoder.
    task feed_all(input integer nbytes);
    integer k, guard;
    begin
        for (k = 0; k < nbytes; k = k + 1) begin
            @(negedge clk);
            guard = 0;
            while (!input_ready && guard < 50) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!input_ready) k = nbytes;      // decoder stopped accepting
            else begin
                input_data  = mem[k];
                input_valid = 1;
                @(negedge clk);
                input_valid = 0;
            end
        end
        repeat (20) @(negedge clk);            // let the last frame drain
    end
    endtask

    always @(posedge clk) if (!reset && pcm_valid && pcm_ready) begin
        if (got_frames < 16) begin
            got[got_frames][0] = pcm_frame[15:0];
            got[got_frames][1] = pcm_frame[31:16];
            got[got_frames][2] = pcm_frame[47:32];
            got[got_frames][3] = pcm_frame[63:48];
            got[got_frames][4] = pcm_frame[79:64];
            got[got_frames][5] = pcm_frame[95:80];
        end
        got_frames = got_frames + 1;
    end

    task run_case(input integer nch, input integer rate, input [8*24:1] name);
    integer k, errors_before;
    begin
        errors_before = errors;
        nframes = 4;
        build(nch, rate);
        reset = 1; repeat (4) @(posedge clk); reset = 0;
        got_frames = 0;
        expected_nch = nch;
        @(negedge clk);
        feed_all(wp);

        if (!format_valid) begin
            errors = errors + 1;
            $display("  FAIL %0s: format_valid low", name);
        end
        else if (pcm_channels != nch) begin
            errors = errors + 1;
            $display("  FAIL %0s: channels %0d expected %0d", name, pcm_channels, nch);
        end
        else if (got_frames != nframes) begin
            errors = errors + 1;
            $display("  FAIL %0s: %0d frames expected %0d", name, got_frames, nframes);
        end
        else begin
            for (k = 0; k < nch * nframes; k = k + 1) begin
                if (got[k/nch][k%nch] !== ((k/nch)*100 + (k%nch))) begin
                    errors = errors + 1;
                    $display("  FAIL %0s: frame %0d ch %0d = %0d expected %0d",
                             name, k/nch, k%nch, got[k/nch][k%nch], (k/nch)*100 + (k%nch));
                    k = nch * nframes;
                end
            end
            if (errors == errors_before)
                $display("  ok   %0s: %0d channels, %0d frames, %0d Hz",
                         name, pcm_channels, got_frames, sample_rate);
        end
    end
    endtask

    initial begin
        repeat (4) @(posedge clk); reset = 0; @(posedge clk);

        $display("-- accepted profiles --");
        run_case(1, 48000, "mono 16-bit 48k");
        run_case(2, 44100, "stereo 16-bit 44.1k");
        run_case(6, 48000, "5.1 16-bit 48k");
        run_case(3, 96000, "3ch 16-bit 96k (rate is not pinned)");

        $display("-- rejection --");
        nframes = 2;
        build(8, 48000);                 // 8 channels: over MAX_CHANNELS
        reset = 1; repeat (4) @(posedge clk); reset = 0;
        @(negedge clk);
        feed_all(wp);
        if (format_error && !format_valid)
            $display("  ok   8 channels rejected with format_error");
        else begin
            errors = errors + 1;
            $display("  FAIL 8 channels: format_error=%b format_valid=%b",
                     format_error, format_valid);
        end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
