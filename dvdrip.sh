#!/usr/bin/env bash
# ============================================================
# dvdrip.sh — remux the video DVD in DEVICE to MKV and ship it to Jellyfin
#
# Usage:
#   dvdrip <device>                              decide movie/show itself
#   dvdrip <device> movie "<Name (Year)>" [title]
#   dvdrip <device> show "<Series>" <season> [first episode]
#
# The override forms are what the "needs a decision" notification tells
# you to run: they skip the guessing, not the ripping.
#
# REMUX, NOT TRANSCODE. ffmpeg's dvdvideo demuxer (libdvdnav/libdvdread,
# CSS via libdvdcss) copies the MPEG-2 video, every audio track, the
# subtitles and the chapters into MKV untouched — read-speed bound, about
# 15 min a disc, nothing to tune and nothing lost. The price is 4–8 GB a
# film. Jellyfin plays MPEG-2 directly to most clients and transcodes it on
# tinydaw's iGPU (mpeg2 decode is on in jellyfin.nix) for the rest.
#
# WHAT IS ON THE DISC, from lsdvd's title list:
#   - episodic: >= 3 titles of 15–70 min, of similar length (within 40% of
#     their median), and no title longer than 70 min unless it is roughly
#     their sum ("Play All"). -> show
#   - decoys: >= 3 titles within 2% of the longest one's length. Copy
#     protection (ARccOS, Disney's 99-title discs) does this to hide the
#     real feature; guessing would rip the wrong one. -> needs a decision
#   - otherwise the longest title, if at least 40 min.     -> movie
#
# NAMES come from the volume label, the only metadata a DVD carries:
# THE_MATRIX_WS -> "The Matrix". No year, so Jellyfin's TMDb lookup goes by
# name; a wrong match is fixed with Identify in Jellyfin. A generic label
# (DVD_VIDEO, DISC1, ...) cannot name anything -> needs a decision.
# Shows need a season in the label (FRIENDS_S1_D2, LOST_SEASON_3); episodes
# are numbered on from the highest SxxEyy already in that season's folder
# on the far side, so discs must go in in order.
#
# "Needs a decision" ejects nothing and rips nothing: the disc stays in the
# drive and the notification carries the title list and the command to run.
# ============================================================
set -euo pipefail

dev=${1:?usage: dvdrip <device> [movie "<Name (Year)>" [title] | show "<Series>" <season> [first ep]]}
[[ $dev == /dev/* ]] || dev=/dev/$dev
mode=${2:-auto}

state=${DVDRIP_STATE:-/var/lib/mediagrabber/dvd}
movies=${DVDRIP_MOVIES:?DVDRIP_MOVIES (host:/path) is not set}
shows=${DVDRIP_SHOWS:?DVDRIP_SHOWS (host:/path) is not set}

notify() {
  echo "$*"
  command -v fleet-notify >/dev/null && fleet-notify "dvdrip: $*" || true
}

clean() {  # safe as one path component
  printf '%s' "$1" | tr '/\\:*?"<>|' '_________' | sed 's/^[. ]*//; s/[. ]*$//'
}

hms() { printf '%d:%02d:%02d' $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

info=$(lsdvd "$dev" 2>/dev/null) || { notify "lsdvd cannot read $dev"; exit 1; }
label=$(sed -n 's/^Disc Title: *//p' <<<"$info" | head -n1)

# "Title: 01, Length: 01:52:33.200 Chapters: 28, ..." -> "1 6753"
declare -A len=()
while read -r t s; do len[$t]=$s; done < <(
  awk '/^Title: [0-9]+, Length:/ {
         t = $2; sub(",", "", t); split($4, a, ":")
         printf "%d %d\n", t, a[1]*3600 + a[2]*60 + a[3] }' <<<"$info")
(( ${#len[@]} )) || { notify "no titles found on $dev (\"$label\")"; exit 1; }

titles_by_len() { for t in "${!len[@]}"; do echo "${len[$t]} $t"; done | sort -rn; }
summary() { titles_by_len | head -n8 | while read -r s t; do printf 'title %d %s; ' "$t" "$(hms "$s")"; done; }

decide() {  # print the reason and the commands, leave the disc in, exit
  notify "\"$label\" needs a decision: $1. Titles: $(summary)Run one of:
  dvdrip $dev movie \"Name (Year)\" [title]
  dvdrip $dev show \"Series\" <season> [first episode]"
  exit 0
}

# --- name from the volume label ---------------------------------------
# Drop the edition/format junk studios append, then title-case.
junk='WS|FS|WIDESCREEN|FULLSCREEN|FULL_SCREEN|16X9|4X3|NTSC|PAL|R[0-9]|SE|CE|SPECIAL_EDITION|COLLECTORS_EDITION|DVD|DISC_?[0-9]*|D[0-9]+|SIDE_?[AB12]'
label_up=$(tr '[:lower:]' '[:upper:]' <<<"$label" | tr ' -' '__')
generic=0
[[ ${#label_up} -lt 3 || $label_up =~ ^(DVD|DVD_?VIDEO|VIDEO_?TS|DISC_?[0-9]*|[0-9_]+|[A-Z]{1,3}[0-9]+)$ ]] && generic=1

season=""
if [[ $label_up =~ _(S|SEASON_?|SERIES_?)([0-9]{1,2})(_|$) ]]; then
  season=$((10#${BASH_REMATCH[2]}))
fi
base=$(sed -E "s/_(S|SEASON_?|SERIES_?)[0-9]{1,2}(_.*)?$//" <<<"$label_up")
while [[ $base =~ ^(.+)_($junk)$ ]]; do base=${BASH_REMATCH[1]}; done
name=$(tr '_' ' ' <<<"$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/(^| )([a-z])/\1\u\2/g')

# --- what kind of disc ------------------------------------------------
read -r longest_s longest_t < <(titles_by_len | head -n1)
mapfile -t eps < <(
  titles_by_len | awk '$1 >= 900 && $1 <= 4200' | sort -n -k2 |
  awk '!seen[$1]++')          # drop exact-length repeats (same PGC twice)

classify() {  # sets $kind; for a show, trims $eps to the episode run
  if (( ${#eps[@]} >= 3 )); then
    local med sum=0 ok=() e s
    med=$(printf '%s\n' "${eps[@]}" | awk '{print $1}' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    for e in "${eps[@]}"; do
      s=${e%% *}
      (( s*10 >= med*6 && s*10 <= med*14 )) && { ok+=("$e"); sum=$((sum + s)); }
    done
    if (( ${#ok[@]} >= 3 )) && (( longest_s <= 4200 || longest_s*10 >= sum*9 )); then
      eps=("${ok[@]}"); kind=show; return
    fi
  fi
  local near
  near=$(titles_by_len | awk -v L="$longest_s" '$1*50 >= L*49' | wc -l)
  if (( near >= 3 && longest_s >= 2400 )); then kind=decoys
  elif (( longest_s >= 2400 )); then kind=movie
  else kind=short
  fi
}

case $mode in
  auto)
    classify
    case $kind in
      decoys) decide "$(titles_by_len | awk -v L="$longest_s" '$1*50 >= L*49' | wc -l) titles of the same length (copy-protection decoys?)" ;;
      short)  decide "nothing longer than 40 min" ;;
    esac
    if (( generic )); then
      decide "the label tells me nothing"
    elif [[ $kind == show && -z $season ]]; then
      decide "looks like TV (${#eps[@]} episodes) but the label has no season"
    elif [[ $kind == movie && -n $season ]]; then
      decide "the label names a season but the disc looks like one long title"
    fi
    ;;
  movie)
    kind=movie name=${3:?movie needs a name}
    if [[ -n ${4:-} ]]; then
      longest_t=$4 longest_s=${len[$4]:?no title $4 on this disc}
    fi
    ;;
  show)
    name=${3:?show needs a series name} season=${4:?show needs a season}
    classify
    [[ $kind == show ]] || { notify "no run of episode-length titles on $dev"; exit 1; }
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
name=$(clean "$name")

stamp=$(date +%Y%m%d-%H%M%S)
work=$state/staging/$stamp
mkdir -p "$work"
cd "$work"
printf '%s\n' "$info" > lsdvd.txt

remux() {  # remux <title> <out.mkv>
  # Video, audio, subtitles only: an MKV muxer error on some stray stream
  # type should not cost the film. -map_chapters comes along by default.
  ffmpeg -nostdin -hide_banner -loglevel warning -stats \
    -f dvdvideo -title "$1" -i "$dev" \
    -map 0:v:0 -map '0:a?' -map '0:s?' -c copy \
    -f matroska "$2.part" 2>>ffmpeg.out
  mv "$2.part" "$2"
}

fail() { notify "rip FAILED for \"$label\" — see $work/ffmpeg.out (CSS keys? scratched?)"; exit 1; }

if [[ $kind == movie ]]; then
  out="$name.mkv"
  remux "$longest_t" "$out" || fail
  rsync -t --mkpath --chmod=F0644 --ignore-existing --partial "$out" "$movies/$name/" || {
    notify "ripped but could not ship $work/$out to $movies/$name/"; exit 1; }
  what="movie \"$name\" (title $longest_t, $(hms "$longest_s"))"
else
  sdir=$(printf 'Season %02d' "$season")
  dest="$shows/$name/$sdir"
  # Continue numbering from what is already there. --list-only goes through
  # rsync's own remote handling, so the path needs no shell quoting.
  last=$(rsync --list-only "$dest/" 2>/dev/null | grep -oE 'S[0-9]+E[0-9]+' |
         sed -E 's/.*E0*//' | sort -n | tail -n1 || true)
  n=${5:-$(( ${last:-0} + 1 ))}
  first=$n
  for e in "${eps[@]}"; do
    t=${e##* }
    out=$(printf '%s S%02dE%02d.mkv' "$name" "$season" "$n")
    remux "$t" "$out" || fail
    n=$((n + 1))
  done
  rsync -t --mkpath --chmod=F0644 --ignore-existing --partial ./*.mkv "$dest/" || {
    notify "ripped but could not ship $work to $dest/"; exit 1; }
  what=$(printf '%s S%02dE%02d–E%02d (%d titles — check the order)' "$name" "$season" "$first" "$((n - 1))" "${#eps[@]}")
fi

eject "$dev" || true
cd /
rm -rf "$work"
notify "ripped $what"
