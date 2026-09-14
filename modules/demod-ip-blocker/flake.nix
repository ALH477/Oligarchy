{
  description = "DeMoD IP Blocker - Robust IPSet blocking module with Caching";

  # Vendored from github:ALH477/DeMoD-IP-Blocker (see the root flake.nix note
  # for the v6 grep pipeline fix). nixpkgs follows the parent lock.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.demod-ip-blocker;

        # Define set names
        setV4 = "demod-blk-v4";
        setV6 = "demod-blk-v6";

        # License Text
        licenseText = ''
          Copyright (c) 2026, DeMoD LLC
          All rights reserved.

          Redistribution and use in source and binary forms, with or without
          modification, are permitted provided that the following conditions are met:

          1. Redistributions of source code must retain the above copyright notice, this
             list of conditions and the following disclaimer.

          2. Redistributions in binary form must reproduce the above copyright notice,
             this list of conditions and the following disclaimer in the documentation
             and/or other materials provided with the distribution.

          3. Neither the name of the copyright holder nor the names of its
             contributors may be used to endorse or promote products derived from
             this software without specific prior written permission.

          THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
          AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
          IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
          DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
          FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
          DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
          SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
          CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
          OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
          OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        '';

        updateScript = pkgs.writeShellScriptBin "update-demod-blocklist" ''
          set -e
          set -o pipefail

          # Configuration
          URL="${cfg.url}"
          STATE_DIR="/var/lib/demod-ip-blocker"
          CACHE_FILE="$STATE_DIR/ips.txt"
          COUNTER_FILE="$STATE_DIR/boot_counter"
          
          SET_V4="${setV4}"
          SET_V6="${setV6}"
          TMP_V4="''${SET_V4}-tmp"
          TMP_V6="''${SET_V6}-tmp"
          
          # Dependencies
          CURL="${pkgs.curl}/bin/curl"
          IPSET="${pkgs.ipset}/bin/ipset"
          GREP="${pkgs.gnugrep}/bin/grep"
          AWK="${pkgs.gawk}/bin/awk"

          echo "Starting DeMoD IP Blocklist Service..."

          # --- Boot Counting Logic ---
          if [ ! -f "$COUNTER_FILE" ]; then echo "0" > "$COUNTER_FILE"; fi
          CURRENT_BOOT=$(<"$COUNTER_FILE")
          NEXT_BOOT=$((CURRENT_BOOT + 1))
          echo "$NEXT_BOOT" > "$COUNTER_FILE"

          SHOULD_FETCH=0
          
          # Fetch if:
          # 1. It is an ODD numbered boot (1, 3, 5...)
          # 2. OR the cache file is missing (fresh install or deleted)
          if [ $((NEXT_BOOT % 2)) -ne 0 ] || [ ! -f "$CACHE_FILE" ]; then
              SHOULD_FETCH=1
          fi

          if [ "$SHOULD_FETCH" -eq 1 ]; then
              echo "Boot #$NEXT_BOOT (Probing Boot): Fetching fresh data from API..."
              
              # Download to a temporary location first
              DOWNLOAD_TMP=$(mktemp)
              if $CURL -sS --fail --max-time 60 --retry 3 "$URL" -o "$DOWNLOAD_TMP"; then
                  # Validate: Not empty
                  if [ -s "$DOWNLOAD_TMP" ]; then
                      mv "$DOWNLOAD_TMP" "$CACHE_FILE"
                      echo "Download successful. Cache updated."
                  else
                      echo "Warning: Downloaded file was empty. Keeping old cache."
                      rm -f "$DOWNLOAD_TMP"
                  fi
              else
                  echo "Error: Download failed. Attempting to use existing cache."
                  rm -f "$DOWNLOAD_TMP"
              fi
          else
              echo "Boot #$NEXT_BOOT (Cached Boot): Skipping network probe."
          fi

          # --- Apply Rules from Cache ---
          if [ ! -s "$CACHE_FILE" ]; then
              echo "Critical Error: No cache file available and download failed/skipped. Cannot apply rules."
              exit 1
          fi

          echo "Processing rules from $CACHE_FILE..."
          
          # Create secure temporary directory for processing
          WORK_DIR=$(mktemp -d)
          trap 'rm -rf "$WORK_DIR"' EXIT

          RESTORE_FILE_V4="$WORK_DIR/restore_v4.txt"
          RESTORE_FILE_V6="$WORK_DIR/restore_v6.txt"

          # --- Prepare IPv4 Set ---
          echo "create $TMP_V4 hash:net family inet hashsize 4096 maxelem 200000 -exist" > "$RESTORE_FILE_V4"
          echo "flush $TMP_V4" >> "$RESTORE_FILE_V4"
          $GREP -v ":" "$CACHE_FILE" | $GREP "\." | $AWK -v set="$TMP_V4" '{print "add " set " " $1 " -exist"}' >> "$RESTORE_FILE_V4"
          echo "swap $TMP_V4 $SET_V4" >> "$RESTORE_FILE_V4"
          echo "destroy $TMP_V4" >> "$RESTORE_FILE_V4"

          # --- Prepare IPv6 Set ---
          echo "create $TMP_V6 hash:net family inet6 hashsize 4096 maxelem 200000 -exist" > "$RESTORE_FILE_V6"
          echo "flush $TMP_V6" >> "$RESTORE_FILE_V6"
          $AWK -v set="$TMP_V6" '/:/{print "add " set " " $1 " -exist"}' "$CACHE_FILE" >> "$RESTORE_FILE_V6"
          echo "swap $TMP_V6 $SET_V6" >> "$RESTORE_FILE_V6"
          echo "destroy $TMP_V6" >> "$RESTORE_FILE_V6"

          # Apply updates via restore
          echo "Applying IPv4 rules..."
          $IPSET restore < "$RESTORE_FILE_V4"
          
          echo "Applying IPv6 rules..."
          $IPSET restore < "$RESTORE_FILE_V6"

          echo "DeMoD IP Blocklist applied successfully."
        '';

      in
      {
        options.services.demod-ip-blocker = {
          enable = lib.mkEnableOption "DeMoD IP Blocker Service";

          url = lib.mkOption {
            type = lib.types.str;
            default = "https://storage.googleapis.com/spur-astrill-vpn/ips.txt";
            description = "The URL to fetch the blacklist text file from.";
          };

          updateInterval = lib.mkOption {
            type = lib.types.str;
            default = "24h";
            description = "Systemd timer interval for periodic updates (in addition to boot logic).";
          };
        };

        config = lib.mkIf cfg.enable {
          networking.firewall.extraPackages = [ pkgs.ipset ];

          # Initialize sets and iptables rules on boot/reload
          networking.firewall.extraCommands = ''
            ${pkgs.ipset}/bin/ipset create -exist ${setV4} hash:net family inet hashsize 4096 maxelem 200000
            ${pkgs.ipset}/bin/ipset create -exist ${setV6} hash:net family inet6 hashsize 4096 maxelem 200000
            
            ${pkgs.iptables}/bin/iptables -I INPUT -m set --match-set ${setV4} src -j DROP
            ${pkgs.iptables}/bin/ip6tables -I INPUT -m set --match-set ${setV6} src -j DROP
          '';

          networking.firewall.extraStopCommands = ''
            ${pkgs.iptables}/bin/iptables -D INPUT -m set --match-set ${setV4} src -j DROP || true
            ${pkgs.iptables}/bin/ip6tables -D INPUT -m set --match-set ${setV6} src -j DROP || true
            ${pkgs.ipset}/bin/ipset destroy ${setV4} || true
            ${pkgs.ipset}/bin/ipset destroy ${setV6} || true
          '';

          systemd.services.demod-ip-blocker-update = {
            description = "DeMoD IP Blocker Update Service";
            wants = [ "network-online.target" ];
            after = [ "network-online.target" "firewall.service" ];

            # Create persistent storage for cache and boot counter
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              StateDirectory = "demod-ip-blocker"; # Creates /var/lib/demod-ip-blocker
              ExecStart = "${updateScript}/bin/update-demod-blocklist";

              # Hardening
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              NoNewPrivileges = true;
              ProtectKernelTunables = true;
              ProtectControlGroups = true;
              RestrictNamespaces = true;
              LockPersonality = true;
            };
          };

          systemd.timers.demod-ip-blocker-update = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "2m";
              OnUnitActiveSec = cfg.updateInterval;
              RandomizedDelaySec = "5m";
              Persistent = true;
            };
          };

        };
      };
  };
}
