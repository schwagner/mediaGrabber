# ============================================================
# module.nix — services.mediagrabber: rip every disc inserted, ship it on
#
# Contains:
#   - services.mediagrabber.{enable,user,package}
#   - services.mediagrabber.cd.{dest,offset}       audio CD -> FLAC
#   - services.mediagrabber.dvd.{enable,movies,shows}  video DVD -> MKV
#   - services.mediagrabber.data.dest              data disc -> .tar.zst
#   - a udev rule starting mediagrab@<kernel name>.service on any media
#     appearing in an sr* drive; mediagrab decides what the disc is
#   - the mediagrab@ template unit (one rip per drive, runs as `user`)
#   - cdrip/cdrip-ship/dvdrip/datarip on PATH with this config baked in, and `user`
#     in cdrom, so the commands the notifications suggest just work
#   - a polkit rule letting `user` block sleep from outside a session, and
#     (with data.dest) mount and unmount discs through udisks
#
# Was services.cdrip (CD only) until 0.2.0; the trigger moved from "has
# audio tracks" to "has media" when DVDs arrived, so that the detection
# lives in one script rather than in a growing set of udev matches.
#
# RUN AS THE USER, NOT A DynamicUser. The unit ships with that user's own
# SSH key and known_hosts, so the files land on the far side owned by
# them — which is what a library like /srv/media (owned by andrew, world-
# readable) wants. The cost is no ProtectHome; it reads ~/.ssh.
#
# RUN+= systemctl, NOT SYSTEMD_WANTS. The trigger is a "change" event on a
# device that already exists (the tray closing), and SYSTEMD_WANTS is only
# reliably honoured for the device's first appearance. A second change
# event for the same disc is harmless: starting a running unit is a no-op.
#
# SLEEP. The rip runs under systemd-inhibit --what=sleep:idle, which stops
# idle suspend mid-rip. logind's default only lets an *active session*
# take a sleep block, and a system unit is not in one — hence the polkit
# rule. Closing the lid still suspends (LidSwitchIgnoreInhibited=yes is
# logind's default) and that is left alone: closing a lid should do that.
# ============================================================
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mediagrabber;
  state = "/var/lib/mediagrabber";

  env = {
    CDRIP_DEST = cfg.cd.dest;
    CDRIP_OFFSET = toString cfg.cd.offset;
    CDRIP_STATE = "${state}/cd";
    DVDRIP_MOVIES = cfg.dvd.movies;
    DVDRIP_SHOWS = cfg.dvd.shows;
    DVDRIP_STATE = "${state}/dvd";
    MEDIAGRAB_DVD = if cfg.dvd.enable then "1" else "0";
  } // lib.optionalAttrs (cfg.data.dest != null) {
    DATARIP_DEST = cfg.data.dest;
    DATARIP_STATE = "${state}/data";
  };

  # The same commands with env baked in, for running by hand.
  configured = pkgs.runCommand "mediagrabber-configured" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    for b in ${cfg.package}/bin/*; do
      makeWrapper "$b" "$out/bin/$(basename "$b")" \
        ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--set ${k} ${lib.escapeShellArg v}") env)}
    done
  '';
in
{
  options.services.mediagrabber = {
    enable = lib.mkEnableOption "ripping every audio CD and video DVD inserted (and archiving data discs)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "The mediagrabber package.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "andrew";
      description = ''
        Account the rip runs as. Its SSH key must reach the destinations,
        it owns ${state}, and it is added to the cdrom group.
      '';
    };

    cd = {
      dest = lib.mkOption {
        type = lib.types.str;
        example = "tinydaw.tf:/srv/media/music";
        description = ''
          rsync destination for albums, host:path. They land in
          path/Album Artist/Album (Year)/.
        '';
      };
      offset = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = ''
          Drive read offset in samples. Find it once with a disc that is
          in AccurateRip: `cyanrip -f`. Wrong offset = every track reports
          an AccurateRip mismatch.
        '';
      };
    };

    dvd = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Rip video DVDs as well as audio CDs.";
      };
      movies = lib.mkOption {
        type = lib.types.str;
        example = "tinydaw.tf:/srv/media/movies";
        description = "rsync destination for films: path/Name/Name.mkv.";
      };
      shows = lib.mkOption {
        type = lib.types.str;
        example = "tinydaw.tf:/srv/media/shows";
        description = ''
          rsync destination for TV discs:
          path/Series/Season NN/Series SNNEMM.mkv.
        '';
      };
    };

    data.dest = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "tinydaw.tf:/srv/archive";
      description = ''
        Where data discs (anything not audio or video) are archived, as
        host:path: one Label_id.tar.zst per disc plus a Label_id.txt
        listing. Compressed by zstd on that host, which must have it on
        PATH. null leaves data discs alone.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ configured ];
    services.udisks2.enable = lib.mkIf (cfg.data.dest != null) true;
    users.users.${cfg.user}.extraGroups = [ "cdrom" ];

    services.udev.extraRules = ''
      SUBSYSTEM=="block", KERNEL=="sr[0-9]*", ACTION=="change", ENV{ID_CDROM_MEDIA}=="1", RUN+="${pkgs.systemd}/bin/systemctl --no-block start mediagrab@%k.service"
    '';

    systemd.services."mediagrab@" = {
      description = "Rip the disc in /dev/%i";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # fleet-notify (or any notifier) comes from the system profile.
      path = [ "/run/current-system/sw" ];
      environment = env;
      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        SupplementaryGroups = [ "cdrom" ];
        StateDirectory = "mediagrabber";
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:idle --who=mediagrabber --why='Ripping a disc' ${lib.getExe cfg.package} /dev/%i";
        TimeoutStartSec = "infinity";
      };
    };

    # datarip mounts through udisks from outside any session, which udisks
    # otherwise answers with auth_admin. Mount and unmount only — the -others
    # unmount because udiskie usually did the mounting.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.login1.inhibit-block-sleep" &&
            subject.user == "${cfg.user}") {
          return polkit.Result.YES;
        }
      });
    '' + lib.optionalString (cfg.data.dest != null) ''
      polkit.addRule(function(action, subject) {
        if ((action.id.indexOf("org.freedesktop.udisks2.filesystem-mount") == 0 ||
             action.id == "org.freedesktop.udisks2.filesystem-unmount-others") &&
            subject.user == "${cfg.user}") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
