# Example ~/.config/oligarchy/local.nix
#
# COPY what you need out of this file. It is not imported by anything: the
# module ships OFF and nothing in the distro turns it on for you.
#
# configuration.nix picks up ~/.config/oligarchy/local.nix when it exists, and
# once it does every rebuild needs --impure:
#   sudo nixos-rebuild switch --flake .#nixos --impure
# Pure eval does not error, it silently uses the fresh-clone defaults — i.e.
# your vault stays off and you spend an hour wondering why.
{ ... }:

{
  custom.vault = {
    enable = true;

    # Portable blobs. Public keys only — this list is world-readable in
    # /etc/oligarchy/vault-recipients and in /nix/store.
    age.recipients = [
      # age-keygen -o ~/.config/oligarchy/vault.key, then paste its public key:
      # "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
      # or an ssh public key you already carry:
      # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... asher@oligarchy"
    ];

    # Native ext4/F2FS encryption, unlocked by your login password via PAM.
    # Wrong filesystem (btrfs, ZFS) → use gocryptfs below instead.
    fscrypt = {
      enable = false;
      # Reminder list only. Run `oligarchy-vault init-fscrypt DIR` yourself on
      # an EMPTY directory; the module refuses to do this at activation.
      directories = [ "/home/asher/Private" ];
    };

    # FUSE overlay: works anywhere, including btrfs, ZFS and network shares.
    gocryptfs = {
      enable = false;

      # Only needed if some mount below sets allowOther = true.
      userAllowOther = false;

      mounts.notes = {
        cipherDir = "/home/asher/.vaults/notes.cipher";
        mountPoint = "/home/asher/Vaults/notes";

        # autoMount needs a passFile: login has no TTY to prompt on.
        # This path is read at RUNTIME. Never a Nix path literal, never
        # something under /nix/store — the module asserts on both.
        # passFile = "/run/media/asher/KEY/notes.pass";
        # autoMount = true;
      };
    };
  };
}
