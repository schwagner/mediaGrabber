# mediagrab (the dispatcher udev runs), cdrip, cdrip-ship, dvdrip, datarip and
# mediagrab-popup (the sticky desktop notification), each a
# wrapper with the runtime tools pinned on PATH so the unit does not depend
# on the system profile. fleet-notify is the exception: it is host config,
# found at run time and skipped if absent.
#
# ffmpeg is the headless build with libdvdnav/libdvdread switched on for
# the dvdvideo demuxer. Neither default ffmpeg has it; ffmpeg-full does,
# but drags in ~140 MB of codecs this never uses. The override is not in
# cache.nixos.org, so it builds once per nixpkgs bump (a few minutes).
# libdvdread links libdvdcss in nixpkgs, which is what decrypts CSS.
{ lib, stdenvNoCC, makeWrapper, bash, cyanrip, flac, rsync, openssh,
  coreutils, findutils, gnugrep, gnused, gawk, util-linux, systemd, lsdvd,
  ffmpeg-headless, libnotify, gnutar, udisks }:

let
  ffmpeg = ffmpeg-headless.override { withDvdnav = true; withDvdread = true; };
  path = lib.makeBinPath [
    bash cyanrip flac rsync openssh coreutils findutils gnugrep gnused gawk
    util-linux systemd lsdvd ffmpeg libnotify gnutar udisks
  ];
in
stdenvNoCC.mkDerivation {
  pname = "mediagrabber";
  version = "0.5.2";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    for s in mediagrab cdrip dvdrip datarip popup; do
      install -Dm755 $s.sh $out/libexec/$s
    done
    patchShebangs $out/libexec
    # Every wrapper gets the same PATH, $out/bin first, so mediagrab can
    # exec cdrip/dvdrip/datarip by name.
    for s in mediagrab cdrip dvdrip datarip; do
      makeWrapper $out/libexec/$s $out/bin/$s --prefix PATH : $out/bin:${path}
    done
    makeWrapper $out/libexec/popup $out/bin/mediagrab-popup --prefix PATH : ${path}
    makeWrapper $out/libexec/cdrip $out/bin/cdrip-ship --prefix PATH : $out/bin:${path} --set CDRIP_MODE ship
  '';
  passthru = { inherit ffmpeg; };
  meta.mainProgram = "mediagrab";
}
