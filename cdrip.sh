#!/usr/bin/env bash
# ============================================================
# cdrip.sh — rip the audio CD in DEVICE to FLAC and ship it to the library
#
# Usage: cdrip <device>        e.g. cdrip /dev/sr0
#
# Run by cdrip@<dev>.service, which udev starts when a disc with audio
# tracks appears. Can be run by hand with the same argument.
#
# Pipeline:
#   1. cyanrip rips to $CDRIP_STATE/staging/<stamp>/rip — paranoia,
#      AccurateRip verification, MusicBrainz tags, Cover Art Archive art
#      (embedded and as a file), a .log and a .cue.
#   2. The album folder is named from the FLAC tags, not by cyanrip's -D,
#      because cyanrip sanitises '/' and so cannot make Artist/Album paths.
#   3. rsync to $CDRIP_DEST (host:path) as Artist/Album (Year)/. Jellyfin's
#      real-time monitor picks it up; nothing has to poke its API.
#   4. Eject, and fleet-notify the outcome.
#
# MusicBrainz outcomes, and why each is handled the way it is:
#   - one release    -> rip and ship.
#   - several        -> cyanrip refuses without -R. Retry with -R 1 and ship,
#                       but say so in the notification: the tracklist is the
#                       same disc, only country/label/date may be off.
#   - none           -> rip untagged (-N) and keep it LOCAL in unmatched/.
#                       Untagged "Unknown Album" folders in Jellyfin are worse
#                       than a short delay; tag it with Picard and run
#                       `cdrip-ship <dir>` to send it on.
#
# A failed rip never ejects, so the disc stays in the drive to be cleaned
# and retried with `systemctl start cdrip@sr0`.
# ============================================================
set -euo pipefail

state=${CDRIP_STATE:-/var/lib/cdrip}
dest=${CDRIP_DEST:?CDRIP_DEST (host:/path) is not set}
offset=${CDRIP_OFFSET:-0}

notify() {
  echo "$*"
  command -v fleet-notify >/dev/null && fleet-notify "cdrip: $*" || true
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
  cyanrip -d "$dev" -s "$offset" -o flac -m 1200 -D rip "$@" 2>&1 | tee -a cyanrip.out
  return "${PIPESTATUS[0]}"
}

note=""
if ! rip; then
  if grep -q 'Multiple releases found' cyanrip.out; then
    note=" (several MusicBrainz releases; took the first)"
    rip -R 1 || { notify "rip FAILED on $dev — see $work/cyanrip.out"; exit 1; }
  elif grep -q 'Unable to find release info' cyanrip.out; then
    rip -N || { notify "rip FAILED on $dev — see $work/cyanrip.out"; exit 1; }
    mkdir -p "$state/unmatched"
    mv "$work" "$state/unmatched/$stamp"
    eject "$dev" || true
    notify "disc not in MusicBrainz; ripped untagged to $state/unmatched/$stamp. Tag it, then: cdrip-ship $state/unmatched/$stamp/rip"
    exit 0
  else
    notify "rip FAILED on $dev — see $work/cyanrip.out"
    exit 1
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
  notify "ripped $target$note$accurip"
else
  eject "$dev" || true
  notify "ripped but could not ship $work/rip to $dest — run: cdrip-ship $work/rip"
  exit 1
fi
