# cdrip and cdrip-ship (the same script; the second wrapper sets CDRIP_MODE=ship), with their
# runtime tools pinned on PATH so the unit does not depend on the system
# profile. fleet-notify is the exception: it is host config, found at run
# time and skipped if absent.
{ lib, stdenvNoCC, makeWrapper, bash, cyanrip, flac, rsync, openssh,
  coreutils, findutils, gnugrep, gnused, util-linux }:

stdenvNoCC.mkDerivation {
  pname = "cdrip";
  version = "0.1.0";
  src = ./cdrip.sh;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -Dm755 $src $out/libexec/cdrip
    patchShebangs $out/libexec/cdrip
    path=${lib.makeBinPath [ bash cyanrip flac rsync openssh coreutils findutils gnugrep gnused util-linux ]}
    makeWrapper $out/libexec/cdrip $out/bin/cdrip --prefix PATH : $path
    makeWrapper $out/libexec/cdrip $out/bin/cdrip-ship --prefix PATH : $path --set CDRIP_MODE ship
  '';
  meta.mainProgram = "cdrip";
}
