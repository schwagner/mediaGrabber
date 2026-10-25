#!/usr/bin/env bash
# ============================================================
# mediagrab.sh — work out what disc is in DEVICE and hand it to its ripper
#
# Usage: mediagrab <device>     e.g. mediagrab /dev/sr0
#
# Run by mediagrab@<dev>.service, which udev starts whenever media appears
# in an optical drive. Decides from udev's cdrom_id properties, plus lsdvd
# for the one case those cannot settle:
#
#   audio tracks              -> cdrip   (audio CD, enhanced CDs included)
#   Blu-ray                   -> notify only; not supported
#   DVD that lsdvd can read   -> dvdrip  (has a VIDEO_TS structure)
#   anything else             -> notify only; a data disc is left alone
#
# Audio is tested first because an enhanced CD carries a data session too.
# A DVD is only "video" if lsdvd can parse its IFOs — a burned DVD-R of
# files has ID_CDROM_MEDIA_DVD_R=1 just like a burned movie. The IFOs are
# never encrypted, so a CSS problem does not show up here; it shows up as
# a failed rip in dvdrip.
# ============================================================
set -euo pipefail

dev=${1:?usage: mediagrab <device>}
[[ $dev == /dev/* ]] || dev=/dev/$dev

notify() {
  echo "$*"
  command -v fleet-notify >/dev/null && fleet-notify "mediagrab: $*" || true
}

props=$(udevadm info --query=property --name="$dev")
has() { grep -q "^$1" <<<"$props"; }

if has 'ID_CDROM_MEDIA_TRACK_COUNT_AUDIO='; then
  exec cdrip "$dev"
elif has 'ID_CDROM_MEDIA_BD'; then
  notify "Blu-ray in $dev — not supported, left alone"
elif has 'ID_CDROM_MEDIA_DVD' && lsdvd "$dev" >/dev/null 2>&1; then
  if [[ ${MEDIAGRAB_DVD:-1} == 1 ]]; then
    exec dvdrip "$dev"
  fi
  notify "video DVD in $dev, but DVD ripping is off — left alone"
else
  label=$(sed -n 's/^ID_FS_LABEL=//p' <<<"$props")
  notify "data disc${label:+ \"$label\"} in $dev — not audio or video, left alone"
fi
