#!/bin/bash
# build.sh <ps-recomp> <outdir> [odin flags...]: the port on a ps-recomp tree.
#   Builds recomp from <ps-recomp>, generates <outdir>/src/rec from tools/recomp.tsv,
#   copies port/src/*.odin beside it and builds <outdir>/port. Extra arguments go to
#   the port's odin build (e.g. -define:FALLBACK_COUNT=true).
#   Runs on POOL (default 4-7,12-15); refuses to start while odin runs or with <14G free.
#   Needs the VU captures named in tools/recomp.tsv (port/vu1.cap, port/vu0.cap);
#   make them as in README step 5.
set -u -o pipefail
G=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$G/../.." && pwd)
T=$(cd "$1" && pwd); mkdir -p "$2"; d=$(cd "$2" && pwd); shift 2
POOL=${POOL:-4-7,12-15}
pgrep -a odin && { echo "odin running, abort"; exit 1; }
free -g | awk 'NR==2{if($7<14){print "free",$7,"<14 abort"; exit 1}}' || exit 1
# recomp only warns on a missing vu1_capture or vu0_capture and leaves that
# microcode to the interpreter: same output, ~5x slower. So a typo'd path is an
# error here.
for k in vu1 vu0; do
	cap=$(awk -F'\t' -v k="${k}_capture" '$1==k{print $2}' "$ROOT/tools/recomp.tsv")
	case $cap in ""|/*) capf=$cap;; *) capf=$ROOT/$cap;; esac
	[ -z "$cap" ] || [ -f "$capf" ] || { echo "${k}_capture $capf: no such file"; exit 1; }
done
(cd "$T" && taskset -c "$POOL" odin build recomp -collection:ps=. -o:speed -out:"$d/recomp") 2>&1 | tail -3 || exit 1
sed "s#^out\t.*#out\t$d/src/rec#; /^native/d" "$ROOT/tools/recomp.tsv" > "$d/gen.tsv"
rm -rf "$d/src"; mkdir -p "$d/src"; cp "$ROOT"/port/src/*.odin "$d/src/"
(cd "$ROOT" && taskset -c "$POOL" "$d/recomp" "$d/gen.tsv") > "$d/recomp.log" 2>&1 || { tail -5 "$d/recomp.log"; exit 1; }
tail -3 "$d/recomp.log"
for k in VU1 VU0; do
	cap=$(awk -F'\t' -v k="${k,,}_capture" '$1==k{print $2}' "$ROOT/tools/recomp.tsv")
	n=$(sed -n "s/^\([0-9]*\) $k programs,.*/\1/p" "$d/recomp.log")
	[ -z "$cap" ] || [ "${n:-0}" -gt 0 ] || { echo "${k,,}_capture $cap: recomp compiled ${n:-no} $k programs"; exit 1; }
done
(cd "$ROOT" && taskset -c "$POOL" python3 -I "$G/tv.py" "$d/time_build" odin build "$d/src" -collection:ps="$T" \
	-define:ENV_PREFIX=GAME_ -use-separate-modules -o:speed "$@" -out:"$d/port") 2>&1 | tail -5 || exit 1
ls -la "$d/port"
