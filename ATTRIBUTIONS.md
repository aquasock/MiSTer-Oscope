# Attributions and licensing

## Occiliscope (upstream design)

- Project: https://github.com/phase0noise/Occiliscope
- Author: phase0noise (Reddit `u/cdabc123`)
- License: **the upstream repository has no LICENSE file**

The upstream author has stated publicly that the project may be reused:

> "This could be easily ported, its almost all hdl with the only ip being
> clocks and the adc. The design is abit logic heavy but could be reduced.
> Feel free to use anything, I dont really believe in copywrite or licensing
> for hobby projects."
> -- r/FPGA, https://www.reddit.com/r/FPGA/comments/1wvgw5e/

and has additionally given explicit permission to port the project. Because
there is no upstream LICENSE file, that permission is the basis for this port,
and third parties have no granted rights upstream. **This repository licenses
the port itself as GPL-3.0** (see `LICENSE`), consistent with the author's other
projects. Upstream involvement in choosing that license is worth confirming and,
ideally, worth a real LICENSE file landing upstream so others can reuse the
original safely.

## MiSTer framework

- Project: https://github.com/MiSTer-devel
- License: GNU General Public License v2.0 (`COPYING.GPL2`)

The whole of `sys/` is the standard MiSTer core framework, vendored unmodified.
It is GPL-2.0, which is why this project carries `COPYING.GPL2` alongside its
own GPL-3.0 `LICENSE`, the same arrangement used by the author's other MiSTer
cores.

## Ported RTL provenance

`rtl/oscilloscope.vhd`, `rtl/scope_capture.vhd`, `rtl/scope_fft.v`, `scope_live.v`,
`scope_vga.v`, `uart_tx.v`, `uart_rx.v`, `SEG7_LUT*.v` are upstream Occiliscope
files. `scope_vga.v` and `oscilloscope.vhd` carry the MiSTer video-interface
additions described in `README.md`; the rest are unmodified.

`rtl/slide_adc.sv` is new work for this port (a synthetic replacement for
upstream's MAX 10 ADC bridge) and is written against the same module interface.

`rtl/wav_decoder.sv` is forked from MiSTer-Phosphor's `rtl/wav_decoder.sv` (same
author, GPL-3.0) and generalised here from a fixed stereo profile to 1..6
channels with whole-frame output. mister_oscope is its own project from this
point, so this file is evolved here rather than kept in step with Phosphor; the
fork and its divergences are documented in the file's own header.
