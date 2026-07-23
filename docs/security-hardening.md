# Security Hardening Runbook

The phased rollout for the Oligarchy security overhaul. Each phase leaves the
system bootable and buildable. Do one `nixos-rebuild dry-build` per phase before
switching (full-closure evals are slow on this machine — batch them).

Rollback at any point:

```bash
sudo nixos-rebuild switch --rollback     # previous generation
sudo nixos-rebuild list-generations      # or pick a specific one to boot
```

---

## Phase 0 — Pre-flight (do this before switching to keys-only SSH)

1. **Prove key login works before passwords are disabled.** The hardening
   module refuses to build (lockout-guard assertion) unless a key is declared
   for `asher`, but a declared key is not the same as a *working* key:

   ```bash
   ls ~/.ssh/*.pub || ssh-keygen -t ed25519
   ssh -o PreferredAuthentications=publickey asher@<host> true   # must succeed
   ```

   The three declared keys live in `configuration.nix` under
   `users.users.asher.openssh.authorizedKeys.keys`. Remove any you don't
   recognize.

2. **Generate the sops age key outside the repo** (never in `/nix/store`):

   ```bash
   sudo mkdir -p /var/lib/sops-nix
   sudo age-keygen -o /var/lib/sops-nix/key.txt
   sudo chmod 600 /var/lib/sops-nix/key.txt
   ```

   Put the printed **public** key into `.sops.yaml` (replace the placeholder),
   then encrypt any real secret:

   ```bash
   sops --encrypt modules/secrets/dcf-id.env > modules/secrets/dcf-id.enc.env
   # plaintext *.env is git-ignored; *.enc.env is safe to commit
   ```

3. **Branch + note rollback point:**

   ```bash
   git switch -c security-overhaul
   sudo nixos-rebuild list-generations | tail -3
   ```

---

## Phase 1–3 — hygiene, SSH/auth, rootless Docker (this changeset)

These are applied together. What changed:

- **Firewall:** dropped stale Sunshine ports; `tailscale0` is no longer a
  trusted interface (SSH is admitted per-interface instead); MAC randomization
  on scan; avahi no longer advertises host metadata.
- **SSH:** keys-only, `AllowUsers asher`, `MaxAuthTries 3`, fail2ban
  (`custom.security.hardening`, preset `hardened`). AppArmor/auditd ship in the
  module but stay off until Phase 6.
- **Docker → rootless:** `virtualisation.docker.rootless`. `asher` removed from
  the root-equivalent `docker` group; `render` added for ROCm.
- **Ollama:** binds `127.0.0.1` and no longer auto-opens the firewall.
- **DSP VM:** QEMU no longer runs as root; port-forwards bind `127.0.0.1`.
- **Secrets:** sops-nix wired with the key path outside the store; the plaintext
  `dcf-id.env` is untracked.

Verify after switch:

```bash
ss -tlnp                              # 11434 bound to 127.0.0.1, no stray ports
echo "$DOCKER_HOST"                   # unix://.../docker.sock (rootless)
ai-stack start && curl 127.0.0.1:11434/api/tags
fail2ban-client status sshd
oligarchy-security status
# from another machine: password auth rejected, key accepted (LAN + tailscale)
```

If ROCm inference fails under rootless docker, confirm `asher` is in `render`
(`id asher`) and `/dev/kfd` is group-accessible; CPU inference is the fallback.

**Migration note:** rootless docker re-pulls images into `~/.local/share/docker`.
Ollama models survive via the bind mount, so only image layers re-download:

```bash
ai-stack stop; docker compose ... # ai-stack handles this; first start re-pulls
```

---

## Phase 4 — Strict egress: dry-run → enforce

Ships enabled in **dry-run** (`recovery.dryRun = true`): it logs what it *would*
block without dropping anything. It runs as a standalone `table inet
strict-egress` (an `output` hook) that coexists with the iptables firewall and
`demod-ip-blocker`.

```bash
oligarchy-security egress status
journalctl -k -g STRICT-EGRESS-WOULDBLOCK -f   # soak a few days
```

Add anything legitimately blocked to `networking.firewall.strictEgress.allow`:

- `allow.domains` — hostnames (resolved into the dynamic set daily)
- `allow.ips` — CIDRs (static set)
- `allow.ports` — e.g. `{ port = 41641; proto = "udp"; }` for WireGuard
- `allow.uids` — daemons with IP-diverse endpoints (e.g. `"tailscaled"`) that
  should bypass filtering entirely

Tailscale note: DERP relays are IP-diverse. Either add the DERP domains, or add
`allow.uids = [ "tailscaled" ]` as the escape hatch.

When the WOULDBLOCK log is quiet, enforce:

```nix
networking.firewall.strictEgress.recovery.dryRun = false;
```

`recovery.failOpen = true` (default) flushes the egress chain if
`cache.nixos.org` is unreachable after enforcement, so a bad allowlist can't
brick `nixos-rebuild`. Manual escape hatch:

```bash
sudo nft flush chain inet strict-egress egress   # open egress immediately
sudo nft delete table inet strict-egress         # remove the table entirely
```

---

## Phase 5 — Malware Shield: monitor → quarantine

Ships enabled at `level = "monitor"` (log + notify only). Verify:

```bash
oligarchy-security scan quick
printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt
malware-shield-yara /tmp        # should log an EICAR event
oligarchy-security events
systemctl list-timers | grep malware
systemctl status clamav-daemon clamav-freshclam
```

Full-closure scan at build time:

```bash
nix build .#malwareScan         # fails the build on a signature hit
```

After ~two weeks with a clean `events.log`, raise enforcement:

```nix
custom.malwareShield.level = "quarantine";   # or "enforce"
# custom.malwareShield.clamav.onAccess = true;  # real-time; DSP latency cost
```

Quarantine lives at `/var/lib/malware-shield/quarantine` (restore manually as
root). `rootkit` uses lynis + unhide (rkhunter/chkrootkit aren't in nixpkgs
25.11). AIDE watches `/etc /boot /root /run/current-system` — never `/nix/store`.

---

## Phase 6 — AppArmor / auditd (after a soak)

```nix
custom.security.hardening = { apparmor = true; auditd = true; };
```

Switch, then watch for a day:

```bash
journalctl -g apparmor -p warning      # denials
journalctl -t audit                    # audit events
```

USBGuard stays opt-in (paranoid preset). To enroll present devices:

```bash
oligarchy-security usb generate-policy   # then set custom.security.hardening.usbguard = true
```

---

## Tests

```bash
nix build -f tests/default.nix strict-egress
nix build -f tests/default.nix malware-shield
nix build -f tests/default.nix hardening
```

(These VM tests are intentionally not in `nix flake check`, which already builds
the full closure.)

---

## sops key rotation

1. `age-keygen -o /var/lib/sops-nix/key.txt.new`
2. Add the new public key to `.sops.yaml`, `sops updatekeys modules/secrets/*.enc.env`
3. Swap the key file, remove the old recipient, re-`updatekeys`, rebuild.
