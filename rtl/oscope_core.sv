//============================================================================
// oscope_core.sv -- MiSTer core shell for the Occiliscope port
//
// This is the "emu" module that the MiSTer framework's sys_top.v instantiates.
// It wires the ported Occiliscope RTL (rtl/oscilloscope.vhd and friends) onto
// the MiSTer platform:
//
//   * clock:    the scope's whole pipeline runs at 50 MHz with an internal
//               25 MHz pixel enable, which is what MiSTer wants too. CLK_VIDEO
//               is therefore CLK_50M and CE_PIXEL is the scope's own pixel
//               enable (exported as VGA_CE). No PLL yet.
//   * video:    scope_vga.v still generates real 640x480@60 VGA timing; the
//               framework's scaler turns VGA_HS/VS/DE + RGB into HDMI/analog.
//               4-bit-per-channel scope colour is padded to the framework's 8.
//   * ADC:      rtl/slide_adc.sv is a SYNTHETIC stand-in (see its header). No
//               analog input exists in this build, so ADC_BUS is left tri-state
//               and the dummy drives the capture path itself. Swapping in the
//               real LTC2308 controller (sys/ltc2308.sv) is a single-module
//               change behind that same interface.
//   * controls: NOT WIRED YET. KEY/SW are held inactive and the seven-segment
//               outputs are left open; the scope's manual-mode and focus-channel
//               controls are the next milestone (OSD + gamepad via hps_io).
//   * UART:     routed to the framework's UART_TXD/UART_RXD, which MiSTer
//               exposes over the user port / USB serial. Making the phone page
//               talk to it needs the hps_io uart_mode/uart_speed handshake
//               (see sys/hps_io.sv), still to do.
//============================================================================
module emu
(
	`include "sys/emu_ports.vh"
);

///////////////////////   Tie off what this core does not use   /////////////

// No analog input in this build: slide_adc is synthetic. (When the real
// LTC2308 controller lands, ADC_BUS is driven from hps_io/ltc2308 instead.)
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;

// Serial is not wired in this milestone. hps_io carries only UART *flags*
// (uart_mode/uart_speed), not the data lines -- the scope's UART reaches the
// outside world over the user port, which is the next milestone. Until then
// the framework's UART pins are held idle.
assign {UART_RTS, UART_TXD, UART_DTR} = 0;

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE,
        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS,
        SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign {DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE, DDRAM_BURSTCNT} = '0;
assign DDRAM_CLK = clk_sys;

// Video: the scope drives all of these for real.
assign VGA_F1      = 0;
assign VGA_SL      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// No audio in the scope.
assign {AUDIO_L, AUDIO_R} = 0;
assign AUDIO_S   = 1'b1;
assign AUDIO_MIX = 2'd0;

assign LED_USER  = 1'b0;
assign LED_DISK  = 2'b00;
assign LED_POWER = 2'b00;
assign BUTTONS   = 2'b00;

// NOTE: this project vendors the STOCK MiSTer framework (sys/ from
// MiSTer-devel/Template_MiSTer), not a media-player-flavoured fork, so there
// is no PLAYER_*/MEDIA_* port subset to tie off here.

///////////////////////   Clocks and reset   /////////////////////////////////

assign CLK_VIDEO = clk_video_pll;
assign CE_PIXEL  = vga_ce;

// Reset asserts asynchronously and releases synchronously, per MiSTer
// convention (HPS status[0] and the OSD button both reset the core).
wire reset_raw = RESET | status[0] | buttons[1];
reg [1:0] reset_sync = 2'b11;
always @(posedge clk_sys or posedge reset_raw)
	if (reset_raw) reset_sync <= 2'b11;
	else reset_sync <= {reset_sync[0], 1'b0};
wire reset = reset_sync[1];

// Cyclone V's clock-select blocks (sys_top.v's vga_clk_sw / hdmi_clk_sw)
// require CLK_VIDEO to come from a PLL output, not a raw clock pin -- a fitter
// constraint, hit here as a real quartus_map error before this PLL was added.
// The reference is the 50 MHz board clock and every output is 50 MHz, which is
// exactly the rate the scope's timing assumes.
wire clk_sys, clk_video_pll, pll_locked;
pll pll
(
	.refclk(CLK_50M), .rst(1'b0),
	.outclk_0(clk_sys), .outclk_1(clk_video_pll),
	.outclk_2(), .outclk_3(), .locked(pll_locked)
);

///////////////////////   Framework HPS I/O   ////////////////////////////////

wire [1:0]  buttons;
wire [31:0] status;
wire        forced_scandoubler;
wire [24:0] ps2_mouse;
wire [10:0] ps2_key;

// OSD. Labels are chosen so the OSD's zero state (a fresh config, before
// MiSTer has saved anything) lands on the scope's own defaults: Auto trigger,
// no averaging, stabilized, grid shown. Hence two inverted entries -- "Live
// mode" and "Hide grid" -- where an unchecked box is the better default.
//
// S0 declares the file browser entry; WAV is the 3-character extension match
// the OSD parses in fixed chunks.
localparam CONF_STR = {
	"Oscope;;",
	"S0,WAV,Load Waveform;",
	"-;",
	"O[2:1],Trigger,Auto,Rising,Falling,Free;",
	"O[4:3],Averaging,X1,X4,X16,X64;",
	"-;",
	"T5,Live mode (minimum latency);",
	"T6,Hide grid;",
	"T7,Manual mode (all channels, free-run);",
	"-;",
	"R0,Reset scope settings;"
};

// WIDE(1) is what makes the virtual-SD buffer 16-bit wide; the block reader
// is written against a 13-bit address and 16-bit data. VDNUM(1) matches.
hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.forced_scandoubler(forced_scandoubler),

	// Configuration for the user-port serial the phone link will use.
	.uart_mode(uart_mode),
	.uart_speed(uart_speed),

	// Virtual SD card: the OSD file browser hands us a WAV as a disk image.
	.img_mounted(img_mounted), .img_size(img_size),
	.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd), .sd_wr(1'b0), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
	.ioctl_wait(1'b0)
);

///////////////////////   WAV streaming from SD   ///////////////////////////
//
// OSD file browser -> media_file_reader (SD blocks) -> wav_decoder (RIFF) ->
// wav_source's elastic FIFO -> slide_adc's mux -> the scope's acquisition.
//
// The reader only honours `start` while it is already idle, so opening a file
// means cancel, wait for idle, then pulse start once -- otherwise a start
// arriving mid-transfer is silently dropped and the previous file keeps
// streaming. The same sequence loops the file: when the reader goes idle the
// whole file has been delivered, so start it again.

wire [0:0]  img_mounted;
wire [63:0] img_size;
wire [31:0] sd_lba      [0:0];
wire [5:0]  sd_blk_cnt  [0:0];
wire [0:0]  sd_rd, sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din [0:0];
wire        sd_buff_wr;

assign sd_buff_din[0] = 16'd0;      // never write back to the virtual disk

reg [63:0] file_size_q, file_base_q;
reg        reader_start, reader_cancel;
wire       reader_idle;
wire [8:0] stream_data;
wire       stream_valid;
wire [63:0] reader_byte_position;

media_file_reader reader (
	.clk(clk_sys), .reset(reset),
	.start(reader_start), .cancel(reader_cancel), .suspend(1'b0),
	.file_size(file_size_q), .file_base(file_base_q), .start_offset(64'd0),
	.sd_lba(sd_lba[0]), .sd_blk_cnt(sd_blk_cnt[0]), .sd_rd(sd_rd[0]),
	.sd_ack(sd_ack[0]), .sd_buff_wr(sd_buff_wr),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.stream_data(stream_data), .stream_valid(stream_valid),
	.stream_ready(wav_stream_ready),
	.idle(reader_idle), .byte_position(reader_byte_position),
	.requests(), .completions(), .max_wait(), .error()
);

// In END_FILE the reader presents an end marker: stream_data[8] set, low byte
// zero. The decoder must not eat that as a sample, but the reader still needs
// its ready to finish the transfer -- so the marker is acknowledged while the
// byte is withheld.
wire wav_byte_eof     = stream_data[8];
wire wav_in_valid     = stream_valid && !wav_byte_eof;
wire wav_in_ready;
wire wav_stream_ready = wav_byte_eof ? 1'b1 : wav_in_ready;

reg  wav_decoder_reset_r;
wire wav_decoder_reset = reset | wav_decoder_reset_r;

wire        wav_pcm_valid, wav_pcm_eof;
wire [2:0]  wav_pcm_channels;
wire [95:0] wav_pcm_frame;
wire [31:0] wav_sample_rate, wav_data_bytes;
wire        wav_format_valid, wav_format_error, wav_metadata_valid;

wav_decoder wav_dec (
	.clk(clk_sys), .reset(wav_decoder_reset),
	.input_data(stream_data[7:0]), .input_valid(wav_in_valid),
	.input_ready(wav_in_ready),
	.pcm_valid(wav_pcm_valid), .pcm_eof(wav_pcm_eof),
	.pcm_ready(wav_frame_ready),
	.pcm_channels(wav_pcm_channels), .pcm_frame(wav_pcm_frame),
	.sample_rate(wav_sample_rate), .data_bytes(wav_data_bytes),
	.metadata_valid(wav_metadata_valid),
	.format_valid(wav_format_valid), .format_error(wav_format_error)
);

wire [95:0] wav_frame_data  = wav_pcm_frame;
wire        wav_frame_wr    = wav_pcm_valid;
wire        wav_frame_ready;

// A valid WAV is loaded and playing, so it is the source. Deliberately latched
// on validity rather than on the FIFO being non-empty: once a file is chosen it
// stays the source and an underrun blanks, rather than the display silently
// flipping back to the synthetic triangle mid-file.
wire wav_ok = (file_size_q != 64'd0) && wav_format_valid && !wav_format_error;

reg       img_mounted_d;
wire      new_file = img_mounted[0] && !img_mounted_d;

localparam [2:0] OPEN_IDLE=3'd0, OPEN_CANCEL=3'd1, OPEN_START=3'd2, OPEN_WAIT=3'd3, OPEN_RUN=3'd4;

reg [2:0] open_state_r;

wire [7:0]  uart_mode;
wire [31:0] uart_speed;

///////////////////////   QWERTY control   /////////////////////////////////
//
// Keys do not drive the scope directly. The scope's whole control surface is a
// byte parser for the phone's UART protocol, so the keyboard is implemented as
// a second client on that protocol: oscope_keys decodes scancodes,
// oscope_ctrl_frames emits the frames the Pico would send, and the bytes are
// muxed into the parser inside oscilloscope.vhd. No upstream control logic is
// duplicated, and the phone link still works unchanged.

wire        k_shift;
wire        k_vpos_up, k_vpos_down, k_vscale_up, k_vscale_down;
wire        k_tb_faster, k_tb_slower, k_trigpos_next, k_trigpos_prev;
wire        k_trig_up, k_trig_down;
wire [5:0]  k_ch_toggle;
wire        k_focus_next, k_focus_prev;
wire        k_run_toggle, k_single_shot;
wire        k_cal_up, k_cal_down;

oscope_keys keys (
	.clk(clk_sys), .reset(reset), .osd_open(OSD_STATUS), .ps2_key(ps2_key),
	.shift(k_shift),
	.vpos_up(k_vpos_up), .vpos_down(k_vpos_down),
	.vscale_up(k_vscale_up), .vscale_down(k_vscale_down),
	.tb_faster(k_tb_faster), .tb_slower(k_tb_slower),
	.trigpos_next(k_trigpos_next), .trigpos_prev(k_trigpos_prev),
	.trig_up(k_trig_up), .trig_down(k_trig_down),
	.ch_toggle(k_ch_toggle), .focus_next(k_focus_next), .focus_prev(k_focus_prev),
	.run_toggle(k_run_toggle), .single_shot(k_single_shot),
	.cal_up(k_cal_up), .cal_down(k_cal_down)
);

wire [7:0] ctrl_byte;
wire       ctrl_valid;
wire       ctrl_busy;
wire [2:0] scan_channels;   // how many channels the scope is scanning

oscope_ctrl_frames ctrl_frames (
	.clk(clk_sys), .reset(reset), .busy(ctrl_busy), .status(status[6:0]),
	.shift(k_shift),
	.vpos_up(k_vpos_up), .vpos_down(k_vpos_down),
	.vscale_up(k_vscale_up), .vscale_down(k_vscale_down),
	.tb_faster(k_tb_faster), .tb_slower(k_tb_slower),
	.trigpos_next(k_trigpos_next), .trigpos_prev(k_trigpos_prev),
	.trig_up(k_trig_up), .trig_down(k_trig_down),
	.ch_toggle(k_ch_toggle), .focus_next(k_focus_next), .focus_prev(k_focus_prev),
	.run_toggle(k_run_toggle), .single_shot(k_single_shot),
	.cal_up(k_cal_up), .cal_down(k_cal_down),
	.ctrl_byte(ctrl_byte), .ctrl_valid(ctrl_valid),
	.channel_count(scan_channels)
);

///////////////////////   File open / loop   ////////////////////////////////

always @(posedge clk_sys) begin
	img_mounted_d <= img_mounted[0];

	if (reset) begin
		file_size_q        <= 64'd0;
		file_base_q        <= 64'd0;
		reader_start       <= 1'b0;
		reader_cancel      <= 1'b0;
		wav_decoder_reset_r<= 1'b0;
		open_state_r       <= OPEN_IDLE;
	end
	else begin
		reader_start       <= 1'b0;   // every start is a one-cycle pulse
		wav_decoder_reset_r<= 1'b0;

		case (open_state_r)
		OPEN_IDLE:
			if (new_file) begin
				file_size_q   <= img_size;
				file_base_q   <= 64'd0;
				reader_cancel <= 1'b1;
				open_state_r  <= OPEN_CANCEL;
			end
		OPEN_CANCEL:
			if (reader_idle) begin
				reader_cancel <= 1'b0;
				open_state_r  <= OPEN_START;
			end
		OPEN_START: begin
			reader_start       <= 1'b1;
			wav_decoder_reset_r<= 1'b1;   // re-parse the header
			open_state_r       <= OPEN_WAIT;
		end
		// Wait for the reader to actually leave idle before watching for it to
		// finish, or it looks finished immediately and start is re-issued.
		OPEN_WAIT:
			if (!reader_idle) open_state_r <= OPEN_RUN;
		OPEN_RUN:
			if (reader_idle) begin        // whole file delivered: loop it
				reader_start       <= 1'b1;
				wav_decoder_reset_r<= 1'b1;
				open_state_r       <= OPEN_WAIT;
			end
		default: open_state_r <= OPEN_IDLE;
		endcase
	end
end

///////////////////////   The ported scope   /////////////////////////////////

wire [3:0] vga_r4, vga_g4, vga_b4;
wire       vga_hs, vga_vs, vga_de, vga_ce;

oscilloscope oscope
(
	.MAX10_CLK1_50 (clk_sys),

	// No physical switches on MiSTer. SW0 is the scope's manual-mode switch and
	// is driven from the OSD, where it belongs: manual mode silently overrides
	// channel selection and trigger settings, so an accidental keypress would
	// lose the setup. SW8 is unused upstream. SW9 is the scope's own reset --
	// previously tied low, which left it with no reset at all.
	.KEY           (2'b11),
	.SW0           (status[7]),
	.SW8           (1'b0),
	.SW9           (RESET),

	// Seven-segment bank has no MiSTer equivalent; readouts move to the OSD.
	.LEDR          (),
	.HEX0          (),
	.HEX1          (),
	.HEX2          (),
	.HEX3          (),
	.HEX4          (),
	.HEX5          (),

	.VGA_R         (vga_r4),
	.VGA_G         (vga_g4),
	.VGA_B         (vga_b4),
	.VGA_HS        (vga_hs),
	.VGA_VS        (vga_vs),
	.VGA_DE        (vga_de),
	.VGA_CE        (vga_ce),

	// Serial and the two square-wave outputs reach the extension header in a
	// later milestone (user port). Left open deliberately for now.
	.UART_TX_PIN   (),
	.UART_RX_PIN   (1'b1),   // idle high
	.GEN_GPIO28    (),
	.GEN_GPIO30    (),

	// Keyboard control bytes, muxed into the scope's protocol parser.
	.EXT_CTRL_BYTE (ctrl_byte),
	.EXT_CTRL_VALID(ctrl_valid),
	.EXT_CTRL_BUSY (ctrl_busy),

	// WAV sample source.
	.WAV_FRAME_WR    (wav_frame_wr),
	.WAV_FRAME_DATA  (wav_frame_data),
	.WAV_FRAME_READY (wav_frame_ready),
	.WAV_SAMPLE_RATE (wav_sample_rate),
	.WAV_FILE_CH     (wav_pcm_channels),
	.WAV_SCAN_CH     (scan_channels),
	.WAV_RUNNING     (wav_ok)
);

// 4 bits per channel in the scope, 8 in the framework: replicate the nibble.
assign VGA_R = {vga_r4, vga_r4};
assign VGA_G = {vga_g4, vga_g4};
assign VGA_B = {vga_b4, vga_b4};
assign VGA_HS = vga_hs;
assign VGA_VS = vga_vs;
assign VGA_DE = vga_de;

// 640x480 is 4:3.
assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;

endmodule
