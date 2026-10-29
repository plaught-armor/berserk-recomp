#!/bin/bash
# Berserk standard gate: replays tools/gate/press.txt headless and compares shots.
#   gate.sh <tier> <outdir> <bin>...      BASE=<dir with shot_*.ppm> compares shots.
#   check: shots to f10800, all bins in parallel (~0.25G RSS, 1 core each).
#          f10800 has the HUD, minimap and tutorial dialog that f12001 shows;
#          f10800-12000 runs at ~16 fps, so stopping there saves ~70 s.
#   vu:    check with GAME_VUCHECK=1, plus vucheck line count.
#   perf:  one run per bin, solo (fps needs a quiet box): check shots plus 12001,
#          GAME_STATS on, under perf stat (instructions:u, task-clock -> pstat);
#          fps/VU1% at f11700-12000 and per-program VU1 TSC (DBG vu1).
# Runs are pinned to the shared pool (POOL, default 4-7,12-15), each with its
# own copy of the memory card directory MC (required; the press script expects
# the card it was recorded with). DISC defaults to disc/ at the repository root.
# Per run: wall time and max RSS in <outdir>/<bin>/<phase>/time.
set -u
W=$(cd "$(dirname "$0")" && pwd)
D=${DISC:-$(cd "$W/../.." && pwd)/disc}
MC=${MC:?MC: memory card directory to start each run from}
PRESS=$(cat "$W/press.txt")
# 700, 900 and 1497 repeat 450 (Now Loading); 560 repeats 500.
SHOTS=300,400,450,500,520,600,1000,1600,2600,2800,3000,8201,9900,10800
POOL=${POOL:-4-7,12-15}
TIER=$1; OUT=$2; shift 2
BASE=${BASE:-}
case $TIER in check|vu|perf) ;; *) echo "tier: check|vu|perf"; exit 2;; esac
avail=$(free -g | awk '/^Mem:/{print $7}')
[ "$avail" -lt 4 ] && { echo "avail ${avail}G < 4G, not starting"; exit 2; }
run() { # bin phase env...
	local b=$1 ph=$2; shift 2
	local o=$OUT/$(basename "$b")/$ph; mkdir -p "$o"
	rm -rf "$o/mc"; cp -r "$MC" "$o/mc"
	(cd "$o" && env GAME_MC="$o/mc" GAME_HEADLESS=1 GAME_SW=1 GAME_PRESS="$PRESS" GAME_VU1_STATS=1 "$@" \
		taskset -c "$POOL" timeout 4000 python3 -I "$W/tv.py" time "${wrap[@]}" "$b" "$D" > log 2>&1; echo "$(basename "$b") $ph rc $?")
}
vc=(); [ "$TIER" = vu ] && vc=(GAME_VUCHECK=1)
wrap=(); [ "$TIER" = perf ] && wrap=(perf stat -x, -o pstat -e instructions:u,task-clock)
if [ "$TIER" = perf ]; then
	# Stats only print, so shots match a check run; one pass covers both.
	SHOTS=$SHOTS,12001
	for b in "$@"; do run "$b" perf GAME_STATS=1 GAME_SHOT=$SHOTS; done
else
	for b in "$@"; do run "$b" check GAME_SHOT=$SHOTS "${vc[@]}" & done
	wait
fi
PH=check; [ "$TIER" = perf ] && PH=perf
first=
for b in "$@"; do
	n=$(basename "$b")
	echo "== $n"
	for ph in check perf; do
		[ -f "$OUT/$n/$ph/time" ] && echo "$ph: $(head -2 "$OUT/$n/$ph/time" | sed 's/.*: //' | tr '\n' ' ')(wall s, RSS KiB)"
	done
	# Compiled VU1 programs (VU1_STATS): a miss or a low VU1 share drop means uncaptured microcode.
	awk '/^vu1 program/{n++; r+=$(NF-5); m+=$(NF-1)} END{printf "vu1: %d programs ran, %d runs, %d misses\n", n, r, m}' "$OUT/$n/$PH/log"
	[ "$TIER" = vu ] && { echo "vucheck lines: $(grep -c '^vucheck:' "$OUT/$n/check/log")"; grep -A3 '^vucheck:' "$OUT/$n/check/log" | head -20; }
	if [ -f "$OUT/$n/perf/log" ]; then
		awk -F, '/instructions/{printf "  instr %.3f G\n", $1/1e9} /task-clock/{printf "  task %.0f ms\n", $1}' "$OUT/$n/perf/pstat"
		grep "stats: frame 1[12][0-9]00 " "$OUT/$n/perf/log" | awk '$3>=11700 && $3<=12000 {print "  " $3, $4, $5, $10, $11}'
		grep "DBG vu1" "$OUT/$n/perf/log" | head -14
	fi
	# Shots against BASE, else against the first bin.
	ref=${BASE:-$first}
	if [ -n "$ref" ]; then
		d=
		for f in ${SHOTS//,/ }; do
			if [ -f "$ref/shot_$f.ppm" ]; then cmp -s "$OUT/$n/$PH/shot_$f.ppm" "$ref/shot_$f.ppm" || d="$d $f"; else d="$d $f(nobase)"; fi
		done
		echo "shots vs $ref: ${d:- all same}"
	fi
	[ -z "$first" ] && first=$OUT/$n/$PH
done
