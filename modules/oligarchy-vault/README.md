# oligarchy-vault

User-data encryption for Oligarchy: encrypted archives you can move around,
and live directories that are encrypted at rest.

This is **not** NixOS activation secrets (that is `custom.secrets` /
agenix / sops-nix) and **not** full-disk encryption (that is LUKS, set up by
the installer). It also does not wrap the distro: it is a path subflake that
adds one module, `custom.vault`, and one CLI, `oligarchy-vault`.

Everything defaults to **off**.

## Wiring

In the parent `flake.nix`:

```nix
inputs = {
  # …
  oligarchy-vault = {
    url = "path:./modules/oligarchy-vault";
    # Without this follows the subflake pins a SECOND nixpkgs and you build
    # two closures.
    inputs.nixpkgs.follows = "nixpkgs";
  };
};

outputs = { self, nixpkgs, oligarchy-vault, ... }@inputs:
  let
    commonModules = [
      # …
      oligarchy-vault.nixosModules.default
    ];
  in
  # …
```

Then turn it on where toggles live — `configuration.nix` or
`~/.config/oligarchy/local.nix`, never in the module:

```nix
custom.vault = {
  enable = true;
  age.recipients = [ "age1…" ];
};
```

See [`example-local.nix`](./example-local.nix) for a fuller example.

## Backends

Pick by job, not by taste. All are off except `age` (which follows
`custom.vault.enable`).

| Backend | Use it for | Filesystems | Leaks | Unlock |
| --- | --- | --- | --- | --- |
| `age` | portable `.tar.gz.age` blobs: backups, things you email or carry | any | nothing (blob is opaque) | recipient key or passphrase, at `unpack` time |
| `fscrypt` | a live directory that must be encrypted at rest | ext4 with the `encrypt` feature, or F2FS. **Not btrfs, not ZFS** | file sizes, timestamps, permissions (contents and filenames are encrypted) | your login password, via PAM |
| `gocryptfs` | a live directory where fscrypt cannot go: btrfs, ZFS, network shares, removable media | any (FUSE) | sizes, timestamps, directory structure | passphrase, or a runtime `passFile` |

Two constraints that drive the whole design:

- **fscrypt cannot encrypt in place.** The kernel only marks an *empty*
  directory. Protecting existing data means: make an empty directory, encrypt
  it, move the data in, destroy the plaintext copy. That is interactive and
  destructive, so the module never does it at activation — `fscrypt.directories`
  is documentation only.
- **The NixOS option is `security.pam.enableFscrypt`.** There is no
  `security.fscrypt.enable`; writing it is an eval error, not a no-op.

## CLI

```
oligarchy-vault pack <path> [out.tar.gz.age]   encrypt a file or dir to an age blob
oligarchy-vault unpack <blob> [dest]           decrypt into dest (default .)
oligarchy-vault init-gocryptfs <cipherDir>     create a cipher directory
oligarchy-vault mount <name>                   mount a declared vault
oligarchy-vault umount <name|mountpoint>       unmount it
oligarchy-vault init-fscrypt <dir>             mark an EMPTY dir encrypted
oligarchy-vault status                         backends, recipients, vaults
```

- `pack` encrypts to `/etc/oligarchy/vault-recipients` when that file has
  entries, otherwise falls back to `age -p` (passphrase). Archives always use
  `tar -C <parent> -cz <name>`, so member names are relative and an unpack in
  the wrong directory cannot overwrite the original.
- `unpack` tries `$OLIGARCHY_VAULT_IDENTITY` (default `~/.ssh/id_ed25519`),
  then falls back to a passphrase. **age does not use ssh-agent** — it reads
  key files. A passphrase-protected ssh key prompts you directly; `ssh-add`
  changes nothing.
- `mount NAME` reads `/etc/oligarchy/vault-mounts.json`, which is generated
  from `custom.vault.gocryptfs.mounts`. That file holds mount points and the
  *path* of a passfile, never its contents.
- `init-fscrypt` refuses a non-empty directory, for the reason above.

## What it will not do

- Put a passphrase, an age private key, or a `passFile`'s contents in
  `/nix/store`. `passFile` is a `str`, not a `path`, and an assertion rejects
  anything starting with `/nix/store/`.
- Auto-mount without a runtime `passFile`. There is no TTY at login to prompt
  on, so `autoMount = true` without `passFile` is an assertion failure rather
  than a unit that hangs forever.
- Encrypt anything at activation time, in place, or behind your back.
- Manage activation secrets (`custom.secrets`), LUKS, or dm-crypt.
- Run any always-on service. With `custom.vault.enable = false` the module
  adds no PAM change, no FUSE config, and no units — which is why the ISO
  needs no `mkForce` to undo it.

Blobs are already covered by the repo `.gitignore` (`*.age`), so a `pack`
output landing in the worktree cannot be committed by accident. Do not add an
exception for it.
