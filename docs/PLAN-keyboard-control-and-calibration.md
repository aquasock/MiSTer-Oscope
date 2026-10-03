# Plan: QWERTY control + WAV playback as the sample source

Status: **M1-M4 landed.** See the milestone list for what is and is not built.

## Goal

1. **Live control from a QWERTY keyboard.** No gamepad -- this is a tool.
2. **Play a WAV file as the scope's input.** The user opens a `.wav` in the OSD
   while the core is running, and the file's audio channels become the scope's
   channels. A 6-channel WAV behaves like six probes; a stereo file like a
   line-out into a two-channel scope. Duration is unbounded -- play a song.

Decisions taken:

- **WAV directly from the OSD**, not a custom container. Reuse the Phosphor
  WAV path.
- **WAV channels map 1:1 to scope channels.** 5.1 is the target case.
- **No persistence.** Defaults every session.
- **OSD carries the uncommon and the dangerous settings**; the keyboard carries
  the things you twiddle while watching.
- **`mister_oscope` is its own project from here.** MiSTer-Phosphor will not be
  maintained in step, so the WAV decoder is **copied** into this tree and
  evolved freely here rather than shared.
- **No signal means no display.** On an SD stall the trace blanks, like an
  analogue scope, rather than holding a stale sample.

## The load-bearing idea: speak the author's protocol

The scope's controls are not registers -- they are a **byte parser** for the
phone's UART protocol (`oscilloscope.vhd:684`, fed by `u_uart_rx` at line 585).
Frames are validated, and channel/VGA frames must arrive three times before
they apply.

So keyboard control needs **no new control logic**. `oscope_keys.sv` decodes
keys, `oscope_ctrl_frames.sv` emits the frames the Pico would send, and those
bytes are muxed ahead of the parser. Parsing, validation, triple-send,
application: all upstream's, already exercised by the author's own testing.
The phone path keeps working -- the keyboard is simply a second client on the
same protocol.

Only upstream edit: `oscilloscope.vhd` gains `ext_ctrl_byte` / `ext_ctrl_valid`
and a mux ahead of the parser (the parser reads `rx_byte`/`rx_byte_valid`
directly, and a VHDL signal cannot have two drivers). About six lines, behind
ports, UART path untouched.

## Reuse audit: what Phosphor gives us, and what it does not

**Reusable as-is**

- `rtl/media_file_reader.sv` -- real-time SD streaming over the virtual-SD
  protocol. This is what makes unbounded playback possible at all.
- The RIFF parsing skeleton in `rtl/wav_decoder.sv`: it already latches
  `fmt_tag`, `fmt_channels`, `fmt_rate`, `fmt_align`, `fmt_bits`, and reports
  `sample_rate`, `total_samples`, `format_valid`, `format_error`.

**Not reusable as-is**

`wav_decoder.sv` is **stereo-only in both directions**:

```verilog
output wire signed [15:0] pcm_left, pcm_right;
...
if(fmt_size>=16 && fmt_tag==1 && fmt_channels==2 && fmt_align==4 &&
   fmt_bits==16 && (fmt_rate==44100||fmt_rate==48000))
```

It *parses* `fmt_channels` and then hard-rejects anything that is not 2.
A 5.1 WAV is 6 channels, 16-bit, 48 kHz -- it passes every test except that
one, and lands in `format_error`.

Generalising it is the main new RTL work in this plan: accept 1..6 channels,
deinterleave into N sample streams, and keep the header validation honest.
The existing acceptance test is the template for what "valid" means.

**Constraint to accept:** 22.05/96 kHz, 8/24-bit and float WAVs are rejected.
Fine for v1; worth an explicit, readable error rather than silence.

## Architecture

Two sub-decisions, and they cascade.

**Stream, do not buffer.** A 6-channel 48 kHz take is ~576 kB/s; a song is
hundreds of megabytes. BRAM is 5.6 Mbit total, so buffering gives about 1.4
seconds of 6-channel audio -- fine for a calibration tone, useless for music.
Streaming is what makes it behave "like line-out into a real scope", and
`media_file_reader.sv` already exists to do it.

**The file's rate becomes the scope's rate.** Rather than resample, the
player paces one frame per `1/sample_rate` and the scope consumes at that
rate. The scope already *measures* the interval between accepted samples
(`adc_interval_counter` -> `adc_sample_period`) and derives its time axis from
it, so a 44.1 or 48 kHz file gives a correct real-time axis with no new maths.

```
OSD browser -> open WAV -> media_file_reader (SD, streaming)
                              | bytes
                              v
                        wav_decoder (extended to N channels)
                              | one frame of N x s16, paced at file rate
                              v
                        elastic FIFO (absorbs SD burstiness)
                              |
                              v
  slide_adc.sv (triangle) --+--> sample source mux --> slide_adc interface
  (nothing loaded)          |                          (unchanged)
                             +-- wav_source.sv

  ps2_key --> oscope_keys.sv --> oscope_ctrl_frames.sv --> mux --> parser
```

**Channel mapping.** Scope channel `n` reads WAV channel `n`. A channel with
no corresponding WAV channel reads silence. Per-channel read pointers advance
as that channel is served, so a channel's rate falls as more channels are
enabled -- which is exactly right, because this instrument's ADC is a single
multiplexed converter. That is upstream's model and it holds for a file too.

**Loop at EOF**, with an OSD toggle. Essential for a calibration tone, harmless
for music.

## Keyboard map

Principle: **the keyboard holds what you twiddle while watching.** Everything
discrete, uncommon, or destructive lives in the OSD.

**Vertical (focus trace)**
- `W` / `S` -- vertical position up / down; `Shift` adds coarse
- `A` / `D` -- vertical scale (volts/div) down / up

**Horizontal (time)**
- `Left` / `Right` -- timebase slower / faster (X1 .. X1024)
- `Shift+Left` / `Shift+Right` -- pre-trigger position

**Trigger**
- `Up` / `Down` -- trigger level; `Shift` adds coarse

**Channels**
- `1` .. `6` -- toggle channel enable
- `Tab` / `Shift+Tab` -- next / previous focus channel
- `C` -- comparison traces

**Acquisition**
- `R` -- run / stop
- `Space` -- single shot

**Calibration**
- `[` / `]` -- full-scale mV, -10 / +10; `Shift` adds coarse

No F-keys, so nothing collides with MiSTer's F12. Note that when the OSD is
open MiSTer routes keys to the OSD, so the scope keys apply with it closed.

## OSD layout

Principle: **if you would not twiddle it, or it can ruin your session, it goes
here.** That also protects against an accidental keypress.

```
Load Waveform        (file browser: WAV)
Trigger mode         free / rising / falling / auto
Trigger position     10 / 25 / 50 / 75 %
Averaging            1 / 4 / 16 / 64
Stabilization        off / on
Grid                 off / on
Focus channel        0 - 5
Channel enable       1 - 6
Loop at EOF          off / on
-- divider --
Manual mode          off / on        (overrides channels + trigger)
Reset to defaults    --               (destructive)
```

Reasoning: trigger mode and position are discrete and set-and-forget; averaging
and stabilization are modes; loop is a mode. Manual mode overrides channel
selection and trigger, so an accidental press loses your setup -- OSD. Reset
obviously. The things left on the keyboard are the continuous ones you adjust
while watching the trace move.

## What this calibrates, honestly

With a WAV as the source there is no real voltage. `adc_full_scale_mv` still
sets the code-to-mV scaling, but it now means "what a WAV sample's full scale
represents" -- an arbitrary but consistent reference.

So the loop calibrates the **digital chain**: column mean/min/max, MAX/P-P/AVG,
the mV scaling, the rendering. Against a generated tone whose amplitude you
already know, every remaining error is the instrument's own.

It does **not** calibrate an analogue front end, because there is not one yet.
When the LTC2308 lands, a pass against a real voltage reference is still
required.

The argument for doing it now stands: a known-amplitude file would have caught
the AVG bug in seconds. Nothing in the core currently knows what "correct"
looks like.

## Milestones

- **M2 -- frames + injection. DONE.** `rtl/oscope_ctrl_frames.sv` emits the
  A6/A9/A7 frames; `oscilloscope.vhd` gained three ports and a mux that leaves
  every downstream parser use untouched. Also exposed a capacity problem that
  had been hidden -- see the README's resource section. *Verified:* Quartus
  clean, deployed, and confirmed working on hardware by the user.
- **M1 -- key decoder. DONE.** `rtl/oscope_keys.sv` decodes `ps2_key` into named
  events, tracks shift as a level, and suppresses everything while the OSD is
  open. Verified: `rtl/oscope_keys_tb.sv` drives real set-2 scancodes through 27
  assertions -- every key, shift-held variants, OSD suppression, held-key
  repeat -- all passing. `verilator -Wall` clean.
- **M2 -- frames + injection.** `rtl/oscope_ctrl_frames.sv` -> `A6`/`A9`/`A7`
  streams, triple-sent, plus the `oscilloscope.vhd` mux. *Verify:* on hardware,
  `Left`/`Right` changes the timebase and `Up`/`Down` moves the trigger level.
- **M3 -- OSD settings. DONE.** `CONF_STR` carries trigger mode, averaging,
  "Live mode", "Hide grid", "Manual mode" and a reset button; all but the reset
  are absolute values applied by `oscope_ctrl_frames`, so there is no precedence
  question with the keyboard. Manual mode drives `SW0` at the top level, where
  upstream expects it. The WAV file entry is deferred to M5: nothing consumes a
  download yet, and a file browser that does nothing is worse than none.
  *Verified:* builds and is deployed; the entries themselves are for the user to
  confirm on screen.
- **M4 -- generalise the WAV decoder to N channels. DONE.** `rtl/wav_decoder.sv`
  forked from Phosphor's and generalised: 1..MAX_CHANNELS accepted (upstream
  hard-rejected anything but stereo, so 5.1 landed in format_error), whole-frame
  output instead of pcm_left/pcm_right, any sane sample rate rather than a
  pinned 44.1/48 kHz. *Verified:* `tests/hdl/wav_decoder_tb.sv` builds synthetic
  RIFF files and checks mono, stereo, 5.1 and 3-channel/96 kHz end to end, plus
  8-channel rejection. Not yet in files.qip -- it has no caller until M5.
- **M5 -- streaming source.** `media_file_reader` + extended decoder + elastic
  FIFO + `rtl/wav_source.sv` behind the `slide_adc` interface, muxed with the
  triangle. *Verify:* TB for FIFO/underrun/loop; hardware -- open a WAV and see
  it on screen.
- **M6 -- calibration tones + loop.** `tools/make_cal_wav.py` producing
  sine/square/triangle at known amplitudes, in mono, stereo and 5.1.
  *Verify:* known amplitude reads back at the predicted mV.

M1 -> M2 -> M3. M4 is independent. M5 needs M4. M6 needs M5 and M3.

## Risks and open questions

- **SD streaming determinism.** `media_file_reader` is bursty. The elastic FIFO
  covers jitter; on a genuine underrun the trace **blanks** -- no signal, no
  display, as an analogue scope would behave. Phosphor already solved the
  pacing problem for audio; the same backpressure approach should carry over.
- **Where the generalised decoder lives.** *Decided:* copied into this tree and
  evolved here. MiSTer-Phosphor is not being maintained in step, so there is no
  shared file to keep in sync.
- **Sample-rate to timebase.** The scope's decimation (X1..X1024) now applies to
  file samples. Worth checking the X1 window still shows something sensible for
  a 48 kHz file before assuming the maths is free.
- **Hysteresis coupling.** Upstream ties the trigger hysteresis to
  `stabilize_enable` (`scope_vga.v:219`), so toggling stabilization retunes the
  trigger threshold. Worth decoupling and reporting upstream.
