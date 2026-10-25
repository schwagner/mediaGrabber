#!/usr/bin/env bash
# ============================================================
# datarip.sh — archive the data disc in DEVICE as one .tar.zst
#
# Usage: datarip <device>
#
# Lands at $DATARIP_DEST (host:path) as  <Label>_<id>.tar.zst  plus
# <Label>_<id>.txt, the `tar -tvv` listing, so a disc can be found with grep
# without unpacking anything. Inside, everything sits under <Label>_<id>/.
# <id> is the filesystem UUID — for ISO 9660 the volume's creation time,
# e.g. 2009-03-14-12-00-00-00 — so the same disc always gets the same name,
# and a disc that is already in the archive is ejected, not archived twice.
#
# FILES, NOT AN IMAGE. The disc is mounted through udisks (the user's
# udiskie usually beats us to it; either way works) and read with tar, so
# the kernel's iso9660/Joliet/Rock Ridge/UDF drivers do the parsing. That
# runs as `user`, no root — the module's polkit rule lets it mount and
# unmount outside a desktop session. A disc that turns out to be video
# (BDMV, or a VIDEO_TS lsdvd could not read) is left alone.
#
# COMPRESSED ON THE FAR SIDE. The plain tar stream goes over SSH and the
# destination host runs `nice zstd -T0 -15`. tx9 is a laptop and often on
# battery; tinydaw is a mains-powered desktop with spare cores. -15 there
# does ~100 MB/s on five cores, several times what a DVD drive reads, so
# it never slows the rip; -19 (~18 MB/s) would. zstd must be on the far
# side's PATH for a non-interactive SSH login.
#
# A read error fails the run: nothing is kept, the disc stays in the drive
# to be cleaned and retried with `systemctl start mediagrab@sr0`.
# ============================================================
set -euo pipefail

dev=${1:?usage: datarip <device>}
[[ $dev == /dev/* ]] || dev=/dev/$dev

state=${DATARIP_STATE:-/var/lib/mediagrabber/data}
dest=${DATARIP_DEST:?DATARIP_DEST (host:/path) is not set}
host=${dest%%:*} path=${dest#*:}
level=15

notify() {  # notify <ok|fail|note> <message> — once per run, as it ends
  local level=$1; shift
  echo "$*"
  command -v fleet-notify >/dev/null && fleet-notify "datarip: $*" || true
  command -v mediagrab-popup >/dev/null && mediagrab-popup "$level" "$*" || true
  notified=1
}

# Whatever set -e kills before a notify still gets a popup.
crashed() {
  local rc=$?
  (( rc == 0 )) || [[ -n ${notified-} ]] ||
    notify fail "datarip stopped unexpectedly (exit $rc) on ${dev:-the drive} — see journalctl -u 'mediagrab@*'"
}
trap crashed EXIT

safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._]*//; s/_*$//'; }
remote() { ssh "$host" "$1"; }  # the far side's login shell may be zsh
q() { printf '%q' "$1"; }

props=$(udevadm info --query=property --name="$dev")
prop() { sed -n "s/^$1=//p" <<<"$props" | head -n1; }
label=$(prop ID_FS_LABEL)
id=$(prop ID_FS_UUID)
name="$(safe "${label:-untitled}")_$(safe "${id:-$(date +%Y-%m-%d-%H%M%S)}")"
name=${name#_}
final="$path/$name.tar.zst"
shown="\"${label:-untitled}\""

if remote "test -e $(q "$final")"; then
  eject "$dev" || true
  notify note "data disc $shown is already archived as $host:$final — ejected"
  exit 0
fi

# --- mount ---------------------------------------------------------------
# udiskie mounts a new disc within a second or two of udev seeing it; try
# udisks ourselves as well, and take whichever mount shows up.
mnt=""
for _ in $(seq 20); do
  mnt=$(findmnt -nro TARGET --source "$dev" | head -n1 || true)
  [[ -n $mnt ]] && break
  udisksctl mount -b "$dev" --no-user-interaction >/dev/null 2>&1 || sleep 1
done
[[ -n $mnt ]] || { notify fail "could not mount data disc $shown in $dev"; exit 1; }
unmount() { udisksctl unmount -b "$dev" --no-user-interaction >/dev/null 2>&1 || true; }

if [[ -d $mnt/BDMV || -d $mnt/bdmv ]]; then
  notify note "Blu-ray video $shown in $dev — not supported, left alone"; exit 0
elif [[ -d $mnt/VIDEO_TS || -d $mnt/video_ts ]]; then
  notify note "DVD $shown in $dev has VIDEO_TS but lsdvd cannot read it — left alone"; exit 0
fi

# --- archive -------------------------------------------------------------
work=$state/$name
mkdir -p "$work"
size=$(du -sb "$mnt" | cut -f1)
part="$final.part"

echo "archiving $mnt ($((size / 1048576)) MiB) to $host:$final"
# -vv with --index-file: the ls -l style listing goes to the file, not the
# stream. --transform puts everything under $name/ (safe() leaves no
# characters sed would read specially).
if ! tar -C "$mnt" -cvv --index-file="$work/index.txt" --transform="s,^\.,$name," -f - . |
     remote "mkdir -p $(q "$path") && nice zstd -q -T0 -$level > $(q "$part")"; then
  remote "rm -f $(q "$part")" || true
  notify fail "archiving data disc $shown FAILED (read error? network?) — see journalctl -u 'mediagrab@*'"
  exit 1
fi
packed=$(remote "cat > $(q "$path/$name.txt") && mv $(q "$part") $(q "$final") && stat -c %s $(q "$final")" \
  < "$work/index.txt") || { notify fail "archived $shown but could not finish $host:$final"; exit 1; }

unmount
eject "$dev" || true
rm -rf "$work"
notify ok "archived data disc $shown → $host:$final ($((size / 1048576)) MiB, $((packed / 1048576)) MiB packed)"
