//============================================================================
// wav_decoder.sv -- RIFF WAV chunk-walker, 1..MAX_CHANNELS channels
//
// Forked from MiSTer-Phosphor's rtl/wav_decoder.sv (same author, GPL-3.0) and
// generalised here. mister_oscope is its own project from this point, so this
// file is evolved here rather than kept in step with Phosphor.
//
// What changed from upstream, and why:
//
//   * Channel count. Upstream declared 16-bit/44.1-48 kHz/**stereo** and
//     hard-rejected everything else, so a 5.1 file -- 6 channels, 16-bit,
//     48 kHz, passing every other test -- landed in format_error. This accepts
//     1..MAX_CHANNELS and emits a whole frame at a time.
//   * Output shape. Upstream emitted pcm_left/pcm_right for the audio path. A
//     scope needs every channel of a frame together, so this emits pcm_frame
//     (MAX_CHANNELS x signed 16) plus pcm_channels.
//   * Sample rate. Upstream pinned 44.1/48 kHz because its audio output is
//     fixed-rate. The scope derives its timebase from its own *measured*
//     sample interval, so any sane rate works; it is reported for the loader
//     to pace against.
//   * total_samples is dropped: upstream computed it as bytes>>2, which is the
//     frame count only for stereo. data_bytes is reported instead, and the
//     consumer divides by frame_bytes if it wants a count.
//
// The RIFF walk itself -- header skip, chunk ID/size, the odd-size pad byte,
// fmt parsing, data-chunk streaming, backpressure via input_ready/pcm_ready --
// is upstream's structure and is kept as-is, including its care about holding
// pcm_valid/pcm_eof stable for the whole handshake rather than only on the
// accepting cycle.
//============================================================================
module wav_decoder #(
    parameter [15:0] MAX_CHANNELS = 16'd6
) (
    input  wire        clk,
    input  wire        reset,

    input  wire [7:0]  input_data,
    input  wire        input_valid,
    output wire        input_ready,

    output wire        pcm_valid,
    output wire        pcm_eof,
    input  wire        pcm_ready,
    output wire [2:0]  pcm_channels,      // 1..MAX_CHANNELS, latched from `fmt `
    output wire [95:0] pcm_frame,         // MAX_CHANNELS x signed 16; ch0 in [15:0]

    output reg  [31:0] sample_rate,
    output reg  [31:0] data_bytes,
    output reg         metadata_valid,
    output reg         format_valid,
    output reg         format_error
);

localparam
    SKIP_HEADER  = 0,   // 12 bytes: "RIFF" + chunk_size(4) + "WAVE", not validated
    CHUNK_ID     = 1,   // 4 bytes: chunk fourCC, MSB-first as read
    CHUNK_SIZE   = 2,   // 4 bytes: chunk size, little-endian
    SKIP_CHUNK   = 3,   // skip a non-`data` chunk (+1 pad byte if its size was odd)
    SAMPLE_LO    = 4,   // low byte of the current channel's sample
    SAMPLE_HI    = 5,   // high byte; the frame is written when the last channel lands
    EMIT         = 6,
    DONE         = 7,
    VALIDATE_FMT = 8;

reg [3:0]  state;
reg [3:0]  byte_idx;
reg [3:0]  header_skip_left;
reg [31:0] chunk_id;
reg [31:0] chunk_remaining;   // bytes left to skip, and the running counter in SKIP_CHUNK
reg [31:0] data_remaining;    // bytes left in the `data` chunk
reg        chunk_odd;         // this chunk's declared size was odd: one pad byte follows
reg [7:0]  sample_lo;
reg [31:0] fmt_size, fmt_rate;
reg [15:0] fmt_tag, fmt_channels, fmt_align, fmt_bits;
reg [5:0]  chunk_position;

reg [2:0]  channels;          // latched, 1..MAX_CHANNELS
reg [4:0]  frame_bytes;       // 2 * channels
reg [2:0]  ch_index;
reg signed [15:0] frame_r [0:MAX_CHANNELS-1];

wire is_data_chunk = (chunk_id == 32'h64617461); // "data"
wire is_fmt_chunk  = (chunk_id == 32'h666d7420); // "fmt "
wire [31:0] frame_bytes32 = {27'd0, frame_bytes};

integer i;

// Ready in every state that consumes a live input byte. EMIT only consumes the
// already-assembled pcm_ready handshake, not a new byte, so it must not also
// claim input_ready.
assign input_ready = (state == SKIP_HEADER) || (state == CHUNK_ID) || (state == CHUNK_SIZE) ||
                     (state == SKIP_CHUNK)  || (state == SAMPLE_LO) || (state == SAMPLE_HI);

assign pcm_valid    = (state == EMIT);
assign pcm_eof      = (state == EMIT) && (data_remaining == frame_bytes32);
assign pcm_channels = channels;
assign pcm_frame    = {frame_r[5], frame_r[4], frame_r[3],
                       frame_r[2], frame_r[1], frame_r[0]};

always @(posedge clk) begin
    if (reset) begin
        state            <= SKIP_HEADER;
        header_skip_left <= 4'd12;
        byte_idx         <= 4'd0;
        metadata_valid   <= 1'b0;
        format_valid     <= 1'b0;
        sample_rate      <= 32'd0;
        format_error     <= 1'b0;
        data_bytes       <= 32'd0;
        fmt_size <= 0; fmt_rate <= 0; fmt_tag <= 0; fmt_channels <= 0;
        fmt_align <= 0; fmt_bits <= 0; chunk_position <= 0;
        channels <= 3'd1; frame_bytes <= 5'd2; ch_index <= 3'd0;
        for (i = 0; i < MAX_CHANNELS; i = i + 1) frame_r[i] <= 16'sd0;
    end
    else begin
        case (state)

        SKIP_HEADER: if (input_valid) begin
            header_skip_left <= header_skip_left - 4'd1;
            if (header_skip_left == 4'd1) begin
                state    <= CHUNK_ID;
                byte_idx <= 4'd0;
            end
        end

        CHUNK_ID: if (input_valid) begin
            chunk_id <= {chunk_id[23:0], input_data};
            if (byte_idx == 4'd3) begin state <= CHUNK_SIZE; byte_idx <= 4'd0; end
            else                   byte_idx <= byte_idx + 4'd1;
        end

        // Little-endian: assembled straight into byte lanes, the reverse of the
        // shift-in-MSB-first pattern CHUNK_ID uses for the (literal-order) fourCC.
        CHUNK_SIZE: if (input_valid) begin
            case (byte_idx[1:0])
                2'd0: chunk_remaining[7:0]   <= input_data;
                2'd1: chunk_remaining[15:8]  <= input_data;
                2'd2: chunk_remaining[23:16] <= input_data;
                2'd3: chunk_remaining[31:24] <= input_data;
            endcase
            if (byte_idx == 4'd3) begin
                // Bit 0 of the full LE value is byte 0's LSB, already latched.
                chunk_odd <= chunk_remaining[0];
                if (is_data_chunk) begin
                    data_remaining <= {input_data, chunk_remaining[23:0]};
                    data_bytes     <= {input_data, chunk_remaining[23:0]};
                    metadata_valid <= format_valid;
                    if (!format_valid) begin
                        format_error <= 1'b1;
                        state        <= DONE;
                    end else begin
                        state <= ({input_data, chunk_remaining[23:0]} == 32'd0) ? DONE : SAMPLE_LO;
                    end
                    byte_idx <= 4'd0;
                end else begin
                    fmt_size       <= {input_data, chunk_remaining[23:0]};
                    chunk_position <= 0;
                    state          <= ({input_data, chunk_remaining[23:0]} == 32'd0) ? CHUNK_ID
                                                                                      : SKIP_CHUNK;
                end
            end else begin
                byte_idx <= byte_idx + 4'd1;
            end
        end

        SKIP_CHUNK: if (input_valid) begin
            if (is_fmt_chunk) begin
                case (chunk_position)
                    0:  fmt_tag[7:0]       <= input_data;
                    1:  fmt_tag[15:8]      <= input_data;
                    2:  fmt_channels[7:0]  <= input_data;
                    3:  fmt_channels[15:8] <= input_data;
                    4:  fmt_rate[7:0]      <= input_data;
                    5:  fmt_rate[15:8]     <= input_data;
                    6:  fmt_rate[23:16]    <= input_data;
                    7:  fmt_rate[31:24]    <= input_data;
                    12: fmt_align[7:0]     <= input_data;
                    13: fmt_align[15:8]    <= input_data;
                    14: fmt_bits[7:0]      <= input_data;
                    15: fmt_bits[15:8]     <= input_data;
                endcase
                chunk_position <= chunk_position + 1'b1;
            end
            if (chunk_remaining == 32'd1) begin
                state           <= is_fmt_chunk ? VALIDATE_FMT : (chunk_odd ? SKIP_CHUNK : CHUNK_ID);
                chunk_remaining <= chunk_odd ? 32'd1 : 32'd0;
                if (!is_fmt_chunk) chunk_odd <= 1'b0;   // the single pad byte
                byte_idx        <= 4'd0;
            end else begin
                chunk_remaining <= chunk_remaining - 32'd1;
            end
        end

        // Accept 1..MAX_CHANNELS channels of 16-bit PCM. fmt_align is the block
        // align, so it must equal channels*2; requiring that catches a header
        // that disagrees with itself. Any sane rate is accepted -- the scope
        // measures its own sample interval rather than assuming one.
        VALIDATE_FMT: begin
            sample_rate <= fmt_rate;
            if (fmt_size >= 16 && fmt_tag == 1 &&
                fmt_channels >= 1 && fmt_channels <= MAX_CHANNELS &&
                fmt_align == (fmt_channels << 1) && fmt_bits == 16 &&
                fmt_rate >= 8000 && fmt_rate <= 192000) begin
                format_valid <= 1'b1;
                format_error <= 1'b0;
                channels     <= fmt_channels[2:0];
                frame_bytes  <= {1'b0, fmt_channels[2:0], 1'b0};
            end else begin
                format_valid <= 1'b0;
                format_error <= 1'b1;
            end
            state           <= chunk_odd ? SKIP_CHUNK : CHUNK_ID;
            chunk_remaining <= chunk_odd ? 32'd1 : 32'd0;
            chunk_odd       <= 1'b0;
            byte_idx        <= 4'd0;
            if (chunk_odd) chunk_id <= 32'd0;
        end

        SAMPLE_LO: if (input_valid) begin
            sample_lo <= input_data;
            state     <= SAMPLE_HI;
        end

        SAMPLE_HI: if (input_valid) begin
            frame_r[ch_index] <= {input_data, sample_lo};
            if (ch_index == channels - 3'd1) begin
                ch_index <= 3'd0;
                state    <= EMIT;
            end else begin
                ch_index <= ch_index + 3'd1;
                state    <= SAMPLE_LO;
            end
        end

        EMIT: if (pcm_ready) begin
            data_remaining <= data_remaining - frame_bytes32;
            state <= (data_remaining == frame_bytes32) ? DONE : SAMPLE_LO;
        end

        DONE: ;   // nothing more to stream for this file

        default: state <= SKIP_HEADER;
        endcase
    end
end

endmodule
