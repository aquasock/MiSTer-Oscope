//============================================================================
// wav_source.sv -- serves WAV frames as the scope's sample source
//
// Sits behind the same interface as the synthetic triangle in slide_adc.sv, so
// nothing in oscilloscope.vhd changes; slide_adc muxes the two.
//
// Pacing. The scope scans N channels round-robin through one ADC, so a "scan"
// of N channels is N responses. Serving one file frame per scan, at
// CLK_HZ/(rate*N) cycles per response, makes:
//
//     frame rate        = scan rate = `rate`
//     per-channel rate  = frame rate = `rate`
//
// so the file plays at its own speed and every channel comes from the same
// frame, i.e. they are sampled together rather than skewed.
//
// The pacing uses a fractional accumulator rather than a divider: stepping by
// rate*N each clock and wrapping at CLK_HZ gives exactly rate*N ticks per
// second on average, with no division in the hardware. The scope MEASURES the
// interval between accepted samples and derives its whole time axis from that
// measurement, so the display stays correct for whatever interval results --
// pacing only decides how fast the music plays.
//
// Blanking. If the FIFO runs dry -- an SD stall, or the file ending --
// response_valid simply stops. The scope stops collecting history,
// history_valid_count never refills, and the plot goes empty. No signal, no
// display, like an analogue scope. Holding the last sample would draw a lie.
//
// Block RAM. The frame FIFO is read through a REGISTERED address. An
// asynchronous read of a 2048 x 96 array cannot be inferred as block RAM, and
// Quartus implemented it as 196 kbit of registers instead -- 219% of the
// device's ALMs. The registered read costs the first channel of a new scan two
// cycles of latency (see `pend` below), which is nothing against a response
// interval of hundreds of cycles, and the scope measures intervals rather than
// their phase.
//============================================================================
module wav_source #(
    parameter [31:0] CLK_HZ      = 32'd50_000_000,
    parameter [11:0] FIFO_FRAMES = 12'd2048   // 2048 x 96 = 196 kbit of block RAM
) (
    input  wire        clk,
    input  wire        reset,

    // --- frame stream from wav_decoder ---
    input  wire        frame_wr,
    input  wire [95:0] frame_wr_data,
    output wire        frame_ready,     // the decoder's pcm_ready

    // --- configuration ---
    input  wire [31:0] sample_rate,     // 0 = nothing loaded
    input  wire [2:0]  channels,        // channels the scope is scanning
    input  wire [2:0]  file_channels,   // channels the file actually carries
    input  wire        running,

    // --- the slide_adc interface ---
    input  wire [4:0]  channel_select,  // 1..6, i.e. scan channel + 1
    output reg         response_valid,
    output reg  [4:0]  response_channel,
    output reg  [11:0] response_data,
    output wire        active           // 1 while the file is supplying samples
);

    // ---------------- FIFO storage and pointers ----------------
    reg [95:0] fifo [0:FIFO_FRAMES-1];
    reg [10:0] wr_ptr, rd_ptr;
    reg [11:0] count;
    reg [95:0] rd_data;                  // registered read -> block RAM

    wire       full  = (count >= FIFO_FRAMES);
    wire       empty = (count == 12'd0);

    assign frame_ready = !full;

    // ---------------- pacing ----------------
    // rate*N responses per second, by fractional accumulation.
    wire [31:0] step    = sample_rate * {29'd0, channels};
    reg  [31:0] acc;
    wire [32:0] acc_sum = {1'b0, acc} + {1'b0, step};
    wire        tick    = running && (acc_sum >= {1'b0, CLK_HZ});

    // ---------------- scan wrap detection ----------------
    // The scope scans upward through the enabled channels and then wraps, so a
    // request that does NOT exceed the previous one ends a scan. That also
    // covers the single-channel case, where the request never changes and
    // every response is therefore a new frame.
    reg  [4:0]  prev_channel;
    wire        scan_wrap = (channel_select <= prev_channel);

    // ---------------- frame advance ----------------
    // Advancing needs TWO frames queued, not one: the head is the frame this
    // scan has been reading, so the next is the one a new scan needs. With only
    // one queued there is nothing to advance to and the scan blanks, rather
    // than redrawing the same frame as if it were new.
    wire [10:0] rd_next   = (rd_ptr == FIFO_FRAMES[10:0] - 11'd1) ? 11'd0 : rd_ptr + 11'd1;
    wire        have_next = (count >= 12'd2);
    wire        advance   = tick && scan_wrap;
    wire        pop_now   = advance && have_next;

    // ---------------- frame read ----------------
    wire [2:0]  file_index = channel_select[2:0] - 3'd1;   // 0..5
    wire [6:0]  bit_off    = {file_index, 4'b0000};         // file_index * 16
    wire [15:0] raw        = rd_data[bit_off +: 16];
    /* verilator lint_off UNUSEDSIGNAL */
    // Channel n of a file carrying fewer than n channels reads mid-scale: an
    // unconnected probe, not a trace pinned to the bottom of the screen.
    wire [15:0] sample16   = (file_index < file_channels) ? raw : 16'd0;
    // Signed 16 -> unsigned 12. The low 4 bits are the discarded fraction and
    // the top 12 bits of the signed value are exactly v/16, so this needs no
    // clamp and no special case for the sign: adding mid-scale in 12-bit
    // modular arithmetic lands exactly in 0..4095.
    wire [11:0] adc_code   = sample16[15:4] + 12'd2048;
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------- FIFO write / pop ----------------
    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= 11'd0;
            rd_ptr <= 11'd0;
            count  <= 12'd0;
        end
        else begin
            if (frame_wr && frame_ready) begin
                fifo[wr_ptr] <= frame_wr_data;
                wr_ptr       <= (wr_ptr == FIFO_FRAMES[10:0] - 11'd1) ? 11'd0 : wr_ptr + 11'd1;
            end
            if (pop_now) rd_ptr <= rd_next;

            case ({frame_wr && frame_ready, pop_now})
                2'b10:   count <= count + 12'd1;
                2'b01:   count <= count - 12'd1;
                default: ;
            endcase
        end
    end

    always @(posedge clk) rd_data <= fifo[rd_ptr];

    // ---------------- response ----------------
    reg        blanked;                  // this scan has no frame to show
    reg  [1:0] pend;                     // delayed first-channel serve

    always @(posedge clk) begin
        if (reset) begin
            acc              <= 32'd0;
            prev_channel     <= 5'd0;
            blanked          <= 1'b0;
            pend             <= 2'd0;
            response_valid   <= 1'b0;
            response_channel <= 5'd0;
            response_data    <= 12'd2048;
        end
        else begin
            response_valid <= 1'b0;

            if (tick) acc <= acc_sum[31:0] - CLK_HZ;
            else      acc <= acc_sum[31:0];

            // The first channel of a new scan is served two cycles after the
            // wrap: rd_ptr moves on the wrap edge, the registered RAM read
            // presents the new frame one cycle later, and this is the cycle
            // after that.
            if (pend == 2'd1) begin
                response_valid   <= 1'b1;
                response_channel <= channel_select;
                response_data    <= adc_code;
            end
            if (pend != 2'd0) pend <= pend - 2'd1;

            if (tick) begin
                if (scan_wrap) begin
                    blanked <= ~have_next;
                    if (have_next) pend <= 2'd2;
                end
                else if (!blanked && !empty) begin
                    response_valid   <= 1'b1;
                    response_channel <= channel_select;
                    response_data    <= adc_code;
                end
                // Otherwise: say nothing at all, and the plot empties.
                prev_channel <= channel_select;
            end
        end
    end

    assign active = running && !blanked && !empty;

endmodule
