# oligarchy-vault — user-data encryption.
#
# In scope:  encrypted archives you can carry (age), a live encrypted
#            directory on ext4/F2FS (fscrypt), a FUSE overlay for btrfs/ZFS
#            or a network share (gocryptfs).
# Out of scope: NixOS activation secrets (custom.secrets / agenix / sops-nix)
#            and whole-disk encryption (LUKS, done by the installer).
#
# Defaults OFF. custom.vault.enable is the master switch; turn it on in
# configuration.nix or ~/.config/oligarchy/local.nix, never here.
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.vault;

  # The primary user is a distro knob, not a constant: the ISO and any
  # non-asher install set custom.user.name. attrByPath keeps this module
  # evaluable in trees where custom.user does not exist at all.
  userName = lib.attrByPath [ "custom" "user" "name" ] "asher" config;
  userHome = "/home/${userName}";

  vaultCli = pkgs.callPackage ./pkgs/oligarchy-vault.nix { };

  mountModule = { name, ... }: {
    options = {
      cipherDir = lib.mkOption {
        type = lib.types.str;
        example = "/home/asher/.vaults/notes.cipher";
        description = "Directory holding the gocryptfs ciphertext. Created by `oligarchy-vault init-gocryptfs`, which requires it to be empty.";
      };

      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "${userHome}/Vaults/${name}";
        defaultText = lib.literalExpression ''"/home/''${custom.user.name}/Vaults/<name>"'';
        description = "Where the decrypted view appears while mounted.";
      };

      allowOther = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Pass -allow_other so other users (e.g. a service account) can see the mount. Requires custom.vault.gocryptfs.userAllowOther.";
      };

      passFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/secrets/vault-notes";
        description = ''
          Runtime path to a file containing the gocryptfs password, as a
          STRING. Deliberately not a path type: a Nix path literal would be
          copied into /nix/store, which is world-readable. Required for
          autoMount; otherwise gocryptfs prompts on the terminal.
        '';
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "-ro" ];
        description = "Extra flags passed to gocryptfs at mount time.";
      };

      autoMount = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount this vault from a systemd --user unit at login. Needs passFile: there is no TTY to prompt on.";
      };
    };
  };

  mounts = cfg.gocryptfs.mounts;

  # passFile != null is also an assertion below. It is filtered here too so a
  # misconfigured vault fails with that assertion's message instead of a
  # "expected a string, got null" type error from unit generation.
  autoMounts = lib.filterAttrs (_: m: m.autoMount && m.passFile != null) mounts;

  isStorePath = p: p != null && lib.hasPrefix "/nix/store/" p;

  # Public metadata only: mount points and the PATH of the passfile, never its
  # contents. Safe to land in /nix/store via environment.etc.
  mountsJson = builtins.toJSON (lib.mapAttrs
    (_: m: {
      inherit (m) cipherDir mountPoint allowOther passFile extraArgs autoMount;
    })
    mounts);

  # One shell script per auto-mounted vault instead of an inline ExecStart:
  # systemd's quoting rules are not shell quoting rules, and cipher dirs live
  # under $HOME where spaces happen. The script embeds the passFile PATH only.
  mountScript = name: m: pkgs.writeShellScript "oligarchy-vault-mount-${name}" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.fuse ]}:$PATH
    mkdir -p ${lib.escapeShellArg m.mountPoint}
    # -fg keeps gocryptfs in the foreground so systemd owns the process.
    # gocryptfs does not speak sd_notify, so Type=simple is the honest choice:
    # the unit is "started" before the mount is necessarily ready.
    exec gocryptfs -fg \
      -passfile ${lib.escapeShellArg m.passFile} \
      ${lib.optionalString m.allowOther "-allow_other"} \
      ${lib.escapeShellArgs m.extraArgs} \
      ${lib.escapeShellArg m.cipherDir} ${lib.escapeShellArg m.mountPoint}
  '';

  umountScript = name: m: pkgs.writeShellScript "oligarchy-vault-umount-${name}" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.fuse ]}:$PATH
    fusermount -u ${lib.escapeShellArg m.mountPoint} || true
  '';
in
{
  options.custom.vault = {
    enable = lib.mkEnableOption "oligarchy-vault user-data encryption (age / fscrypt / gocryptfs)";

    age = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        defaultText = lib.literalExpression "config.custom.vault.enable";
        description = "Install age and the pack/unpack side of the CLI. This is the portable-blob backend and the only one on by default.";
      };

      recipients = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... asher@oligarchy"
        ];
        description = ''
          PUBLIC recipients (age1… or ssh-ed25519 public keys) written to
          /etc/oligarchy/vault-recipients. `pack` encrypts to these; with an
          empty list it falls back to `age -p` (passphrase). Public keys only —
          never a private key or passphrase, this file is in the store.
        '';
      };
    };

    fscrypt = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Install fscrypt and unlock directories at login via PAM. ext4 (with the encrypt feature) or F2FS only — not btrfs, not ZFS.";
      };

      directories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/home/asher/Private" ];
        description = ''
          DOCUMENTATION ONLY: the directories you intend to protect, surfaced
          by `oligarchy-vault status`. Nothing is encrypted at activation, on
          purpose. fscrypt can only mark an EMPTY directory, so encrypting an
          existing path means moving data out and back in — a destructive,
          interactive operation that has no business running at switch time.
        '';
      };
    };

    gocryptfs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Install gocryptfs and expose declared mounts to the CLI. Use this where fscrypt cannot go: btrfs, ZFS, network shares, removable media.";
      };

      userAllowOther = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set user_allow_other in /etc/fuse.conf. Only needed if some mount sets allowOther.";
      };

      mounts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule mountModule);
        default = { };
        description = "Declared gocryptfs vaults, published to /etc/oligarchy/vault-mounts.json for `oligarchy-vault mount NAME`.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = mounts == { } || cfg.gocryptfs.enable;
          message = "custom.vault.gocryptfs.mounts is set but custom.vault.gocryptfs.enable = false.";
        }
      ]
      ++ lib.mapAttrsToList
        (name: m: {
          # A passFile under /nix/store is world-readable: that is not a
          # secret, that is a published password.
          assertion = !isStorePath m.passFile;
          message = "custom.vault.gocryptfs.mounts.${name}.passFile points into /nix/store. Use a runtime path (/run/secrets/…, a removable key, ~/.config/oligarchy/…).";
        })
        mounts
      ++ lib.mapAttrsToList
        (name: m: {
          # Login has no TTY for gocryptfs to prompt on.
          assertion = m.autoMount -> m.passFile != null;
          message = "custom.vault.gocryptfs.mounts.${name}.autoMount = true requires passFile; there is nothing to type a password into at login.";
        })
        mounts
      ++ lib.mapAttrsToList
        (name: m: {
          assertion = m.allowOther -> cfg.gocryptfs.userAllowOther;
          message = "custom.vault.gocryptfs.mounts.${name}.allowOther = true requires custom.vault.gocryptfs.userAllowOther = true (FUSE refuses -allow_other without user_allow_other in /etc/fuse.conf).";
        })
        mounts
      ++ [
        {
          assertion = cfg.fscrypt.directories == [ ] || cfg.fscrypt.enable;
          message = "custom.vault.fscrypt.directories is set but custom.vault.fscrypt.enable = false.";
        }
      ];

    warnings = lib.optional (cfg.fscrypt.directories != [ ])
      "custom.vault.fscrypt.directories is documentation only; run `oligarchy-vault init-fscrypt DIR` by hand on an empty directory.";

    environment.systemPackages =
      [ vaultCli ]
      ++ lib.optional cfg.age.enable pkgs.age
      # pkgs.fscrypt is the Go library; fscrypt-experimental is the CLI that
      # security.pam.enableFscrypt also uses.
      ++ lib.optional cfg.fscrypt.enable pkgs.fscrypt-experimental
      ++ lib.optional cfg.gocryptfs.enable pkgs.gocryptfs;

    environment.etc."oligarchy/vault-recipients" = lib.mkIf cfg.age.enable {
      text = lib.concatMapStrings (r: r + "\n") cfg.age.recipients;
      mode = "0444";
    };

    environment.etc."oligarchy/vault-mounts.json" = lib.mkIf cfg.gocryptfs.enable {
      text = mountsJson + "\n";
      mode = "0444";
    };

    # LOAD-BEARING: the option is security.pam.enableFscrypt. There is no
    # security.fscrypt.enable in NixOS — writing that is an eval error, not a
    # no-op. mkIf, not a plain bool: defining `false` here conflicts with any
    # other module that sets it true.
    security.pam.enableFscrypt = lib.mkIf cfg.fscrypt.enable true;

    programs.fuse.userAllowOther =
      lib.mkIf (cfg.gocryptfs.enable && cfg.gocryptfs.userAllowOther) true;

    # Only autoMount vaults get a unit. With autoMount = false (the default)
    # this is {} — no always-on services, nothing to mkForce off on the ISO.
    systemd.user.services = lib.mkIf cfg.gocryptfs.enable (lib.mapAttrs'
      (name: m: lib.nameValuePair "oligarchy-vault-${name}" {
        description = "gocryptfs vault ${name} at ${m.mountPoint}";
        wantedBy = [ "default.target" ];
        # Removable key not plugged in, secret not provisioned yet: skip
        # quietly instead of failing at every login.
        unitConfig.ConditionPathExists = m.passFile;
        serviceConfig = {
          Type = "simple";
          ExecStart = mountScript name m;
          ExecStop = umountScript name m;
          Restart = "no";
        };
      })
      autoMounts);
  };
}
