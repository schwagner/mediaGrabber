#!/usr/bin/env bash
# tests/cdrip-test.sh — cdrip's MusicBrainz outcomes and popup answers,
# without a drive.
#
# Stubs cyanrip (acts out $FAKE_MB: one/multi/none, writing real FLACs with
# the tags MusicBrainz would give), eject, fleet-notify and mediagrab-ask
# (answers with the next line of $ANSWERS), and maps rsync's "fake:" host
# to a temp dir. Needs flac/metaflac:
#   nix shell nixpkgs#flac -c bash tests/cdrip-test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/remote"
real_rsync=$(command -v rsync)

cat > "$tmp/bin/cyanrip" <<'S'
#!/usr/bin/env bash
# Records its arguments; -D <dir>, -R <n>, -N as cyanrip has them.
echo "$*" >> "$CYANRIP_CALLS"
dir="" rel="" none=0
while (( $# )); do case $1 in -D) dir=$2; shift ;; -R) rel=$2; shift ;; -N) none=1 ;; esac; shift; done
track() {  # track <file> [TAG=value]...
  head -c 17640 /dev/zero | flac -s --force-raw-format --endian=little --sign=signed \
    --channels=2 --bps=16 --sample-rate=44100 -o "$1" -
  local f=$1; shift; (( $# )) && metaflac "${@/#/--set-tag=}" "$f"; true
}
case $FAKE_MB:$rel:$none in
  multi::0)
    echo "Multiple releases found in database for DiscID xyz:"
    echo "    1 (ID: aaaa): The Sign (US) (1993-11-23)"
    echo "    2 (ID: bbbb): The Sign (GB) (1994)"
    echo "Please specify which release to use by adding the -R argument with an index or ID."
    exit 1 ;;
  none:*:0) echo "Unable to find release info for this CD, and metadata hasn't been manually added!"; exit 1 ;;
  fail:*) echo "read error"; exit 1 ;;
esac
mkdir -p "$dir"
if (( none )); then
  track "$dir/01 - Track 01.flac"; track "$dir/02 - Track 02.flac"
else
  y=1993; [[ $rel == 2 ]] && y=1994
  for n in 01 02; do
    track "$dir/$n - Song $n.flac" "ALBUM=The Sign" "ALBUMARTIST=Ace of Base" "ARTIST=Ace of Base" "DATE=$y" "TITLE=Song $n"
  done
  echo "Tracks ripped accurately: 2/2"
fi
S
cat > "$tmp/bin/mediagrab-ask" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ASKED"
a=$(head -n1 "$ANSWERS"); sed -i 1d "$ANSWERS"
[[ -n $a ]] && echo "$a"
S
printf '#!/bin/sh\necho ejected >> "$NOTES"\n' > "$tmp/bin/eject"
printf '#!/bin/sh\necho "$*" >> "$NOTES"\n' > "$tmp/bin/fleet-notify"
cat > "$tmp/bin/rsync" <<S
#!/usr/bin/env bash
a=(); for x in "\$@"; do a+=("\${x/#fake:/$tmp/remote}"); done
exec $real_rsync "\${a[@]}"
S
chmod +x "$tmp/bin"/*

export MEDIAGRAB_INHIBITED=1 PATH="$tmp/bin:$PATH" CDRIP_STATE="$tmp/state" CDRIP_DEST=fake:/music
export NOTES=$tmp/notes ANSWERS=$tmp/answers ASKED=$tmp/asked CYANRIP_CALLS=$tmp/calls

pass=0 fail=0
check() {  # check <desc> <condition...>
  if "${@:2}"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; tail -n3 "$NOTES" 2>/dev/null; fi
}
run() {  # run <musicbrainz outcome> [answers...]
  export FAKE_MB=$1; shift
  printf '%s\n' "$@" > "$ANSWERS"; : > "$NOTES"; : > "$ASKED"; : > "$CYANRIP_CALLS"
  rm -rf "$tmp/remote"/* "$tmp/state"
  bash "$here/cdrip.sh" /dev/sr9 >/dev/null 2>&1 || true
}
album=$tmp/remote/music/"Ace of Base"
sign() { metaflac --show-tag=DATE "$album/The Sign ($1)/01 - Song 01.flac" | grep -qx "DATE=$1"; }

run one
check "one release: shipped, no question"     bash -c "test -f '$album/The Sign (1993)/01 - Song 01.flac' && test ! -s '$ASKED'"
check "one release: AccurateRip in the note"  grep -q 'AccurateRip 2/2' "$NOTES"

run multi 2
check "multi: releases offered as buttons"    grep -q '2=The Sign (GB) (1994)' "$ASKED"
check "multi: button 2 -> -R 2"               sign 1994
check "multi: note says it was chosen"        grep -q 'release 2 of 2 on MusicBrainz, as chosen' "$NOTES"

run multi ""
check "multi, unanswered: the first"          sign 1993
check "multi, unanswered: note says so"       grep -q 'took the first' "$NOTES"
check "multi: asked with a timeout"           grep -q -- '--timeout 300' "$ASKED"

run multi eject
check "multi: eject -> nothing ripped"        bash -c "grep -qx ejected '$NOTES' && test \$(wc -l < '$CYANRIP_CALLS') = 1"

run none "reply Ace of Base - Happy Nation (1993)"
check "none: typed name -> tagged, shipped"   test -f "$album/Happy Nation (1993)/01 - Track 01.flac"
check "none: ALBUMARTIST set"                 bash -c "metaflac --show-tag=ALBUMARTIST '$album/Happy Nation (1993)/02 - Track 02.flac' | grep -qx 'ALBUMARTIST=Ace of Base'"

run none "reply Unknown Mix"
check "none: no ' - ' in reply -> unmatched"  bash -c "ls '$tmp/state/unmatched'/*/rip/*.flac >/dev/null && test ! -e '$tmp/remote/music'"

run none untagged
check "none: Rip untagged -> unmatched"       bash -c "ls '$tmp/state/unmatched'/*/rip/*.flac >/dev/null && grep -q cdrip-ship '$NOTES'"

run none ""
check "none, unanswered -> unmatched"         bash -c "ls '$tmp/state/unmatched'/*/rip/*.flac >/dev/null"

run fail eject
check "fail: Retry/Eject offered"             grep -q 'retry=Retry eject=Eject' "$ASKED"
check "fail: eject"                           grep -qx ejected "$NOTES"

run fail retry ""
check "fail: retry runs cyanrip again"        test "$(wc -l < "$CYANRIP_CALLS")" = 2

[[ -n ${SHOW_NOTES:-} ]] && cat "$NOTES"
echo "$pass passed, $fail failed"
(( fail == 0 ))
