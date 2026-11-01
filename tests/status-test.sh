#!/usr/bin/env bash
# tests/status-test.sh — status.sh's <drive>.json through a run, without a
# drive: phases, the progress ticker mid-remux, the outcome, valid JSON.
#
# dvdrip with a slow fake ffmpeg that writes -progress lines like the real
# one, sampled while it runs; plus a decision left unanswered and a datarip.
# Run: bash tests/status-test.sh   (needs python3 for the JSON check)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/remote" "$tmp/disc"
real_rsync=$(command -v rsync)

cat > "$tmp/bin/lsdvd" <<'S'
#!/usr/bin/env bash
cat "$FAKE_LSDVD"
S
# 6 s of "remuxing": out_time_us climbs 10 min a second, of a 2 h title.
cat > "$tmp/bin/ffmpeg" <<'S'
#!/usr/bin/env bash
prog=""; while (( $# > 1 )); do [[ $1 == -progress ]] && prog=$2; shift; done
for m in 10 20 30 40 50 60; do
  printf 'out_time_us=%d\nprogress=continue\n' $((m * 60 * 1000000)) >> "$prog"; sleep 1
done
echo film > "$1"
S
printf '#!/bin/sh\n:\n' > "$tmp/bin/eject"
printf '#!/bin/sh\n:\n' > "$tmp/bin/fleet-notify"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/mediagrab-ask"   # dismissed
cat > "$tmp/bin/rsync" <<S
#!/usr/bin/env bash
a=(); for x in "\$@"; do a+=("\${x/#fake:/$tmp/remote}"); done
exec $real_rsync "\${a[@]}"
S
chmod +x "$tmp/bin"/*

export MEDIAGRAB_INHIBITED=1 PATH="$tmp/bin:$PATH" DVDRIP_STATE="$tmp/state"
export DVDRIP_MOVIES=fake:/movies DVDRIP_SHOWS=fake:/shows MEDIAGRAB_STATUS="$tmp/status"
json=$tmp/status/sr9.json

pass=0 fail=0
check() {  # check <desc> <condition...>
  if "${@:2}"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; cat "$json" 2>/dev/null; fi
}
field() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print("" if v is None else v)' "$json" "$1"; }
is() { [[ $(field "$1") == "$2" ]]; }
between() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))["progress"]; sys.exit(not (v is not None and float(sys.argv[2]) < v < float(sys.argv[3])))' "$json" "$1" "$2"; }

printf 'Disc Title: THE_MATRIX_WS\nTitle: 01, Length: 02:00:00.000 Chapters: 08\n' > "$tmp/lsdvd"
FAKE_LSDVD=$tmp/lsdvd bash "$here/dvdrip.sh" /dev/sr9 >/dev/null 2>&1 &
pid=$!
sleep 3.5
check "mid-rip: phase ripping"            is phase ripping
check "mid-rip: kind dvd, disc named"     bash -c "[[ \$(python3 -I -c 'import json;d=json.load(open(\"$json\"));print(d[\"kind\"],d[\"disc\"])') == 'dvd The Matrix' ]]"
check "mid-rip: progress from out_time"   between 0.05 0.60
check "mid-rip: step shows the time"      bash -c "python3 -I -c 'import json;print(json.load(open(\"$json\"))[\"step\"])' | grep -q ' of 2:00:00'"
check "mid-rip: pid is the run"           is pid "$pid"
wait "$pid" || true
check "after: phase done"                 is phase done
check "after: progress cleared"           is progress ""
check "after: message is the outcome"     bash -c "python3 -I -c 'import json;print(json.load(open(\"$json\"))[\"message\"])' | grep -q 'ripped movie \"The Matrix\"'"
check "no ticker left behind"             bash -c "! pgrep -f '[d]vdrip.sh /dev/sr9' >/dev/null"

printf 'Disc Title: DVD_VIDEO\nTitle: 01, Length: 01:40:00.000 Chapters: 08\n' > "$tmp/lsdvd"
FAKE_LSDVD=$tmp/lsdvd bash "$here/dvdrip.sh" /dev/sr9 >/dev/null 2>&1 || true
check "dismissed question: not left 'waiting'" is phase note
check "dismissed question: says so"       bash -c "python3 -I -c 'import json;print(json.load(open(\"$json\"))[\"message\"])' | grep -q 'undecided'"

# A quote, a backslash and a tab in a label must still make valid JSON.
dev=/dev/sr9 bash -c 'source "$1/status.sh"; status_new data; status disc="$(printf "a \"q\" \\\\ b\tc")"' _ "$here"
check "escaping: still valid JSON"        is disc 'a "q" \ b c'
check "escaping: started is a number"     bash -c "[[ \$(python3 -I -c 'import json;print(type(json.load(open(\"$json\"))[\"started\"]).__name__)') == int ]]"

echo "$pass passed, $fail failed"
(( fail == 0 ))
