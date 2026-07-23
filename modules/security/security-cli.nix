# ═══════════════════════════════════════════════════════════════════════════════
# oligarchy-security — unified security status / scan / control CLI
# ═══════════════════════════════════════════════════════════════════════════════
# One front door over the scattered security subsystems (SSH, fail2ban, strict-
# egress, malware-shield, AppArmor/auditd/USBGuard, rootless docker). Consumed
# by oligarchy-ctl, the DCF tray, the greeter, and the MCP security_status tool
# via a cached /run/oligarchy-security/status.json so those never fork heavy
# commands.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.securityCli;
  runDir = "/run/oligarchy-security";
  statusJson = "${runDir}/status.json";

  securityCli = pkgs.writeShellScriptBin "oligarchy-security" ''
    set -u
    export PATH=${makeBinPath [ pkgs.systemd pkgs.gnugrep pkgs.gawk pkgs.coreutils pkgs.jq pkgs.openssh ]}:$PATH

    have() { command -v "$1" >/dev/null 2>&1; }

    q_ssh_password() {
      # Effective sshd setting (falls back to config grep if sshd -T unavailable)
      if have sshd; then
        sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}' | head -1
      else
        echo "unknown"
      fi
    }
    q_unit() { systemctl is-active "$1" 2>/dev/null || echo "inactive"; }
    q_egress_mode() {
      if systemctl is-enabled strict-egress-resolve.service >/dev/null 2>&1; then
        if grep -q "policy drop" /run/strict-egress/* 2>/dev/null; then echo "enforcing"; else echo "dry-run/active"; fi
      else echo "off"; fi
    }
    q_events() { [ -f /var/lib/malware-shield/events.log ] && wc -l < /var/lib/malware-shield/events.log || echo 0; }

    build_status() {
      local ssh_pw fail2ban egress clamd apparmor auditd usbguard docker_rootless events
      ssh_pw=$(q_ssh_password)
      fail2ban=$(q_unit fail2ban.service)
      egress=$(q_egress_mode)
      clamd=$(q_unit clamav-daemon.service)
      apparmor=$(q_unit apparmor.service)
      auditd=$(q_unit auditd.service)
      usbguard=$(q_unit usbguard.service)
      docker_rootless=$([ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" ] && echo yes || echo no)
      events=$(q_events)
      jq -n \
        --arg ssh_pw "$ssh_pw" --arg fail2ban "$fail2ban" --arg egress "$egress" \
        --arg clamd "$clamd" --arg apparmor "$apparmor" --arg auditd "$auditd" \
        --arg usbguard "$usbguard" --arg docker_rootless "$docker_rootless" \
        --argjson events "''${events:-0}" --arg ts "$(date -Is)" \
        '{ts:$ts, ssh_password_auth:$ssh_pw, fail2ban:$fail2ban, egress:$egress,
          clamav:$clamd, apparmor:$apparmor, auditd:$auditd, usbguard:$usbguard,
          docker_rootless:$docker_rootless, malware_events:$events}'
    }

    cmd_status() {
      local json; json=$(build_status)
      case "''${1:-}" in
        --json) echo "$json" ;;
        --oneline)
          echo "$json" | jq -r '"ssh:pw=\(.ssh_password_auth) egress:\(.egress) clamav:\(.clamav) events:\(.malware_events)"' ;;
        *)
          echo "$json" | jq -r '
            "── Oligarchy Security ──────────────────────",
            "SSH password auth : \(.ssh_password_auth)",
            "fail2ban          : \(.fail2ban)",
            "Strict egress     : \(.egress)",
            "ClamAV daemon     : \(.clamav)",
            "AppArmor          : \(.apparmor)",
            "auditd            : \(.auditd)",
            "USBGuard          : \(.usbguard)",
            "Docker rootless   : \(.docker_rootless)",
            "Malware events    : \(.malware_events)"' ;;
      esac
    }

    cmd_scan() {
      case "''${1:-quick}" in
        quick) have malware-shield-yara && malware-shield-yara /home /tmp || echo "malware-shield not enabled" ;;
        full)
          have malware-shield-yara && malware-shield-yara /home /tmp /var/tmp
          have malware-shield-rootkit && malware-shield-rootkit
          have malware-shield-aide && malware-shield-aide
          systemctl start clamav-scanner.service 2>/dev/null || true
          ;;
        *) echo "usage: oligarchy-security scan [quick|full]"; return 1 ;;
      esac
    }

    cmd_egress() {
      case "''${1:-status}" in
        status) have strict-egress-status && strict-egress-status || echo "strict-egress not enabled" ;;
        resolve) sudo strict-egress-resolve ;;
        test) shift; strict-egress-test "$@" ;;
        *) echo "usage: oligarchy-security egress {status|resolve|test <host>}"; return 1 ;;
      esac
    }

    cmd_quarantine() {
      local qdir=/var/lib/malware-shield/quarantine
      case "''${1:-list}" in
        list) sudo ls -la "$qdir" 2>/dev/null || echo "quarantine empty"; ;;
        restore) shift; echo "Restore manually (root): mv $qdir/$1 <dest>; chmod 644 <dest>" ;;
        *) echo "usage: oligarchy-security quarantine {list|restore <id>}"; return 1 ;;
      esac
    }

    cmd_events() { sudo tail -n "''${2:-20}" /var/lib/malware-shield/events.log 2>/dev/null || echo "no events"; }

    cmd_usb() {
      case "''${1:-}" in
        generate-policy) sudo usbguard generate-policy 2>/dev/null || echo "usbguard not enabled" ;;
        *) echo "usage: oligarchy-security usb generate-policy" ;;
      esac
    }

    case "''${1:-status}" in
      status)     shift 2>/dev/null; cmd_status "$@" ;;
      scan)       shift; cmd_scan "$@" ;;
      egress)     shift; cmd_egress "$@" ;;
      quarantine) shift; cmd_quarantine "$@" ;;
      events)     shift; cmd_events "$@" ;;
      usb)        shift; cmd_usb "$@" ;;
      cache-status) build_status > ${statusJson}.tmp && mv ${statusJson}.tmp ${statusJson} ;;
      *) echo "usage: oligarchy-security {status|scan|egress|quarantine|events|usb} ..."; exit 1 ;;
    esac
  '';
in
{
  options.custom.securityCli.enable = mkOption {
    type = types.bool;
    default = true;
    description = "Install the oligarchy-security CLI and its status-caching timer.";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ securityCli ];

    systemd.tmpfiles.rules = [ "d ${runDir} 0755 root root -" ];

    # Cache posture every 5 min so tray/greeter/MCP read a file, not fork tools.
    systemd.services.oligarchy-security-status = {
      description = "Cache Oligarchy security posture to ${statusJson}";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${securityCli}/bin/oligarchy-security cache-status";
      };
    };
    systemd.timers.oligarchy-security-status = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "5m";
        Persistent = true;
        Unit = "oligarchy-security-status.service";
      };
    };
  };
}
