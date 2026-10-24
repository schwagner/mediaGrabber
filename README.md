# mediaGrabber

Insert an audio CD; get verified, tagged FLAC with cover art in a remote
music library (Jellyfin, Navidrome, anything that watches a folder).

- **Rip:** [cyanrip](https://github.com/cyanreg/cyanrip) — cdparanoia-level
  error correction, AccurateRip verification, MusicBrainz metadata, Cover Art
  Archive art (embedded and as `cover.jpg`), `.log` and `.cue` per disc.
- **Trigger:** udev starts `cdrip@sr0.service` when a disc with audio
  tracks is inserted. Ejects when done.
- **Ship:** rsync over SSH to `dest/Album Artist/Album (Year)/`.
  Multi-disc sets share one folder.
- **Unknown discs** (not in MusicBrainz) are ripped untagged and kept in
  `/var/lib/cdrip/unmatched/` rather than polluting the library. Tag with
  Picard, then `cdrip-ship /var/lib/cdrip/unmatched/<stamp>/rip`.
- **Failures** leave the disc in the drive; retry with
  `sudo systemctl start cdrip@sr0`. Logs: `journalctl -u cdrip@sr0`.

## NixOS

```nix
inputs.mediagrabber.url = "github:schwagner/mediaGrabber";
# ...
imports = [ mediagrabber.nixosModules.default ];
services.cdrip = {
  enable = true;
  user = "andrew";                       # its SSH key must reach dest
  dest = "tinydaw.tf:/srv/media/music";
  offset = 6;                            # your drive's read offset
};
```

Find the drive offset once with a well-known disc: `cyanrip -f -d /dev/sr0`,
or look the drive up at <https://www.accuraterip.com/driveoffsets.htm>.
With a wrong offset every track reports an AccurateRip mismatch (the audio
is still fine, shifted by a few samples).

If `fleet-notify` is on PATH, each rip reports its outcome through it.
