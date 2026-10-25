# mediaGrabber

Insert a disc; it ends up in your media library (Jellyfin, or anything
that watches a folder). Audio CDs become verified, tagged FLAC; video DVDs
become lossless MKV. NixOS module, everything open source.

When media appears in a drive, udev starts `mediagrab@sr0.service`, which
works out what the disc is:

| Disc | What happens |
|---|---|
| Audio CD | `cdrip`: cyanrip with AccurateRip, MusicBrainz tags, Cover Art Archive art → `music/Album Artist/Album (Year)/` |
| Video DVD, film | `dvdrip`: main title remuxed by ffmpeg's `dvdvideo` demuxer → `movies/Name/Name.mkv` |
| Video DVD, TV | each episode → `shows/Series/Season NN/Series SNNEMM.mkv`, numbered on from what is already there |
| Blu-ray, data disc | left alone, with a notification |

Everything is shipped by rsync over SSH and the disc is ejected.

## CDs

- Several MusicBrainz releases for one disc: takes the first, and says so.
- Not in MusicBrainz: ripped untagged into `/var/lib/mediagrabber/cd/unmatched/`
  instead of the library. Tag it with Picard, then `cdrip-ship <dir>`.
- Set the drive's read offset once (`cyanrip -f -d /dev/sr0`), or every
  track reports an AccurateRip mismatch.

## DVDs

The DVD is **remuxed, not re-encoded**: MPEG-2 video, every audio track,
subtitles and chapters, untouched. Fast (read-speed bound) and lossless, at
4–8 GB a film. CSS is handled by libdvdcss.

A DVD carries no metadata except its volume label, so the name comes from
that: `THE_MATRIX_WS` → `The Matrix`, `FRIENDS_S1_D2` → Friends season 1.
Jellyfin then finds the film or show on TMDb by name; fix a wrong match
with *Identify*. TV discs must go in in order.

When guessing would be wrong, nothing is ripped: the disc stays in the
drive, and the notification lists the titles and the command to run:

- label is generic (`DVD_VIDEO`, `DISC1`)
- TV-shaped disc with no season in the label
- several titles of identical length (copy-protection decoys)
- nothing longer than 40 minutes

```sh
dvdrip /dev/sr0 movie "Cars (2006)" 3       # title 3 as the film
dvdrip /dev/sr0 show "The Office (US)" 2    # episodes as season 2
```

## NixOS

```nix
inputs.mediagrabber.url = "github:schwagner/mediaGrabber";
# ...
imports = [ mediagrabber.nixosModules.default ];
services.mediagrabber = {
  enable = true;
  user = "andrew";                           # its SSH key must reach the dests
  cd.dest = "tinydaw.tf:/srv/media/music";
  cd.offset = 6;
  dvd.movies = "tinydaw.tf:/srv/media/movies";
  dvd.shows  = "tinydaw.tf:/srv/media/shows";
};
```

Logs: `journalctl -u mediagrab@sr0`. A failed rip leaves the disc in the
drive; retry with `sudo systemctl start mediagrab@sr0`.

Every run ends in one notification saying what the disc was and whether it
worked: a critical desktop popup for `user` that stays up until dismissed
(skipped if they are not logged in), and a `fleet-notify` message if that
is on PATH. A crash mid-rip still pops one.

Tests for the DVD decisions (no drive needed): `bash tests/dvdrip-test.sh`.
