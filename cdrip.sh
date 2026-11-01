#!/usr/bin/env bash
# ============================================================
# cdrip.sh — rip the audio CD in DEVICE to FLAC and ship it to the library
#
# Usage: cdrip <device>        e.g. cdrip /dev/sr0
#
# Run by mediagrab (mediagrab@<dev>.service) when the disc has audio
# tracks. Can be run by hand with the same argument.
#
# Pipeline:
#   1. cyanrip rips to $CDRIP_STATE/staging/<stamp>/rip — paranoia,
#      AccurateRip verification, MusicBrainz tags, Cover Art Archive art
#      (embedded and as a file), a .log and a .cue.
#   2. The album folder is named from the FLAC tags, not by cyanrip's -D,
#      because cyanrip sanitises '/' and so cannot make Artist/Album paths.
#   3. rsync to $CDRIP_DEST (host:path) as Artist/Album (Year)/. Jellyfin's
#      real-time monitor picks it up; nothing has to poke its API.
#   4. Eject, and report the outcome (fleet-notify and a desktop popup).
#
# MusicBrainz outcomes, and why each is handled the way it is:
#   - one release    -> rip and ship.
#   - several        -> cyanrip refuses without -R. A popup offers the
#                       releases as buttons (mediagrab-ask); unanswered in
#                       5 min, -R 1 — the tracklist is the same disc, only
#                       country/label/date may be off — and the
#                       notification says so.
#   - none           -> a popup asks for "Artist - Album (Year)": typed, the
#                       rip is tagged with that and shipped (no track titles).
#                       "Rip untagged", or no answer in 5 min: rip untagged
#                       (-N) and keep it LOCAL in unmatched/. Untagged
#                       "Unknown Album" folders in Jellyfin are worse than a
#                       short delay; tag it with Picard and run
#                       `cdrip-ship <dir>` to send it on.
#
# A failed rip never ejects: the disc stays in the drive, and the popup
# offers Retry and Eject (or: `systemctl start mediagrab@sr0`). Every popup
# also has Eject, and goes away by itself if the disc is taken out.
# ============================================================
set -euo pipefail

state=${CDRIP_STATE:-/var/lib/cdrip}
dest=${CDRIP_DEST:?CDRIP_DEST (host:/path) is not set}
offset=${CDRIP_OFFSET:-0}

notify() {  # notify <ok|fail|note> <message> — once per run, as it ends
  local level=$1; shift
  echo "$*"
  command -v fleet-notify >/dev/null && fleet-notify "cdrip: $*" || true
  command -v mediagrab-popup >/dev/null && mediagrab-popup "$level" "$*" || true
  notified=1
}

# Whatever set -e kills before a notify still gets a popup.
crashed() {
  local rc=$?
  (( rc == 0 )) || [[ -n ${notified-} ]] ||
    notify fail "cdrip stopped unexpectedly (exit $rc) on ${dev:-the drive} — see journalctl -u 'mediagrab@*'"
}

tag() {  # tag <flac> <name>... — first non-empty of the named tags
  local f=$1 v; shift
  for t in "$@"; do
    v=$(metaflac --show-tag="$t" "$f" | head -n1 | cut -d= -f2-)
    [[ -n $v ]] && { printf '%s' "$v"; return; }
  done
}

clean() {  # make a tag safe as one path component
  printf '%s' "$1" | tr '/\\:*?"<>|' '_________' | sed 's/^[. ]*//; s/[. ]*$//'
}

ship() {  # ship <rip dir> — place under Artist/Album (Year) on $dest
  local dir=$1 first artist album year target
  first=$(find "$dir" -maxdepth 1 -name '*.flac' | sort | head -n1)
  [[ -n $first ]] || { echo "no FLAC files in $dir" >&2; return 1; }

  artist=$(clean "$(tag "$first" ALBUMARTIST "ALBUM ARTIST" album_artist ARTIST)")
  album=$(clean "$(tag "$first" ALBUM)")
  year=$(tag "$first" DATE YEAR | cut -c1-4)
  [[ -n $artist && -n $album ]] || { echo "missing artist/album tags in $first" >&2; return 1; }
  target="$artist/$album${year:+ ($year)}"

  # cyanrip writes MusicBrainz IDs under its own names (release_id, mbid,
  # totaldiscs). Add the Picard-standard ones Jellyfin and beets read.
  local f rel rec td
  for f in "$dir"/*.flac; do
    rel=$(tag "$f" release_id) rec=$(tag "$f" mbid) td=$(tag "$f" totaldiscs)
    metaflac ${rel:+--set-tag=MUSICBRAINZ_ALBUMID=$rel} \
             ${rec:+--set-tag=MUSICBRAINZ_TRACKID=$rec} \
             ${td:+--set-tag=DISCTOTAL=$td} "$f"
  done

  # Jellyfin looks for cover.jpg/folder.jpg; cyanrip names it Front.jpg.
  local front
  front=$(find "$dir" -maxdepth 1 -iname 'front.*' | head -n1)
  [[ -n $front && ! -e $dir/cover.${front##*.} ]] && cp "$front" "$dir/cover.${front##*.}"

  # Multi-disc sets land in the same folder: cyanrip prefixes track files
  # with the disc number and suffixes the log/cue with "CD<n>", so nothing
  # collides. --ignore-existing keeps a re-rip from clobbering a good copy.
  # No shell quoting on the remote path: rsync >= 3.2.4 passes it verbatim.
  rsync -rt --mkpath --chmod=D0755,F0644 --ignore-existing --partial \
    "$dir/" "$dest/$target/"
  printf '%s' "$target"
}

# The cdrip-ship wrapper sets CDRIP_MODE (argv0 does not reach a script's $0).
if [[ ${CDRIP_MODE:-} == ship ]]; then
  target=$(ship "${1:?usage: cdrip-ship <rip dir>}")
  echo "shipped $target"
  exit
fi
trap crashed EXIT

dev=${1:?usage: cdrip <device>}
[[ $dev == /dev/* ]] || dev=/dev/$dev

stamp=$(date +%Y%m%d-%H%M%S)
work=$state/staging/$stamp
mkdir -p "$work"
cd "$work"

rip() {
  # -m 1200: Cover Art Archive's full-size originals run to tens of MB of
  # PNG, and cyanrip embeds the cover in every track. The 1200px JPEG
  # thumbnail is plenty. -L/-M left at cyanrip's defaults: they carry the
  # "CD<n>" suffix that keeps a multi-disc set's logs from colliding.
  # The sleep block covers the rip only, not a question waiting on the desktop.
  local inhibit=()
  [[ -n ${MEDIAGRAB_INHIBITED-} ]] ||
    inhibit=(systemd-inhibit --what=sleep:idle --who=mediagrabber --why="Ripping a CD")
  "${inhibit[@]}" cyanrip -d "$dev" -s "$offset" -o flac -m 1200 -D rip "$@" 2>&1 | tee -a cyanrip.out
  return "${PIPESTATUS[0]}"
}

ask() {  # a popup with buttons while the disc is in; prints the answer
  command -v mediagrab-ask >/dev/null || return 1
  mediagrab-ask --while "udevadm info --query=property --name=$(printf %q "$dev") | grep -qx ID_CDROM_MEDIA=1" "$@"
}

failed() {  # failed <message> — the disc stays in; offer Retry / Eject
  local a
  echo "$1"
  command -v fleet-notify >/dev/null && fleet-notify "cdrip: $1" || true
  notified=1
  if command -v mediagrab-ask >/dev/null; then
    a=$(ask --title "CD rip FAILED" "$1" retry=Retry eject=Eject) || true
  else
    command -v mediagrab-popup >/dev/null && mediagrab-popup fail "$1" || true
  fi
  case ${a-} in
    retry) cd /; rm -rf "$work"; echo "answered: retry"; exec "$BASH" "${BASH_SOURCE[0]}" "$dev" ;;
    eject) eject "$dev" || true ;;
  esac
  exit 1
}

untagged() {  # rip -N into unmatched/, to be tagged by hand and cdrip-ship'd
  rip -N || failed "rip FAILED on $dev — see $work/cyanrip.out"
  mkdir -p "$state/unmatched"
  mv "$work" "$state/unmatched/$stamp"
  eject "$dev" || true
  notify note "disc not in MusicBrainz; ripped untagged to $state/unmatched/$stamp. Tag it, then: cdrip-ship $state/unmatched/$stamp/rip"
  exit 0
}

note=""
if ! rip; then
  if grep -q 'Multiple releases found' cyanrip.out; then
    # "    2 (ID: 5f1c…): The Sign (US) (1993-…)" -> "2=The Sign (US) (1993-…)"
    mapfile -t rels < <(sed -nE 's/^ +([0-9]+) \(ID: [^)]*\): (.*)$/\1=\2/p' cyanrip.out)
    a=$(ask --timeout 300 --title "CD: which MusicBrainz release?" \
          "${#rels[@]} releases match this disc; same tracks, they differ in country, label or date. Unanswered, the first is taken in 5 min." \
          "${rels[@]:0:4}" eject=Eject) || a=""
    [[ $a == eject ]] && { eject "$dev" || true; echo "answered: eject"; exit 0; }
    if [[ $a =~ ^[0-9]+$ ]]; then note=" (release $a of ${#rels[@]} on MusicBrainz, as chosen)"
    else a=1 note=" (${#rels[@]} MusicBrainz releases; took the first)"; fi
    rip -R "$a" || failed "rip FAILED on $dev — see $work/cyanrip.out"
  elif grep -qE 'Unable to find release info|matching stub' cyanrip.out; then
    a=$(ask --timeout 300 --title "CD not in MusicBrainz" --reply "Artist - Album (Year)" \
          "Type \"Artist - Album (Year)\" to tag it and file it in the library, or rip it untagged to tag later with Picard. Unanswered: untagged, in 5 min." \
          untagged="Rip untagged" eject=Eject) || untagged
    [[ $a == eject ]] && { eject "$dev" || true; echo "answered: eject"; exit 0; }
    # "Artist - Album (Year)", the year optional
    [[ $a =~ ^reply\ (.+[^ ])\ +-\ +(.+[^ ])$ ]] || untagged
    artist=${BASH_REMATCH[1]} album=${BASH_REMATCH[2]} year=""
    if [[ $album =~ ^(.+[^ ])\ *\(([0-9]{4})\)$ ]]; then album=${BASH_REMATCH[1]} year=${BASH_REMATCH[2]}; fi
    rip -N || failed "rip FAILED on $dev — see $work/cyanrip.out"
    for f in rip/*.flac; do
      metaflac --remove-tag=ALBUM --remove-tag=ALBUMARTIST --remove-tag=ARTIST --remove-tag=DATE \
        --set-tag="ALBUM=$album" --set-tag="ALBUMARTIST=$artist" --set-tag="ARTIST=$artist" \
        ${year:+--set-tag=DATE=$year} "$f"
    done
    note=" (not in MusicBrainz; tagged as typed, track titles missing)"
  else
    failed "rip FAILED on $dev — see $work/cyanrip.out"
  fi
fi

# "Tracks ripped accurately: n/m" only appears when the disc is in the
# AccurateRip DB; n < m means a bad rip, a new pressing, or a wrong offset.
accurip=$(grep -o 'Tracks ripped accurately: [0-9]*/[0-9]*' cyanrip.out | tail -n1 || true)
accurip=${accurip:+ — AccurateRip ${accurip#Tracks ripped accurately: }}

if target=$(ship "$work/rip"); then
  eject "$dev" || true
  cd /
  rm -rf "$work"
  notify ok "ripped $target$note$accurip"
else
  eject "$dev" || true
  notify fail "ripped but could not ship $work/rip to $dest — run: cdrip-ship $work/rip"
  exit 1
fi
