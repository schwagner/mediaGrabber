#!/usr/bin/env bash
# tests/dvdrip-test.sh — dvdrip's decisions, without a drive.
#
# Stubs lsdvd (prints a canned title list), ffmpeg (writes the title
# number into the output file) and eject, and maps rsync's "fake:" host to
# a temp dir, then checks what lands where. Run: bash tests/dvdrip-test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/remote"
real_rsync=$(command -v rsync)

cat > "$tmp/bin/lsdvd" <<'S'
#!/usr/bin/env bash
cat "$FAKE_LSDVD"
S
cat > "$tmp/bin/ffmpeg" <<'S'
#!/usr/bin/env bash
t=""; while (( $# > 1 )); do [[ $1 == -title ]] && t=$2; shift; done
echo "title $t" > "$1"
S
printf '#!/bin/sh\n:\n' > "$tmp/bin/eject"
printf '#!/bin/sh\necho "$*" >> "$NOTES"\n' > "$tmp/bin/fleet-notify"
cat > "$tmp/bin/rsync" <<S
#!/usr/bin/env bash
a=(); for x in "\$@"; do a+=("\${x/#fake:/$tmp/remote}"); done
exec $real_rsync "\${a[@]}"
S
chmod +x "$tmp/bin"/*

export PATH="$tmp/bin:$PATH" DVDRIP_STATE="$tmp/state" NOTES="$tmp/notes"
export DVDRIP_MOVIES=fake:/movies DVDRIP_SHOWS=fake:/shows

disc() {  # disc <label> <h:mm:ss>...  -> canned lsdvd output
  echo "Disc Title: $1"; shift
  local i=1; for l in "$@"; do
    printf 'Title: %02d, Length: %s.000 Chapters: 08, Cells: 09, Audio streams: 02, Subpictures: 03\n' $i "0$l"; i=$((i+1))
  done
  echo "Longest track: 01"
}
pass=0 fail=0
check() {  # check <desc> <condition...>
  if "${@:2}"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; tail -n3 "$NOTES" 2>/dev/null; fi
}
run() { disc "$@" > "$tmp/lsdvd"; FAKE_LSDVD=$tmp/lsdvd bash "$here/dvdrip.sh" /dev/sr9 "${EXTRA[@]}" >/dev/null 2>&1 || true; }
last_note() { tail -n1 "$NOTES"; }
EXTRA=()

run THE_MATRIX_WS 2:16:03 0:03:10 0:01:30
check "movie from label, longest title" grep -qx "title 1" "$tmp/remote/movies/The Matrix/The Matrix.mkv"

run FRIENDS_S1_D2 1:28:10 0:22:01 0:22:30 0:21:58 0:22:40 0:00:40
check "tv: play-all skipped, 4 episodes"  test -f "$tmp/remote/shows/Friends/Season 01/Friends S01E04.mkv"
check "tv: E01 is title 2"                grep -qx "title 2" "$tmp/remote/shows/Friends/Season 01/Friends S01E01.mkv"
check "tv: no E05 yet"                    test ! -e "$tmp/remote/shows/Friends/Season 01/Friends S01E05.mkv"

run FRIENDS_S1_D3 0:22:10 0:22:20 0:23:00
check "tv: next disc continues at E05"    grep -qx "title 1" "$tmp/remote/shows/Friends/Season 01/Friends S01E05.mkv"
check "tv: ...through E07"                test -f "$tmp/remote/shows/Friends/Season 01/Friends S01E07.mkv"

run LOST_SEASON_3_DISC_2 0:43:00 0:42:10 0:44:05 0:41:50
check "tv: SEASON_3_DISC_2 label"         test -f "$tmp/remote/shows/Lost/Season 03/Lost S03E04.mkv"

: > "$NOTES"
run CARS 1:56:00 1:56:01 1:55:59 1:56:02 0:02:00
check "decoys -> decision, nothing ripped" bash -c "grep -q 'same length' '$NOTES' && test ! -e '$tmp/remote/movies/Cars'"

: > "$NOTES"
run DVD_VIDEO 1:40:00 0:05:00
check "generic label -> decision"         grep -q 'label tells me nothing' "$NOTES"

: > "$NOTES"
run THE_OFFICE 0:22:00 0:21:30 0:22:15
check "tv without season -> decision"     grep -q 'no season' "$NOTES"

: > "$NOTES"
run TRAILERS 0:02:00 0:03:00
check "nothing long -> decision"          grep -q 'longer than 40 min' "$NOTES"

EXTRA=(movie "Cars (2006)" 3)
run CARS 1:56:00 1:56:01 1:55:59 1:56:02
check "override: movie, chosen title"     grep -qx "title 3" "$tmp/remote/movies/Cars (2006)/Cars (2006).mkv"

EXTRA=(show "The Office (US)" 2)
run THE_OFFICE 0:22:00 0:21:30 0:22:15
check "override: show + season"           test -f "$tmp/remote/shows/The Office (US)/Season 02/The Office (US) S02E03.mkv"

[[ -n ${SHOW_NOTES:-} ]] && cat "$NOTES"
echo "$pass passed, $fail failed"
(( fail == 0 ))
