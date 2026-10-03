#!/bin/sh
# Build and run every HDL bench with its real dependencies.
#
# Each bench needs more than its own module now -- slide_adc instantiates
# wav_source, for instance -- and compiling a module on its own fails quietly
# if you are not watching, which is exactly how a broken bench goes unnoticed.
set -e
cd "$(dirname "$0")/.."

IV=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
fail=0

run() {
    name=$1; shift
    printf '%-14s ' "$name"
    if ! $IV -g2012 -o "/tmp/$name.vvp" "$@" 2>/tmp/$name.err; then
        echo "COMPILE FAILED"; sed 's/^/    /' /tmp/$name.err | head -5; fail=1; return
    fi
    out=$($VVP "/tmp/$name.vvp" 2>&1) || true
    if echo "$out" | grep -q 'RESULT: PASS'; then
        echo "PASS"
    else
        echo "FAIL"; echo "$out" | grep -E 'FAIL|WATCHDOG|RESULT' | head -6 | sed 's/^/    /'
        fail=1
    fi
}

run slide_adc    rtl/slide_adc.sv    rtl/wav_source.sv tests/hdl/slide_adc_tb.sv
run wav_decoder  rtl/wav_decoder.sv  tests/hdl/wav_decoder_tb.sv
run wav_source   rtl/wav_source.sv   tests/hdl/wav_source_tb.sv
run oscope_keys  rtl/oscope_keys.sv  tests/hdl/oscope_keys_tb.sv

exit $fail
