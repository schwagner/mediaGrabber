# mediaGrabber for Noctalia

What the disc drive is doing, in the bar. Click it for the details.

| Bar | Meaning |
| --- | --- |
| disc / film / archive glyph + `42%` | ripping a CD / DVD / data disc |
| `?` | a popup is asking how to rip it |
| green tick | the last rip finished (for `recent_hours`, default 12) |
| red triangle | the last rip failed, or was interrupted |
| plain grey disc | nothing going on |

The panel has one card per drive: the disc (album, film, volume label),
the phase, the step (`track 3 of 12`, `0:47:12 of 2:16:03`, `1.2G of 4.3G`),
a progress bar with a time-left estimate, and the outcome once it is over.
Per card: the unit's journal in a terminal, and Eject when nothing is running.

## Where it comes from

`status.sh` (sourced by every ripper) writes `<drive>.json` under
`$MEDIAGRAB_STATUS` — `/var/lib/mediagrabber/status` with the NixOS module —
on every phase change, and a ticker rewrites it every 2 s during the long
step. The plugin only reads those files: once a second while something runs,
every 5 s otherwise. The JSON's fields are documented at the top of status.sh.

Progress is measured, not guessed:

- **CD** — cyanrip's own `track N, progress - P%` line, so it is per track.
  The overall figure assumes tracks of equal length.
- **DVD** — ffmpeg's `-progress` `out_time_us` against the title lengths.
- **Data** — bytes tar has read (`/proc/<pid>/io`) against `du`'s total.

A record still saying "ripping" whose process is gone, or that is from a
previous boot, is shown as **Interrupted**.

## Install

The package ships the plugin at `share/noctalia/plugins/mediagrab`, so it
always matches the scripts. nixos-config adds it from
`services.mediagrabber.package` where the service runs for that user.
