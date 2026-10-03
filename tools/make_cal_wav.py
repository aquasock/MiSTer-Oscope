#!/usr/bin/env python3
"""Generate calibration WAVs for mister_oscope.

A WAV's channels ARE the scope's channels, so this emits 1..6 channel 16-bit PCM
at a known amplitude -- which is the whole point: with a file whose amplitude you
already know, any error left on screen is the instrument's own.

The core measures its own sample interval and derives the timebase from it, so
the rate here is not restricted to 44.1/48 kHz. It does have to be sane
(8 kHz .. 192 kHz).

Examples:
    make_cal_wav.py sine.wav --wave sine --channels 2 --freq 1000
    make_cal_wav.py 51.wav   --wave sine --channels 6 --per-channel-div
    make_cal_wav.py sq.wav   --wave square --channels 1 --freq 200
"""
import argparse
import math
import struct
import sys

WAVES = ("sine", "square", "triangle")


def sample(wave, phase):
    """One cycle of the waveform at `phase` in [0, 1)."""
    if wave == "sine":
        return math.sin(2.0 * math.pi * phase)
    if wave == "square":
        return 1.0 if phase < 0.5 else -1.0
    # triangle: -1 at phase 0, +1 at phase 0.5
    return 4.0 * abs(phase - 0.5) - 1.0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out")
    p.add_argument("--wave", choices=WAVES, default="sine")
    p.add_argument("--channels", type=int, default=2, help="1..6")
    p.add_argument("--rate", type=int, default=48000, help="8000..192000")
    p.add_argument("--freq", type=float, default=1000.0)
    p.add_argument("--amplitude", type=float, default=0.5,
                   help="fraction of full scale, 0..1")
    p.add_argument("--seconds", type=float, default=2.0)
    p.add_argument("--per-channel-div", action="store_true",
                   help="each channel gets freq/channel-number, so a channel is "
                        "identifiable from the trace alone")
    a = p.parse_args()

    if not 1 <= a.channels <= 6:
        sys.exit("channels must be 1..6 (the scope has six)")
    if not 8000 <= a.rate <= 192000:
        sys.exit("rate must be 8000..192000 (the core rejects the rest)")
    if not 0.0 < a.amplitude <= 1.0:
        sys.exit("amplitude must be >0 and <=1")

    frames = int(a.seconds * a.rate)
    peak   = int(a.amplitude * 32767.0)

    data = bytearray()
    phases = [0.0] * a.channels
    steps  = []
    for ch in range(a.channels):
        f = a.freq / (ch + 1) if a.per_channel_div else a.freq
        steps.append(f / a.rate)

    for _ in range(frames):
        for ch in range(a.channels):
            v = int(round(peak * sample(a.wave, phases[ch] % 1.0)))
            v = max(-32768, min(32767, v))
            data += struct.pack("<h", v)
            phases[ch] += steps[ch]

    block_align = a.channels * 2
    byte_rate   = a.rate * block_align
    riff = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    fmt  = (b"fmt " + struct.pack("<I", 16) +
            struct.pack("<HHIIHH", 1, a.channels, a.rate, byte_rate,
                        block_align, 16))
    hdr  = riff + fmt + b"data" + struct.pack("<I", len(data))

    with open(a.out, "wb") as fh:
        fh.write(hdr)
        fh.write(data)

    print(f"{a.out}: {a.wave}, {a.channels} ch, {a.rate} Hz, "
          f"{a.freq:g} Hz, {a.amplitude * 100:g}% of full scale, "
          f"{frames} frames, {len(hdr) + len(data)} bytes")
    # The core reduces 16 -> 12 bits by taking the top 12, i.e. v/16, then
    # biases to mid-scale. So the excursion in ADC codes is peak>>4 and
    # peak-to-peak in mV follows from the calibration constant.
    pp_mv = 2 * (peak >> 4) * 5000.0 / 4096.0
    print(f"  at 5000 mV full scale this should read {pp_mv:.0f} mV peak-to-peak")


if __name__ == "__main__":
    main()
