# ═══════════════════════════════════════════════════════════════════════════════
# custom.mounts — UUID-pinned volumes, and swapfiles that are ordered after them
# ═══════════════════════════════════════════════════════════════════════════════
#
# PLAIN `fileSystems` STAYS LEGAL AND CORRECT. If a volume is neither removable
# nor the home of a swapfile, write the three lines and move on:
#
#   fileSystems."/mnt/scratch" = {
#     device = "/dev/disk/by-uuid/…"; fsType = "ext4"; options = [ "nofail" ];
#   };
#
# That is already declarative, already ordered by systemd, and is exactly what
# modules/reliquary/nix/module.nix does. This module is NOT nicer syntax for it
# and nothing whose only merit is nicer syntax belongs here. It exists for two
# things `fileSystems` cannot do, both of which have already cost a switch:
#
#   1. REFUSE A NON-IDENTITY DEVICE STRING AT EVAL TIME.
#      `fileSystems` happily accepts
#        device = "/run/media/asher/a82fcfcf-e913-413e-ab4f-4a3b104b2de0"
#      and so did `swapDevices`, which is precisely how this host ended up with
#      a declarative swap unit hung off a *udisks2 automount path*. That path is
#      session-dependent: it exists only while a logged-in desktop session has
#      asked udisks2 to mount the volume, under a directory udisks2 invents. A
#      systemd unit generated at build time cannot depend on a desktop session,
#      so the .swap unit failed on every single `nixos-rebuild switch` — loudly
#      enough to notice, vaguely enough to ignore for months. Here, a device is
#      declared as `uuid` or `partuuid` and NOTHING ELSE: there is no option to
#      type a mountpoint-shaped string into, and `where` is asserted not to live
#      under /run or /media. This is the only mechanism in the tree that would
#      have caught that bug before the switch, and it also finally implements
#      the "pin by PARTUUID, not by a forgeable label" lesson that
#      modules/reliquary/docs/ADVERSARY_REVIEW.md records but never enforced.
#
#   2. ORDER A SWAPFILE AFTER ITS OWN MOUNT, AND CREATE IT CORRECTLY.
#      `swapDevices` has no `RequiresMountsFor`. NixOS's own `size = …`
#      auto-creation runs `truncate`/`fallocate`/`mkswap` and cannot do
#      `chattr +C`, which on btrfs is MANDATORY — the kernel refuses to swapon a
#      file with datacow still set, so `size =` on btrfs produces a 32 GiB file
#      that can never be used and a unit that fails after the disk is already
#      spent. Nor does anything create the swapfile's parent: the exact same
#      shape took out `services.ollamaAgentic.dedicatedSwap` on a completely
#      different filesystem (its parent directory did not exist, so `truncate`
#      failed, so `mkswap` failed, so the .swap unit failed). One code path here
#      fixes both classes.
#
# ── The hazard that shapes every default ──────────────────────────────────────
#
# `nofail` is unconditional and not a knob. On this machine
# `custom.vm.dsp.enable = true`, and starting the DSP VM binds 0000:c7:00.3/.4
# to vfio-pci — configuration.nix:584-586 puts it plainly: "every audio
# interface on that bus disappears from the host mid-session". A block device on
# such a bus vanishes the same way. A mount unit that something else *requires*
# then blocks a job indefinitely, and a blocked job during activation is
# indistinguishable from a hung rebuild. So: `nofail` always, automount and a
# short `x-systemd.device-timeout` for removables, and this module never emits a
# unit that another unit must wait on without a bound.
#
# ── Why the removable option set is what it is ────────────────────────────────
#
# `nosuid nodev noexec` on a removable volume is load-bearing, not hygiene, and
# the reasoning is lifted from modules/reliquary/nix/module.nix:39-60 rather
# than the option list being copied blindly. A volume identified by a UUID or a
# PARTUUID is identified by a number an attacker with physical access can simply
# write onto their own stick (`mkfs.ext4 -U <uuid>`; `sfdisk --part-uuid`). If
# such a stick is then mounted with on-disk permission bits honoured, a setuid
# root binary sitting on it executes as root for any local user: an at-rest
# identity weakness turns into a local privilege escalation. `x-systemd.automount`
# makes it worse, because the mount then fires on first *access* — a file
# manager, a backup scan, a `du` — rather than on a deliberate command. Nothing
# is ever executed from a data volume, so the three words cost nothing.
#
# Everything defaults OFF and, with `volumes = { }`, this module emits no
# fileSystems entry, no unit, no tmpfiles rule and no swapDevices entry — so the
# ISO needs no `mkForce` for it, the same property android-mirror,
# oligarchy-vault and reliquary have.
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.mounts;

  # One volume. Modelled on modules/oligarchy-vault/nixos-module.nix's
  # `mountModule`: an `attrsOf (submodule ...)` whose `name` supplies sane
  # per-instance defaults, and whose mistakes are caught by assertions that name
  # the offending attribute path rather than by a type error from unit
  # generation three modules away.
  volumeModule = { name, config, ... }: {
    options = {
      # ── Identity ──────────────────────────────────────────────────────────
      # types.str, NEVER types.path, for the same two reasons vault's `passFile`
      # is a str (nixos-module.nix:46-54): a Nix path literal gets copied into
      # the world-readable store, and — more to the point here — a path type
      # would coerce and normalise the value, defeating the whole purpose of
      # asserting on the *shape* of the string the user wrote.
      uuid = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "a82fcfcf-e913-413e-ab4f-4a3b104b2de0";
        description = ''
          Filesystem UUID, as `lsblk -o NAME,UUID` prints it. Rendered to
          /dev/disk/by-uuid/<uuid>. Exactly one of uuid / partuuid.
        '';
      };

      partuuid = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "5b1f6a2c-0e44-4a1d-8f3b-1b0c2d9e7a11";
        description = ''
          GPT partition UUID, as `lsblk -o NAME,PARTUUID` prints it. Rendered to
          /dev/disk/by-partuuid/<partuuid>. Required for removable volumes:
          a filesystem UUID travels with any image dd'd onto any stick, whereas
          a PARTUUID at least lives in the partition table of the device that
          was actually enrolled. Exactly one of uuid / partuuid.
        '';
      };

      fsType = lib.mkOption {
        type = lib.types.str;
        example = "btrfs";
        description = ''
          Filesystem type. Required, and load-bearing rather than decorative:
          NixOS derives `boot.supportedFilesystems` from the fsType of every
          `fileSystems` entry, which is what pulls the kernel module and the
          userspace progs into the closure. `boot.supportedFilesystems` is set
          nowhere in this tree outside the ISO, and no other `fileSystems` entry
          is btrfs, so declaring a btrfs volume here is also what makes
          btrfs-progs exist on the machine at all.
        '';
      };

      where = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/${name}";
        defaultText = lib.literalExpression ''"/mnt/<name>"'';
        example = "/mnt/data";
        description = ''
          Mount point. Asserted to be absolute and outside /run and /media —
          those are udisks2's session-scoped automount trees and are the bug
          this module exists to make unrepresentable.
        '';
      };

      # ── Behaviour ─────────────────────────────────────────────────────────
      removable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          This volume may be absent, and may be a device someone carried in.
          Adds nosuid, nodev and noexec, turns on automount, and bounds the
          device wait. See the banner comment: a forgeable identity plus
          automount plus honoured setuid bits is a local privilege escalation.
        '';
      };

      automount = lib.mkOption {
        type = lib.types.bool;
        default = config.removable;
        defaultText = lib.literalExpression "config.removable";
        description = ''
          Mount lazily on first access (x-systemd.automount) and unmount again
          after idleTimeout. Incompatible with a swapfile on the same volume.
        '';
      };

      idleTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Seconds of inactivity before an automounted volume is unmounted.";
      };

      deviceTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if config.removable then "10s" else null;
        defaultText = lib.literalExpression ''if config.removable then "10s" else null'';
        description = ''
          x-systemd.device-timeout for the mount. Short by default on removable
          volumes: a device on a bus that vfio-pci has taken over mid-session
          (see the DSP VM note in the banner) never comes back, and the default
          90s wait is 90s of a job nobody can explain. null omits the option.
        '';
      };

      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "compress=zstd" "noatime" ];
        description = ''
          Appended to the generated option list. Appended, never substituted:
          the safety set above cannot be removed through this option.
        '';
      };

      # ── Swapfile ──────────────────────────────────────────────────────────
      swapfile = lib.mkOption {
        default = { };
        description = "A swapfile living on this volume, created and ordered correctly.";
        type = lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Create a swapfile on this volume and register it in swapDevices.";
            };

            path = lib.mkOption {
              type = lib.types.str;
              default = "${config.where}/.swapfile";
              defaultText = lib.literalExpression ''"<where>/.swapfile"'';
              description = "Absolute path of the swapfile. Must be on this volume.";
            };

            sizeGB = lib.mkOption {
              type = lib.types.ints.positive;
              example = 32;
              description = ''
                Size in GiB. No default on purpose: a swapfile is disk you will
                never get back by accident, so the number is always written down
                by whoever asked for it.
              '';
            };

            priority = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              example = 10;
              description = ''
                Swap priority. Higher is used first, so a disk-backed
                last-resort tier wants a LOW number — zram sits at 100 on this
                distro. null leaves it to the kernel.
              '';
            };

            nodatacow = lib.mkOption {
              type = lib.types.bool;
              default = config.fsType == "btrfs";
              defaultText = lib.literalExpression ''config.fsType == "btrfs"'';
              description = ''
                chattr +C the file before allocating it. Defaults to true on
                btrfs because there it is not an optimisation: the kernel
                refuses to swapon a btrfs file that still has datacow set, and
                the attribute can only be set while the file is empty — which is
                exactly why NixOS's own `swapDevices.*.size` auto-creation
                cannot produce a working btrfs swapfile.
              '';
            };
          };
        };
      };
    };
  };

  volumes = cfg.volumes;

  deviceOf = v:
    if v.uuid != null
    then "/dev/disk/by-uuid/${v.uuid}"
    else "/dev/disk/by-partuuid/${v.partuuid}";

  optionsOf = v:
    # nofail first and unconditionally: see the banner. Never a knob.
    [ "nofail" ]
    ++ lib.optionals v.automount [
      "x-systemd.automount"
      "x-systemd.idle-timeout=${toString v.idleTimeout}"
    ]
    ++ lib.optionals v.removable [ "nosuid" "nodev" "noexec" ]
    ++ lib.optional (v.deviceTimeout != null) "x-systemd.device-timeout=${v.deviceTimeout}"
    ++ v.extraOptions;

  mkswapUnit = name: "oligarchy-mkswapfile-${name}.service";

  swapVolumes = lib.filterAttrs (_: v: v.swapfile.enable) volumes;

  isAbsolute = p: lib.hasPrefix "/" p;

  # /run and /media are udisks2 territory. Checked as "is it that directory, or
  # under it" rather than a bare hasPrefix, so /runtime-data is not refused.
  underAny = dirs: p: lib.any (d: p == d || lib.hasPrefix "${d}/" p) dirs;
in
{
  options.custom.mounts = {
    enable = lib.mkEnableOption "declarative UUID-pinned volumes and their swapfiles";

    volumes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule volumeModule);
      default = { };
      example = lib.literalExpression ''
        {
          data = {
            uuid = "a82fcfcf-e913-413e-ab4f-4a3b104b2de0";
            fsType = "btrfs";
            where = "/mnt/data";
            swapfile = { enable = true; sizeGB = 32; priority = 10; };
          };
        }
      '';
      description = "Volumes to mount by stable identity, keyed by a short name.";
    };
  };

  config = lib.mkMerge [
    # Declaring volumes without flipping the master switch would otherwise be
    # completely silent — the same shape of failure the module exists to kill.
    (lib.mkIf (volumes != { } && !cfg.enable) {
      warnings = [
        "custom.mounts.volumes declares ${toString (builtins.length (builtins.attrNames volumes))} volume(s) but custom.mounts.enable = false, so nothing is mounted and no swapfile is created."
      ];
    })

    (lib.mkIf (cfg.enable && volumes != { }) {
      # ── Assertions ──────────────────────────────────────────────────────────
      # Per-volume, via mapAttrsToList, each message naming the exact attribute
      # path — the idiom at modules/oligarchy-vault/nixos-module.nix:182-214.
      assertions =
        lib.mapAttrsToList
          (name: v: {
            assertion = (v.uuid == null) != (v.partuuid == null);
            message = "custom.mounts.volumes.${name}: set exactly one of `uuid` or `partuuid` (currently ${if v.uuid == null && v.partuuid == null then "neither" else "both"}). A mountpoint, a label or a /dev/sdX name is not an identity and is not accepted here.";
          })
          volumes
        ++ lib.mapAttrsToList
          (name: v: {
            assertion = isAbsolute v.where && !(underAny [ "/run" "/media" ] v.where);
            message = "custom.mounts.volumes.${name}.where = \"${v.where}\" must be an absolute path outside /run and /media. /run/media/<user>/<uuid> and /media/<user>/<label> are udisks2 AUTOMOUNT paths: they exist only while a desktop session has asked udisks2 to mount the volume, under a directory udisks2 chooses. A build-time systemd unit cannot depend on a desktop session, which is why the swapDevices entry that used to sit at that path failed on every rebuild. Use /mnt/${name} or another fixed mountpoint.";
          })
          volumes
        ++ lib.mapAttrsToList
          (name: v: {
            assertion = v.swapfile.enable -> !v.automount;
            message = "custom.mounts.volumes.${name}: swapfile.enable = true is incompatible with automount = true. An automount idles out and unmounts the filesystem; doing that under a live swapfile the kernel is still paging to is a foot-gun with no recovery path. Set automount = false (and note it defaults to `removable`).";
          })
          volumes
        ++ lib.mapAttrsToList
          (name: v: {
            assertion = v.removable -> v.partuuid != null;
            message = "custom.mounts.volumes.${name}: removable = true requires `partuuid`, not `uuid`. A filesystem UUID travels with any image written onto any stick, so it identifies a *filesystem someone made*, not the device you enrolled — the same weakness modules/reliquary/docs/ADVERSARY_REVIEW.md records for label-based pairing. A PARTUUID is at least a property of the partition table on the device itself.";
          })
          volumes
        ++ lib.mapAttrsToList
          (name: v: {
            assertion = v.swapfile.enable -> lib.hasPrefix "${v.where}/" v.swapfile.path;
            message = "custom.mounts.volumes.${name}.swapfile.path = \"${v.swapfile.path}\" is not under where = \"${v.where}\". The creation unit is ordered by RequiresMountsFor = ${v.where}, so a path elsewhere would be created — and swapped onto — with no guarantee its own filesystem is mounted. That is the failure this module exists to prevent.";
          })
          volumes;

      # Assertion 5 of the plan is deliberately a WARNING: chattr +C on a
      # non-btrfs filesystem is a no-op or an EOPNOTSUPP, not a correctness
      # problem, and refusing to evaluate over it would be out of proportion.
      warnings = lib.mapAttrsToList
        (name: _: "custom.mounts.volumes.${name}.swapfile.nodatacow is set on fsType = \"${volumes.${name}.fsType}\". chattr +C is a btrfs attribute; elsewhere it does nothing (and may fail). The default already tracks fsType, so this was set by hand.")
        (lib.filterAttrs (_: v: v.swapfile.enable && v.swapfile.nodatacow && v.fsType != "btrfs") volumes);

      # ── The mounts ──────────────────────────────────────────────────────────
      # EMIT `fileSystems`, do not replace it. Going around it with a hand-rolled
      # .mount unit would work and would also silently drop the fsType out of
      # `boot.supportedFilesystems`, leaving the mount to fail at boot for want
      # of a kernel module nothing asked for.
      fileSystems = lib.mapAttrs'
        (name: v: lib.nameValuePair v.where {
          device = deviceOf v;
          inherit (v) fsType;
          options = optionsOf v;
        })
        volumes;

      # systemd creates a mount unit's directory itself, so this is belt and
      # braces for the window in which the device is absent (nofail) and
      # something still expects the path to exist. Mode/owner are `-`
      # deliberately: with the volume already mounted this rule would otherwise
      # chmod/chown the root of a filesystem full of somebody's data.
      systemd.tmpfiles.rules = lib.mapAttrsToList (_: v: "d ${v.where} - - - -") volumes;

      # ── Swapfile creation ───────────────────────────────────────────────────
      # A oneshot, not `system.activationScripts` (where this body used to live
      # on hosts/asher) and not `swapDevices.*.size`. Activation is the wrong
      # place twice over: it runs before systemd has mounted anything, so the
      # old script had to test `mountpoint -q` and skip silently when the answer
      # was no — which it always was — and a rebuild-time script cannot be
      # re-run by systemd when the volume shows up later.
      #
      # No wantedBy. The unit is pulled in solely by the .swap unit's
      # `x-systemd.requires=`, so if nothing swaps here, nothing runs, and a
      # missing volume costs a skipped condition rather than a blocked job.
      systemd.services = lib.mapAttrs'
        (name: v: lib.nameValuePair "oligarchy-mkswapfile-${name}" {
          description = "Create the swapfile for custom.mounts.volumes.${name} on ${v.where}";

          unitConfig = {
            # The whole point. `swapDevices` has no equivalent, and this is the
            # precondition nobody owned in either of the two swap failures.
            RequiresMountsFor = v.where;
            # Idempotent and cheap: an existing swapfile is left exactly alone,
            # including its size. Resizing is a deliberate manual act (swapoff,
            # rm, rebuild), never something a rebuild does to a live system.
            ConditionPathExists = "!${v.swapfile.path}";
          };

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          path = [ pkgs.coreutils pkgs.util-linux pkgs.e2fsprogs ];

          # `set -eu` and NO `|| true` on chattr, unlike the activation script
          # this replaces. On btrfs a swapfile that missed `chattr +C` is not
          # degraded, it is unusable — the kernel refuses to swapon it — and the
          # attribute cannot be set after data has been allocated. Swallowing
          # the error there buys a 32 GiB file that can never be swapped to and
          # a failure that surfaces one unit later with an unrelated message.
          script = ''
            set -eu
            truncate -s 0 ${lib.escapeShellArg v.swapfile.path}
            ${lib.optionalString v.swapfile.nodatacow ''
              chattr +C ${lib.escapeShellArg v.swapfile.path}
            ''}
            fallocate -l ${toString v.swapfile.sizeGB}G ${lib.escapeShellArg v.swapfile.path}
            chmod 600 ${lib.escapeShellArg v.swapfile.path}
            mkswap ${lib.escapeShellArg v.swapfile.path}
          '';
        })
        swapVolumes;

      # ── The swapDevices entry ───────────────────────────────────────────────
      # `nofail`, because a volume that did not appear must not fail the boot.
      # `x-systemd.requires-mounts-for`, because systemd-fstab-generator does not
      # infer that a swapfile depends on the filesystem it is a file on.
      # `x-systemd.requires`, which adds both Requires= and After= on the
      # creation oneshot above — that is the edge that makes the unit run at all
      # and the edge that makes it run FIRST.
      swapDevices = lib.mapAttrsToList
        (name: v: {
          device = v.swapfile.path;
          options = [
            "nofail"
            "x-systemd.requires-mounts-for=${v.where}"
            "x-systemd.requires=${mkswapUnit name}"
          ];
        } // lib.optionalAttrs (v.swapfile.priority != null) {
          inherit (v.swapfile) priority;
        })
        swapVolumes;
    })
  ];
}
