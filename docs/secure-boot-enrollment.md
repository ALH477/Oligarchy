# Secure Boot Enrollment for Vault Mode

Vault mode requires Secure Boot. This is a one-time setup.

## Prerequisites

- UEFI firmware with Secure Boot support (your Framework 16 has it)
- `sbctl` package (included when `custom.secureBoot.enable = true`)
- Physical access to the machine (BIOS access required)

## Step-by-Step

### 1. Create signing keys

```bash
sudo sbctl create-keys
```

This creates a PKI bundle at `/var/lib/sbctl/` with:
- Platform Key (PK)
- Key Exchange Key (KEK)
- Signature Database key (db)

### 2. Enable Secure Boot in NixOS config

In `configuration.nix`:
```nix
custom.secureBoot.enable = true;
```

Rebuild:
```bash
sudo nixos-rebuild switch --flake .#nixos
```

This installs lanzaboote (signed systemd-boot replacement).

### 3. Enter BIOS Setup Mode

1. Reboot → press F2 to enter BIOS
2. Navigate to Security → Secure Boot
3. Select "Clear Secure Boot Keys" or "Delete all keys"
4. The system is now in "Setup Mode" (no keys enrolled)
5. Save and exit (don't reboot yet — or reboot back into BIOS)

### 4. Enroll keys (from Linux)

Boot into NixOS (it will still boot without Secure Boot keys):

```bash
sudo sbctl enroll-keys
```

This enrolls YOUR keys only. No Microsoft keys, no third-party trust. Maximum lockdown.

### 5. Reboot and verify

```bash
sudo reboot
bootctl status | grep "Secure Boot"
```

Expected output:
```
Secure Boot: enabled
```

### 6. Enable vault mode

Now set in `configuration.nix`:
```nix
hardware.cpuSecurity = {
  enable = true;
  preset = "vault";
};
```

Rebuild:
```bash
sudo nixos-rebuild switch --flake .#nixos
```

## Verification

After enabling vault mode, verify:

```bash
# Secure Boot
bootctl status | grep "Secure Boot"  # → enabled

# Kernel lockdown
cat /sys/kernel/security/lockdown  # → [none] integrity confidentiality

# Module locking
cat /sys/kernel/module_locking  # → 1 (locked)

# All mitigations
grep -r . /sys/devices/system/cpu/vulnerabilities/  # → all mitigated

# Kernel config
zcat /proc/config.gz | grep SECURITY_LOCKDOWN  # → =y
```

## Recovery

If you brick Secure Boot (can't boot):
1. Enter BIOS → clear Secure Boot keys again
2. Boot into NixOS (no Secure Boot)
3. Set `custom.secureBoot.enable = false` and `hardware.cpuSecurity.preset = "hardened"`
4. Rebuild and reboot

## TPM2 LUKS Auto-Unlock (Optional)

After Secure Boot is working, you can bind LUKS to TPM2 for passwordless boot:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p2
```

PCR 0 = firmware code, PCR 7 = Secure Boot policy. If either changes (BIOS update, Secure Boot key change), TPM2 won't release the key and you'll fall back to password.
