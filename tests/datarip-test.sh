#!/usr/bin/env bash
# tests/datarip-test.sh — datarip end to end, without a drive or a far side.
#
# Stubs udevadm (canned label/UUID), findmnt (a temp dir is "the disc"),
# udisksctl and eject, and ssh (runs the remote command locally), so the
# real tar and zstd run. Run: bash tests/datarip-test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'chmod -R u+rwX "$tmp"; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/remote" "$tmp/disc"

cat > "$tmp/bin/udevadm" <<'S'
#!/usr/bin/env bash
printf 'ID_FS_LABEL=%s\nID_FS_UUID=%s\n' "$FAKE_LABEL" "$FAKE_UUID"
S
printf '#!/bin/sh\necho "$FAKE_MNT"\n' > "$tmp/bin/findmnt"
printf '#!/bin/sh\n:\n' > "$tmp/bin/udisksctl"
printf '#!/bin/sh\n:\n' > "$tmp/bin/eject"
printf '#!/bin/sh\necho "$*" >> "$NOTES"\n' > "$tmp/bin/fleet-notify"
printf '#!/usr/bin/env bash\nexec bash -c "$2"\n' > "$tmp/bin/ssh"
chmod +x "$tmp/bin"/*

export PATH="$tmp/bin:$PATH" DATARIP_STATE="$tmp/state" NOTES="$tmp/notes"
export DATARIP_DEST="fake:$tmp/remote" FAKE_MNT="$tmp/disc"
export FAKE_LABEL="Photos 2009" FAKE_UUID=2009-03-14-12-00-00-00
name=Photos_2009_2009-03-14-12-00-00-00

pass=0 fail=0
check() {  # check <desc> <condition...>
  if "${@:2}"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; tail -n3 "$NOTES" 2>/dev/null; fi
}
run() { : > "$NOTES"; bash "$here/datarip.sh" /dev/sr9 >/dev/null 2>&1 || true; }

mkdir -p "$tmp/disc/DCIM/100"
head -c 200000 /dev/urandom > "$tmp/disc/DCIM/100/img 1.jpg"
seq 100000 > "$tmp/disc/notes.txt"

run
check "tarball lands under Label_UUID"   test -f "$tmp/remote/$name.tar.zst"
check "listing alongside"                grep -q "$name/DCIM/100/img 1.jpg" "$tmp/remote/$name.txt"
check "no .part left"                    test ! -e "$tmp/remote/$name.tar.zst.part"
mkdir "$tmp/out"; zstd -dc "$tmp/remote/$name.tar.zst" | tar -C "$tmp/out" -xf -
check "round trip, under one top dir"    cmp -s "$tmp/disc/DCIM/100/img 1.jpg" "$tmp/out/$name/DCIM/100/img 1.jpg"
check "ok notification"                  grep -q 'archived data disc' "$NOTES"

run
check "same disc again -> skipped"       grep -q 'already archived' "$NOTES"

FAKE_UUID=2010-01-01-00-00-00-00
chmod 000 "$tmp/disc/notes.txt"
run
check "read error -> fail"               grep -q 'FAILED' "$NOTES"
check "read error -> nothing kept"       bash -c "! ls '$tmp/remote' | grep -q 2010"
chmod 644 "$tmp/disc/notes.txt"

mkdir "$tmp/disc/BDMV"
run
check "Blu-ray video -> left alone"      grep -q 'Blu-ray video' "$NOTES"

[[ -n ${SHOW_NOTES:-} ]] && cat "$NOTES"
echo "$pass passed, $fail failed"
(( fail == 0 ))
