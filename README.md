# mister_oscope

A port of [phase0noise/Occiliscope](https://github.com/phase0noise/Occiliscope)
-- a six-channel FPGA oscilloscope -- to the **MiSTer** platform (DE10-Nano,
Cyclone V SE `5CSEBA6U23I7`).

The upstream project runs on a DE10-Lite and does its sampling with the MAX 10's
integrated ADC. MiSTer has no such block, but the DE10-Nano carries an **LTC2308**
(8-channel, 12-bit, ~500 ksps, SPI), and the MiSTer framework already ships a
controller for it (`sys/ltc2308.sv`). The port therefore keeps the entire
acquisition, trigger, FFT, VGA and telemetry stack and replaces only the ADC
bridge.

## Status: milestone 1 -- scaffolding and a synthetic signal source

**There is no analog input in this build.** `rtl/slide_adc.sv` is a synthetic
stand-in for upstream's `rtl/slide_adc.v` (the one file that instantiated the
MAX 10 modular-ADC IP). It presents an identical interface, so the capture,
averaging, clock-crossing, trigger, FFT and VGA paths all run unchanged and the
core displays a live, moving waveform with nothing connected.

Waveform, and what each piece verifies, are in the module header.

Done:

- MiSTer project skeleton (`sys/` framework vendored, Quartus project, SDC)
- Upstream RTL ported, with two small video-interface additions (below)
- Synthetic ADC stand-in plus a contract testbench
- MiSTer core shell (`rtl/oscope_core.sv`, module `emu`) wiring clocks, video
  and hps_io

Not done yet:

- **Controls.** No switches or buttons are wired: `KEY`/`SW` are held inactive
  and the seven-segment outputs are left open. The scope's manual-mode and
  focus-channel controls belong on the OSD and gamepad, via `hps_io`.
- **Real ADC.** The LTC2308 controller is not instantiated. See below.
- **Phone / browser UI.** The scope's UART is routed to the framework's
  UART_TXD/RXD, but hps_io's user-port UART handshake (`uart_mode`,
  `uart_speed`) is not set up, so the upstream Pico W + web page is inert.

## Upstream bug found and fixed: AVG always reads ~0

First hardware run, the on-screen status bar read **MAX 3.73 V** and **P-P 2.48 V**
-- both correct for the synthetic source -- while **AVG sat at 0.00-0.01 V**
when it should have read ~2.49 V.

Cause, in upstream `scope_vga.v` (their line 528; the code arrived here verbatim):

```verilog
measure_average <= (measure_final_sum * 9'd455 + 18'd131072) >> 18;
```

`455/2^18 ~= 1/576`, the 576-column mean -- the intent is right. But
`measure_final_sum` is 22 bits, so Verilog evaluates the multiply in a **22-bit
context**. `576 x 2048 x 455` needs 30 bits, so it wraps and `>> 18` yields the
truncation residue: approximately zero for essentially any input.

Reproduced in simulation, then fixed by giving the literal the context width:

| sum (576 columns) | as shipped | `32'd455` | true mean |
| --- | --- | --- | --- |
| 576 x 2048 | 0 | 2048 | 2048 |
| 576 x 4095 | 15 | 4095 | 4096 |
| 576 x 64 | 0 | 64 | 64 |

`30'd455` also works, but the worst-case product clears 2^30 by only 260k, so
`32` is the safe literal. Fixed here; **this is worth reporting upstream.**

The `NOW`/`MAX`/`P-P` readouts use the same pattern but with a correctly sized
28-bit target, which is why they were always right.

## Changes to upstream RTL

Only `rtl/scope_vga.v` and `rtl/oscilloscope.vhd` differ, and only to expose
MiSTer's video interface:

- `scope_vga.v` gains `VGA_DE` (data enable) and `VGA_CE` (pixel clock enable).
  The renderer already ran its 640x480 pipeline on an internal 25 MHz pixel
  enable inside a 50 MHz clock; `VGA_CE` exports that enable, pipelined three
  deep to line up with the RGB outputs, and `VGA_DE` marks the active window.
- `oscilloscope.vhd` threads those two signals to its top-level ports.

Everything else is upstream code as-is.

## Clocks

The scope's design already runs a 50 MHz system clock with an alternating
25 MHz pixel enable -- exactly MiSTer's model -- so the core runs at 50 MHz and
`CE_PIXEL` is the scope's own pixel enable.

A PLL is required anyway, for a platform reason rather than a design one:
Cyclone V's clock-select blocks in `sys_top.v` (`vga_clk_sw`, `hdmi_clk_sw`)
require `CLK_VIDEO` to be driven by a PLL output, not a raw clock pin. Driving
it from `CLK_50M` fails `quartus_map` with `Error (15836)`. `rtl/pll.v` is
retuned from the author's other MiSTer core (same board and chip) to emit
50 MHz on all four outputs.

## Build result (verified)

Quartus Prime 17.0.2 Lite, target `5CSEBA6U23I7`:

- Analysis & synthesis, fitter, assembler and TimeQuest: **0 errors**
- `output_files/mister_oscope.rbf` produced
- Timing closes: worst setup slack **+0.528 ns**, in the framework's HDMI
  scaler (`ascal`) as always, not in the ported scope. The scope's own 50 MHz
  domain reports **133.56 MHz** Fmax.
- Resources: 15,370 / 41,910 ALMs (37%), 33 / 112 DSP blocks (29%),
  912,641 / 5,662,720 block memory bits (16%)

### Why the resource numbers moved so much -- and what it taught us

An earlier build of this core reported 8,938 ALMs and 70 DSP blocks. That
figure was an **artifact**. `UART_RX_PIN` is tied high in `oscope_core.sv`, so
the UART could never deliver a byte, so the control parser could never commit a
frame, so `adc_full_scale_mv` never left its reset value of 5000 -- and Quartus
constant-folded the entire control path, turning every `* render_full_scale_mv`
multiply into a constant shift-add. Most of the display logic had nothing live
to do.

The proof is a one-bit change. With the keyboard injector disabled
(`EXT_CTRL_VALID` tied low, parser dead): **70 DSP, fits**. With it live:
**142 DSP, does not fit**. Same RTL otherwise.

So the port had never been verified to fit with a *working* control surface.
Cyclone V SE has 112 DSP blocks and the live design wants ~142.

**The fix is scoped to `scope_vga.v`, not the project.** That module's display
maths is multiplier-rich -- every mV conversion is a 12x16 or 16x16 multiply,
plus the axis labels and the time divisions -- and this device has far more ALM
headroom than DSP. A `(* multstyle = "logic" *)` attribute on the module moves
just those multiplies into logic: DSP 142 -> 33, ALMs 8,938 -> 15,370, and
timing still closes.

A project-wide `DSP_BLOCK_BALANCING "LOGIC ELEMENTS"` setting was tried first
and **rejected**: it also pushes the framework's `ascal` scaler into logic,
which fails timing at the HDMI pixel clock (worst slack -3.374 ns, scaler Fmax
159 -> 99 MHz). Scoping the attribute to our own module leaves the framework's
multiplies on DSPs where they belong.

**Lesson worth keeping:** a design verified only with its inputs tied off is
not verified. This one looked comfortably empty until the controls became
reachable.

## Building

Quartus Prime **17.0.2 Lite** (the device is Cyclone V SE, matching your other
MiSTer cores):

```
quartus_sh --flow compile mister_oscope
```

Output lands in `output_files/`, and `mister_oscope.rbf` is the core to copy to
the MiSTer SD card (rename as desired -- the filename is the core name in the
MiSTer menu).

## Deploying: the core's name matters

The `.rbf` basename and `CONF_STR`'s core name must agree -- both should be
`Oscope`. MiSTer's OSD file browser opens at `games/<CoreName>/`, and if the two
names disagree you get a browser that opens somewhere with none of your files in
it. (`CONF_STR` starts `"Oscope;;"`, so the file is `Oscope.rbf` or
`Oscope_<date>.rbf` in `/media/fat/_Utility/`.)

**WAV files go in `/media/fat/games/Oscope/`**, not the SD card root. That is
where the browser looks.

`tools/make_cal_wav.py` generates suitable files:

```
tools/make_cal_wav.py sine.wav --wave sine --channels 2 --rate 48000 --freq 1000
```

A WAV's channels are the scope's channels -- a 6-channel file drives six
traces -- and the amplitude is known, which is the point of the calibration
files. The core accepts 1..6 channels, 16-bit, at any rate from 8 kHz to
192 kHz.

## Synthetic-source parameters

`rtl/slide_adc.sv` takes `PERIOD` (samples per cycle) and `CH_PHASE` (per-channel
phase step). `PERIOD` matters because scope_vga's triggered record is exactly
**576 samples** (144 pretrigger + 1 + 431 posttrigger = `PLOT_WIDTH`), and a
512-sample period is 1.125 cycles per record -- it does not divide, and the
trace walks. `PERIOD` is currently **64**, which divides 576 exactly (9 cycles),
so if the walk was a period/record beat it will be gone. It must be a power of
two; the ramp is rescaled by an elaboration-time shift.

Contract test: `rtl/slide_adc_tb.sv` checks the response pacing (800 clocks),
the channel echo, the amplitude swing, and the measured period *in samples*.

## Next milestone: the real ADC

Replace `rtl/slide_adc.sv` with a bridge onto the framework's `sys/ltc2308.sv`.
The interface to satisfy is unchanged and is documented at the top of the
synthetic module plus enforced by `rtl/slide_adc_tb.sv`. Two upstream
assumptions change with real silicon: the LTC2308's full scale is ~4.1 V rather
than the MAX 10's 5 V (`adc_full_scale_mv` in `rtl/oscilloscope.vhd`), and its
~500 ksps aggregate is about half the MAX 10's ~1 Msps.
# MiSTer-Oscope
