#!/bin/sh
# Reproduce the campus-rediald speed-test measurement on this firmware.
#
# Hypothesis: the curl fallback in run_speed_test_session() kills each stream
# subprocess after SPEED_SECONDS and reads the byte-count files immediately,
# but curl itself is given --max-time SPEED_SECONDS+5 and therefore only prints
# its %{size_download} several seconds later.  The daemon therefore always
# measures 0.00 Mbps and every session stays "unverified", which is what makes
# the maintenance sweep redial forever.
#
# This script runs the exact loop shape and reads the counters twice: once at
# the same moment the daemon does, once after the downloads have really ended.
set -u

SPEED_SECONDS=${1:-3}
DEV=${2:-pppoe-wan}
DIR=/tmp/cr-spd
rm -rf "$DIR"; mkdir -p "$DIR"

src=$(ip -4 -o addr show dev "$DEV" 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')
echo "device=$DEV src=$src"
[ -n "$src" ] || { echo "NO_SRC_ADDRESS"; exit 1; }

URL="https://test.xidian.edu.cn/backend/garbage.php?r=1&ckSize=100"
echo "=== replicate daemon loop: SPEED_SECONDS=$SPEED_SECONDS, curl --max-time $((SPEED_SECONDS + 5)) ==="

pids=
for stream in 1 2 3 4 5 6; do
	(
		curl -sS -4 --interface "$src" --max-time "$((SPEED_SECONDS + 5))" \
			-o /dev/null -w '%{size_download}' "${URL}&r=$stream" 2>/dev/null
	) > "$DIR/c$stream" 2>/dev/null &
	pids="$pids $!"
done

sleep "$SPEED_SECONDS"
for p in $pids; do kill "$p" 2>/dev/null || true; done
for p in $pids; do wait "$p" 2>/dev/null || true; done

show_counts() {
	total=0
	for s in 1 2 3 4 5 6; do
		v=$(cat "$DIR/c$s" 2>/dev/null || echo 0)
		case "$v" in ''|*[!0-9]*) v=0 ;; esac
		printf '  stream%s=[%s]\n' "$s" "$v"
		total=$((total + v))
	done
	awk -v b="$total" -v s="$SPEED_SECONDS" \
		'BEGIN { printf "  TOTAL=%d bytes -> %.2f Mbps\n", b, b * 8 / s / 1000000 }'
}

echo "--- A) counts read IMMEDIATELY after kill (what the daemon does) ---"
show_counts
echo "surviving curl children now: $(ps w 2>/dev/null | grep -c '[c]url')"

echo "--- waiting 7s for the orphaned downloads to finish and flush -w ---"
sleep 7
echo "--- B) counts read AFTER the downloads really ended ---"
show_counts
echo "surviving curl children now: $(ps w 2>/dev/null | grep -c '[c]url')"

rm -rf "$DIR"
