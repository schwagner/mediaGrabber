# mediaGrabber

Insert a disc; it ends up in your media library (Jellyfin, or anything
that watches a folder). Audio CDs become verified, tagged FLAC; video DVDs
become lossless MKV; data discs become one compressed tarball each in an
archive folder. NixOS module, everything open source.

When media appears in a drive, udev starts `mediagrab@sr0.service`, which
works out what the disc is:

| Disc | What happens |
|---|---|
| Audio CD | `cdrip`: cyanrip with AccurateRip, MusicBrainz tags, Cover Art Archive art → `music/Album Artist/Album (Year)/` |
| Video DVD, film | `dvdrip`: main title remuxed by ffmpeg's `dvdvideo` demuxer → `movies/Name/Name.mkv` |
| Video DVD, TV | each episode → `shows/Series/Season NN/Series SNNEMM.mkv`, numbered on from what is already there |
| Data CD/DVD/BD | `datarip`: mounted, tarred, zstd-compressed on the far side → `archive/Label_id.tar.zst` |
| Blu-ray video, blank disc | left alone, with a notification |

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

## Data discs

Anything that is not audio and not a readable video DVD — burned CD-Rs,
DVD-Rs of files, software discs, data BD-Rs — is archived whole, as files
(not an image):

```
archive/Photos_2009_2009-03-14-12-00-00-00.tar.zst   everything under Photos_2009_…/
archive/Photos_2009_2009-03-14-12-00-00-00.txt       tar -tvv listing, for grep
```

The name is the volume label plus the filesystem UUID (for ISO 9660, the
time the disc was mastered), so the same disc always gets the same name
and inserting it again just ejects it. Unpack with
`zstd -dc X.tar.zst | tar -xf -`.

The disc is mounted through udisks (udiskie usually got there first) and
read with tar; the plain tar stream goes over SSH and the far side runs
`zstd -T0 -15`, so the ripping laptop does no compression. That level runs
far faster than a drive reads; the far side needs `zstd` on PATH. A read
error keeps nothing and leaves the disc in the drive.

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
  data.dest  = "tinydaw.tf:/srv/archive";    # optional; null = leave alone
};
```

Logs: `journalctl -u mediagrab@sr0`. A failed rip leaves the disc in the
drive; retry with `sudo systemctl start mediagrab@sr0`.

Every run ends in one notification saying what the disc was and whether it
worked: a critical desktop popup for `user` that stays up until dismissed
(skipped if they are not logged in), and a `fleet-notify` message if that
is on PATH. A crash mid-rip still pops one.

Tests (no drive needed): `bash tests/dvdrip-test.sh` for the DVD
decisions, `bash tests/datarip-test.sh` for archiving.
