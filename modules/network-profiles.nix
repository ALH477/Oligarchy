# ═══════════════════════════════════════════════════════════════════════════════
# Trusted Wi-Fi profiles — declared in Nix, secrets from sops-nix
# ═══════════════════════════════════════════════════════════════════════════════
# custom.network.trustedWifi.<name> renders a NetworkManager keyfile through
# networking.networkmanager.ensureProfiles, so every Oligarchy host that
# carries the secrets file converges to the same connections and a reinstall
# needs no nmtui session. Only TRUSTED networks belong here: a declared
# profile pins DNS (ipv4.dns + ignore-auto-dns), which is right at home and at
# the office and wrong on a captive portal, where the venue's resolver is the
# only one that answers before login. Public networks are joined ad hoc.
#
# The PSK never enters the Nix store: the profile carries `$VAR`, and
# NetworkManager-ensure-profiles substitutes it at boot from a root-only
# env file — the sops-nix secret when custom.secrets.wifi.enable is on, or
# custom.network.trustedWifiSecretsFile for hosts (and the VM gate) without
# sops. `psk = "hunter2"` is refused at eval by the pskVar pattern.
{ config, lib, options, ... }:

let
  cfg = config.custom.network.trustedWifi;
  # `or false`: custom.secrets.enable is declared in modules/secrets.nix,
  # which a standalone import (the VM gate) does not carry.
  useSops = (config.custom.secrets.enable or false) && config.custom.secrets.wifi.enable;
  secretsFile =
    if useSops then config.sops.secrets."wifi-env".path
    else config.custom.network.trustedWifiSecretsFile;

  varPattern = "^[A-Z_][A-Z0-9_]*$";

  mkProfile = name: p: {
    connection = {
      id = name;
      type = "wifi";
      autoconnect = true;
      autoconnect-priority = p.priority;
    };
    wifi = {
      ssid = p.ssid;
      mode = "infrastructure";
    };
    wifi-security = {
      key-mgmt = p.security;
      psk = "$" + p.pskVar;
    } // lib.optionalAttrs (p.security == "sae") {
      # WPA3: management frame protection is mandatory, not optional.
      pmf = 3;
    };
    ipv4 = { method = "auto"; } // lib.optionalAttrs (p.dns != [ ]) {
      dns = lib.concatMapStrings (d: d + ";") p.dns;
      ignore-auto-dns = true;
    };
    ipv6 = {
      method = "auto";
      addr-gen-mode = "stable-privacy";
    };
  };
in
{
  options.custom.network = {
    trustedWifi = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          ssid = lib.mkOption {
            type = lib.types.str;
            description = "Network name. Not secret, but keep per-host lists in local.nix.";
          };
          pskVar = lib.mkOption {
            type = lib.types.strMatching varPattern;
            example = "HOME_PSK";
            description = ''
              Name of the variable in the secrets env file that holds the
              pre-shared key. The NAME, never the key: the profile is rendered
              with `$NAME` and substituted at boot.
            '';
          };
          dns = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "9.9.9.9" "149.112.112.112" ];
            description = "Resolvers to pin on this network. Empty keeps the DHCP-advertised ones.";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "connection.autoconnect-priority; higher wins when several are in range.";
          };
          security = lib.mkOption {
            type = lib.types.enum [ "wpa-psk" "sae" ];
            default = "wpa-psk";
            description = ''
              `wpa-psk` (WPA2) or `sae` (WPA3-Personal). An evil twin of a
              WPA2 network can record the 4-way handshake for offline PSK
              cracking; SAE makes that capture useless. Use `sae` wherever the
              access point supports it.
            '';
          };
        };
      });
      default = { };
      description = "Trusted Wi-Fi networks rendered as NetworkManager profiles.";
    };

    trustedWifiSecretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Root-only env file (`HOME_PSK=...`) substituted into the profiles when
        custom.secrets.wifi is not in use. Prefer the sops path; this exists
        for hosts without sops-nix and for the VM gate.
      '';
    };
  };

  options.custom.secrets.wifi.enable = lib.mkEnableOption ''
    the encrypted Wi-Fi env file (modules/secrets/wifi.enc.env, sops dotenv
    format: one VAR=psk line per trusted network). Decrypted to a root-only
    runtime path consumed by custom.network.trustedWifi
  '';

  config = lib.mkIf (cfg != { }) (lib.mkMerge [
    {
      assertions = [
        {
          assertion = secretsFile != null;
          message = ''
            custom.network.trustedWifi declares ${toString (lib.length (lib.attrNames cfg))} profile(s)
            but no secrets source: enable custom.secrets.wifi (sops) or set
            custom.network.trustedWifiSecretsFile.
          '';
        }
        {
          assertion = config.networking.networkmanager.enable;
          message = "custom.network.trustedWifi renders NetworkManager profiles; enable networking.networkmanager.";
        }
        {
          # A store path is world-readable, so a PSK in it is public on the
          # host and on every cache it is pushed to.
          assertion = secretsFile == null || !(lib.hasPrefix builtins.storeDir (toString secretsFile));
          message = "custom.network.trustedWifiSecretsFile must not be a Nix store path — the store is world-readable. Use a sops secret or a root-only file under /run or /var.";
        }
      ];

      networking.networkmanager.ensureProfiles = {
        # optional, not a bare list: with no source the assertion above is the
        # error the user should see, not a null-in-listOf-path type error.
        environmentFiles = lib.optional (secretsFile != null) secretsFile;
        profiles = lib.mapAttrs mkProfile cfg;
      };
    }

    # Guarded on the sops module being present at all (the VM gate imports
    # this file alone); a definition for an undeclared option is an eval
    # error even under mkIf false.
    (lib.optionalAttrs (options ? sops) {
      sops.secrets = lib.mkIf useSops {
        "wifi-env" = {
          format = "dotenv";
          sopsFile = ./secrets/wifi.enc.env;
          mode = "0400";
        };
      };
    })
  ]);
}
