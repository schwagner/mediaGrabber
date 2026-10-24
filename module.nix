# ============================================================
# module.nix — services.cdrip: rip every audio CD inserted, ship to a library
#
# Contains:
#   - services.cdrip.{enable,user,dest,offset,package}
#   - a udev rule that starts cdrip@<kernel name>.service when a disc with
#     audio tracks appears in any sr* drive
#   - the cdrip@ template unit (one rip per drive, runs as `user`)
#   - a polkit rule letting `user` block sleep from outside a session
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
  cfg = config.services.cdrip;
in
{
  options.services.cdrip = {
    enable = lib.mkEnableOption "automatic CD ripping to FLAC on disc insert";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "The cdrip package.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "andrew";
      description = ''
        Account the rip runs as. Its SSH key must reach `dest`, and the
        staging area /var/lib/cdrip is owned by it.
      '';
    };

    dest = lib.mkOption {
      type = lib.types.str;
      example = "tinydaw.tf:/srv/media/music";
      description = ''
        rsync destination, host:path. Albums land in
        path/Album Artist/Album (Year)/.
      '';
    };

    offset = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = ''
        Drive read offset in samples. Find it once with a disc that is in
        AccurateRip: `cyanrip -f`, or the drive's entry at
        accuraterip.com/driveoffsets.htm. Wrong offset = every track
        reports an AccurateRip mismatch.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.udev.extraRules = ''
      SUBSYSTEM=="block", KERNEL=="sr[0-9]*", ACTION=="change", ENV{ID_CDROM_MEDIA_TRACK_COUNT_AUDIO}=="?*", RUN+="${pkgs.systemd}/bin/systemctl --no-block start cdrip@%k.service"
    '';

    systemd.services."cdrip@" = {
      description = "Rip audio CD in /dev/%i to FLAC";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # fleet-notify (or any notifier) comes from the system profile.
      path = [ "/run/current-system/sw" ];
      environment = {
        CDRIP_DEST = cfg.dest;
        CDRIP_OFFSET = toString cfg.offset;
        CDRIP_STATE = "/var/lib/cdrip";
      };
      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        SupplementaryGroups = [ "cdrom" ];
        StateDirectory = "cdrip";
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:idle --who=cdrip --why='Ripping CD' ${lib.getExe cfg.package} /dev/%i";
        TimeoutStartSec = "infinity";
      };
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.login1.inhibit-block-sleep" &&
            subject.user == "${cfg.user}") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
