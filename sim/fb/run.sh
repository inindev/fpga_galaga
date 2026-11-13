#!/bin/sh
# V2: frame buffer simulation with Verilator 5 (--timing).
#
#   sim/fb/run.sh [out_dir] [extra plusargs...]
#
# out_dir defaults to sim/out/fb. Verilator must be on PATH (or set VERILATOR). Extra
# arguments go to the simulation, e.g. +frames=120 +seed=7, or +stream=<stream.bin> +skip=<n>
# for the pixel stream recorded in V1 (see tb_fb.sv for the format). VFLAGS adds Verilator
# options.
# Writes out_dir/v2.log and the HDMI frames as PPM and PNG images.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/sim/out/fb}
[ $# -gt 0 ] && shift
mkdir -p "$out"
out=$(cd "$out" && pwd)
V=${VERILATOR:-verilator}

python3 "$here/fbimg.py" pattern "$out/src_img.hex"
python3 "$here/fbimg.py" srcpng "$out/src_img.hex" "$out/v2_source.png"

"$V" --binary --timing --timescale 1ps/1ps -j 0 -O3 -Wno-fatal -Wno-MULTIDRIVEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    $VFLAGS --top-module tb_fb -Mdir "$out/obj" \
    "$root/tang/nano20k/sdram.v" \
    "$root/tang/nano20k/fb_writer.sv" \
    "$root/tang/nano20k/fb_reader.sv" \
    "$root/tang/nano20k/framebuffer.sv" \
    "$here/sdram_model.sv" "$here/tb_fb.sv" > "$out/verilate.log" 2>&1 || {
    cat "$out/verilate.log"; exit 1; }

(cd "$out" && ./obj/Vtb_fb +img="$out/src_img.hex" +out="$out" "$@") | tee "$out/v2.log"

for f in "$out"/v2_*.ppm; do
    [ -e "$f" ] && python3 "$here/fbimg.py" png "$f"
done
grep -q "^V2 PASS" "$out/v2.log"
