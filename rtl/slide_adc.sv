//============================================================================
// slide_adc.sv -- the scope's sample source
//
// Replaces upstream's rtl/slide_adc.v, which instantiated the MAX 10 modular-ADC
// IP. This device has no such block, so the source is one of:
//
//   * a synthetic triangle, for bring-up with nothing connected (and the
//     default when no file is loaded);
//   * a WAV file's samples, served by wav_source from frames the decoder
//     streams off the SD card.
//
// The mux lives here rather than at the top level because oscilloscope.vhd
// instantiates this module itself: this is the only place that sees
// channel_select and can therefore select between the two sources.
//
// Contract the consumer (adc_capture_proc in oscilloscope.vhd) needs:
//   * everything is clocked by adc_sys_clk -- drive it from the system clock;
//   * on a response, response_valid=1 AND response_channel == channel_select:
//     the sample is accepted and the scan advances to the next enabled channel;
//   * nothing else. There is no ready/busy handshake.
//
// Pacing matters. oscilloscope.vhd MEASURES the interval between accepted
// samples and the phone derives its time axis from that measurement, so a
// source that responded every clock would report nonsense. SAMPLE_HZ defaults
// to 62.5 kHz, matching the design's own adc_sample_period reset value of 800
// counts at 50 MHz.
//============================================================================
module slide_adc #(
    parameter               CLK_HZ    = 50_000_000,
    parameter               SAMPLE_HZ = 62_500,    // response rate -> measured period
    parameter signed [11:0] AMPLITUDE = 12'sd1020, // +/- excursion about mid-scale
    parameter integer       PERIOD    = 64,        // samples per cycle (power of two)
    parameter integer       CH_PHASE  = 8          // per-channel phase step, in samples
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire [4:0]  channel_select,
    output wire        adc_sys_clk,
    output wire        response_valid,
    output wire [4:0]  response_channel,
    output wire [11:0] response_data,

    // ---- WAV path: frames from wav_decoder, configuration from the core ----
    input  wire        wav_frame_wr,
    input  wire [95:0] wav_frame_data,
    output wire        wav_frame_ready,
    input  wire [31:0] wav_sample_rate,
    input  wire [2:0]  wav_file_channels,
    input  wire [2:0]  wav_scan_channels,
    input  wire        wav_running
);

    // The real bridge synchronised channel_select into the ADC clock domain. A
    // synthetic source shares the consumer's clock, so adc_sys_clk is simply
    // the system clock for both sources.
    assign adc_sys_clk = clk;

    ///////////////////////////////////////////////////////////////////////
    // WAV source
    ///////////////////////////////////////////////////////////////////////
    wire        wav_valid;
    wire        wav_active_unused;
    wire [4:0]  wav_channel;
    wire [11:0] wav_data;

    wav_source #(.CLK_HZ(CLK_HZ)) wav (
        .clk(clk), .reset(~reset_n),
        .frame_wr(wav_frame_wr), .frame_wr_data(wav_frame_data),
        .frame_ready(wav_frame_ready),
        .sample_rate(wav_sample_rate), .channels(wav_scan_channels),
        .file_channels(wav_file_channels), .running(wav_running),
        .channel_select(channel_select),
        .response_valid(wav_valid), .response_channel(wav_channel),
        .response_data(wav_data), .active(wav_active_unused));

    ///////////////////////////////////////////////////////////////////////
    // Synthetic triangle
    ///////////////////////////////////////////////////////////////////////
    // Elaboration-time constants only -- deliberately no $clog2 and no
    // variable-width arithmetic, so every synthesis flow folds this to a
    // fixed comparator against a constant.
    localparam integer DIV  = (CLK_HZ + SAMPLE_HZ / 2) / SAMPLE_HZ;  // clocks/response
    localparam integer HALF = PERIOD / 2;

    // Scale the 0..HALF-1 ramp to 0..255 for the +/-128 maths below:
    // 256/HALF == 512/PERIOD, a power of two for any power-of-two PERIOD.
    function integer shift_to_256;
        input integer value;
        integer i, r;
        begin
            r = 0;
            for (i = value; i > 1; i = i >> 1) r = r + 1;
            shift_to_256 = r;
        end
    endfunction
    localparam integer NORM_SHIFT = shift_to_256(512 / PERIOD);

    reg [31:0] div_count;
    reg [31:0] phase;                       // 0 .. PERIOD-1, one synthetic cycle

    // Per-channel phase offset so six traces land at visibly different points.
    // channel_select*CH_PHASE < PERIOD in any sane configuration, so a single
    // conditional subtract completes the modulo.
    wire [31:0] ch_sum   = phase + (channel_select * CH_PHASE);
    wire [31:0] ch_phase = (ch_sum >= PERIOD) ? (ch_sum - PERIOD) : ch_sum;

    // 0..HALF-1 .. 0 triangle, rescaled to 0..255.
    wire [31:0] tri_norm = (ch_phase >= HALF) ? (PERIOD - 1 - ch_phase) : ch_phase;
    wire [7:0]  tri_val  = 8'(tri_norm << NORM_SHIFT);   // <= 255 by construction

    // Centre the ramp on 128, then scale the -128..127 excursion to
    // +/-AMPLITUDE. The product MUST be formed at full width: assigning a
    // multiply straight into a 12-bit result evaluates it in a 12-bit context
    // and silently truncates before the shift. (The same defect, unfixed, is
    // what makes upstream's AVG readout read zero -- see scope_vga.v.)
    wire signed [9:0]  tri_s  = $signed({2'b00, tri_val}) - 10'sd128;   // -128..127
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [23:0] prod   = tri_s * AMPLITUDE;   // upper = sign, low = fraction
    wire        [11:0] exc    = prod[18:7];          // (prod >> 7), integer part
    /* verilator lint_on UNUSEDSIGNAL */
    wire        [11:0] sample = 12'd2048 + exc;      // mid-scale +/- AMPLITUDE

    reg        syn_valid;
    reg [4:0]  syn_channel;
    reg [11:0] syn_data;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            div_count   <= 32'd0;
            phase       <= 32'd0;
            syn_valid   <= 1'b0;
            syn_channel <= 5'd0;
            syn_data    <= 12'd2048;
        end
        else begin
            syn_valid <= 1'b0;

            if (div_count >= DIV - 1) begin
                div_count   <= 32'd0;
                syn_valid   <= 1'b1;
                syn_channel <= channel_select;
                syn_data    <= sample;
                phase       <= (phase >= PERIOD - 1) ? 32'd0 : (phase + 32'd1);
            end
            else begin
                div_count <= div_count + 32'd1;
            end
        end
    end

    ///////////////////////////////////////////////////////////////////////
    // Source select
    ///////////////////////////////////////////////////////////////////////
    // A loaded file wins. When it is not running -- nothing loaded, or the file
    // has stalled -- the synthetic triangle takes over, so the core always has
    // something to show rather than a dead acquisition path.
    assign response_valid   = wav_running ? wav_valid   : syn_valid;
    assign response_channel = wav_running ? wav_channel : syn_channel;
    assign response_data    = wav_running ? wav_data    : syn_data;

endmodule
