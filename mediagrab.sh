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
#   blank                     -> notify only
#   audio tracks              -> cdrip   (audio CD, enhanced CDs included)
#   DVD that lsdvd can read   -> dvdrip  (has a VIDEO_TS structure)
#   anything else             -> datarip (data CD/DVD/BD -> .tar.zst), which
#                                mounts it and leaves Blu-ray video alone
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

notify() {  # notify <ok|fail|note> <message> — once per run, as it ends
  local level=$1; shift
  echo "$*"
  command -v fleet-notify >/dev/null && fleet-notify "mediagrab: $*" || true
  command -v mediagrab-popup >/dev/null && mediagrab-popup "$level" "$*" || true
  notified=1
}

# Whatever set -e kills before a notify still gets a popup.
crashed() {
  local rc=$?
  (( rc == 0 )) || [[ -n ${notified-} ]] ||
    notify fail "mediagrab stopped unexpectedly (exit $rc) on ${dev:-the drive} — see journalctl -u 'mediagrab@*'"
}

trap crashed EXIT

props=$(udevadm info --query=property --name="$dev")
has() { grep -q "^$1" <<<"$props"; }

if has 'ID_CDROM_MEDIA_STATE=blank'; then
  notify note "blank disc in $dev — left alone"
elif has 'ID_CDROM_MEDIA_TRACK_COUNT_AUDIO='; then
  exec cdrip "$dev"
elif ! has 'ID_CDROM_MEDIA_BD' && has 'ID_CDROM_MEDIA_DVD' && lsdvd "$dev" >/dev/null 2>&1; then
  if [[ ${MEDIAGRAB_DVD:-1} == 1 ]]; then
    exec dvdrip "$dev"
  fi
  notify note "video DVD in $dev, but DVD ripping is off — left alone"
elif [[ -n ${DATARIP_DEST-} ]]; then
  exec datarip "$dev"
else
  label=$(sed -n 's/^ID_FS_LABEL=//p' <<<"$props")
  notify note "data or Blu-ray disc${label:+ \"$label\"} in $dev — archiving is off, left alone"
fi
