#!/bin/sh
# V1: build and run the core equivalence testbench with GHDL (mcode or llvm).
#
# Usage: sim/core/run_v1.sh <upstream> <zipdir> [frames] [pause_test] [dump] [name] [-- tb options]
#   upstream    path to Dar's core (the Arcade_Galaga repository); its rtl_dar/
#               and rtl_T80/ are simulated as they are, with the changes of
#               sim/core/ref_patch.py, and ROM entities written by
#               sim/core/make_ref_proms.py from the zips
#   zipdir      folder with galaga.zip (or galagamw.zip) and namco54.zip
#   frames      frames to compare (default 800; the script inserts a coin at frame
#               400, presses 1P start at 460 and plays from 520)
#   pause_test  true/false: also run a copy of the port with random pauses (default true)
#   dump        true/false: write stream.bin and audio.bin (default true)
#   name        output folder under sim/out/ (default core)
#   tb options  more testbench generics as GHDL -g options, e.g. for a cocktail run (not
#               part of the default V1):
#               -- -gdsw_a=119 -gplayers=2 (DSWA 0x77: cabinet set to cocktail);
#               dsw_a and dsw_b are also passed to ref_patch.py
#
# GHDL: set GHDL (default ghdl). Outputs go to sim/out/<name>/ (ignored by git).
set -e
[ $# -ge 2 ] || { sed -n '4,22p' "$0"; exit 1; }
UP=$(cd "$1" && pwd)
ZIPS=$(cd "$2" && pwd)
shift 2
FRAMES=800 PAUSE=true DUMP=true NAME=core
for v in FRAMES PAUSE DUMP NAME; do
	[ $# -gt 0 ] && [ "$1" != "--" ] || break
	eval "$v=\$1"
	shift
done
[ "${1:-}" = "--" ] && shift
GHDL=${GHDL:-ghdl}

DSWA=F7
DSWB=97
for o in "$@"; do
	case "$o" in
		-gdsw_a=*) DSWA=$(printf '%02X' "${o#-gdsw_a=}") ;;
		-gdsw_b=*) DSWB=$(printf '%02X' "${o#-gdsw_b=}") ;;
	esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
RTL=$HERE/../../rtl
OUT=$HERE/../out/$NAME
mkdir -p "$OUT/lib"

# the port's ROM image from our MRA (md5 checked), and the reference's ROM
# entities and patched sources
python3 "$HERE/build_rom.py" "$ZIPS" "$OUT/galaga.rom"
python3 "$HERE/make_ref_proms.py" "$ZIPS" "$OUT/ref_proms"
python3 "$HERE/ref_patch.py" "$UP" "$OUT/ref_src" --dsw-a "$DSWA" --dsw-b "$DSWB"

cd "$OUT/lib"
OPTS="--std=08 -fsynopsys -frelaxed -Wno-hide"
T80="cpu/T80_Pack.vhd cpu/T80_MCode.vhd cpu/T80_ALU.vhd cpu/T80_Reg.vhd cpu/T80.vhd cpu/T80se.vhd"
REF="$(for f in $T80; do printf '%s ' "$UP/rtl_T80/${f#cpu/}"; done)
     $OUT/ref_proms/*.vhd $OUT/ref_src/gen_ram.vhd $OUT/ref_src/gen_video.vhd
     $OUT/ref_src/stars.vhd $OUT/ref_src/stars_machine.vhd $OUT/ref_src/mb88.vhd
     $OUT/ref_src/sound_machine.vhd $OUT/ref_src/galaga.vhd"
CONV="$(for f in $T80; do printf '%s ' "$RTL/$f"; done)
      $RTL/gen_ram.vhd $RTL/dpram.vhd $RTL/gen_video.vhd $RTL/stars.vhd $RTL/stars_machine.vhd
      $RTL/mb88.vhd $RTL/sound_machine.vhd $RTL/galaga.vhd"

rm -f *.cf
$GHDL -a $OPTS --work=ref $REF
$GHDL -a $OPTS --work=work $CONV $HERE/tb_v1.vhd
$GHDL -e $OPTS tb_v1
$GHDL -r $OPTS tb_v1 -gn_frames="$FRAMES" -gpause_test="$PAUSE" -gdump="$DUMP" \
	-grom_file="$OUT/galaga.rom" -gout_dir="$OUT" "$@" \
	--ieee-asserts=disable --max-stack-alloc=0 | tee "$OUT/v1_log.txt"
