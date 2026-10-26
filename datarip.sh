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
# DAMAGED DISCS ARE SALVAGED. Old CD-Rs fade, and one bad patch should not
# cost the rest of the disc. tar carries on past a file it cannot read
# (padding it with zeros, or leaving it out) and exits non-zero; when the
# far side still took the whole stream, the archive is kept as
# <Label>_<id>.damaged.tar.zst, and its .damaged.txt starts with tar's
# complaints, so the bad files are named. The disc is ejected to be cleaned
# or tried in another drive: reinserting it archives it again, since only a
# clean archive counts as done, and a clean one replaces the damaged one.
# A failure on the SSH/zstd side keeps nothing.
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
  # -r escapes the awkward characters (a space is \x20); %b undoes that.
  mnt=$(printf '%b' "$(findmnt -nro TARGET --source "$dev" | head -n1 || true)")
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

echo "archiving $mnt ($(numfmt --to=iec "$size")) to $host:$final"
# -vv with --index-file: the ls -l style listing goes to the file, not the
# stream. --transform puts everything under $name/ (safe() leaves no
# characters sed would read specially). tar's stderr is only its complaints.
set +e
tar -C "$mnt" -cvv --show-transformed-names --index-file="$work/index.txt" --transform="s,^\.,$name," -f - . \
    2>"$work/errors.txt" |
  remote "mkdir -p $(q "$path") && nice zstd -q -T0 -$level > $(q "$part")"
rc=("${PIPESTATUS[@]}")
set -e
cat "$work/errors.txt" >&2
if (( rc[1] != 0 )); then
  remote "rm -f $(q "$part")" || true
  notify fail "archiving data disc $shown FAILED on the $host side (network? disk full?) — see journalctl -u 'mediagrab@*'"
  exit 1
fi

out="$path/$name"
if (( rc[0] == 0 )); then
  cp "$work/index.txt" "$work/listing.txt"
  tidy="rm -f $(q "$out.damaged.tar.zst") $(q "$out.damaged.txt")"
else
  out+=.damaged
  bad=$(grep -c '^tar: ' "$work/errors.txt" || true)
  { echo "# DAMAGED: tar exited $rc, $bad problem(s) reading the disc:"
    sed 's/^/# /' "$work/errors.txt"
    echo
    cat "$work/index.txt"; } > "$work/listing.txt"
  tidy=:
fi
packed=$(remote "cat > $(q "$out.txt") && mv $(q "$part") $(q "$out.tar.zst") && $tidy && stat -c %s $(q "$out.tar.zst")" \
  < "$work/listing.txt") || { notify fail "archived $shown but could not finish $host:$out.tar.zst"; exit 1; }

unmount
eject "$dev" || true
rm -rf "$work"
if (( rc[0] != 0 )); then
  notify note "data disc $shown is DAMAGED — kept what could be read as $host:$out.tar.zst ($(numfmt --to=iec "$packed") packed); $bad problem(s) listed at the top of $out.txt. Clean it or try another drive, then reinsert."
  exit 0
fi
notify ok "archived data disc $shown → $host:$out.tar.zst ($(numfmt --to=iec "$size"), $(numfmt --to=iec "$packed") packed)"
