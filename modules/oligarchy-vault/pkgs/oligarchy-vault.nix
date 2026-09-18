{ lib
, writeShellApplication
, age
, gocryptfs
, fscrypt-experimental
, gnutar
, gzip
, coreutils
, fuse
, jq
}:

writeShellApplication {
  name = "oligarchy-vault";

  # fscrypt-experimental is the CLI; pkgs.fscrypt is the Go library.
  # fuse (v2) gives us fusermount for unmounting gocryptfs as a normal user.
  runtimeInputs = [ age gocryptfs fscrypt-experimental gnutar gzip coreutils fuse jq ];

  text = ''
    # oligarchy-vault — user-data encryption helper.
    #
    #   pack / unpack                 age        portable .tar.gz.age blobs
    #   init-fscrypt                  fscrypt    live dir on ext4 / F2FS
    #   init-gocryptfs / mount /
    #   umount                        gocryptfs  FUSE overlay (btrfs, ZFS, shares)
    #   status                        what is installed, declared and mounted
    #
    # This tool never touches activation secrets and never writes into
    # /nix/store. Passphrases stay on the terminal or in a runtime passFile.

    VAULT_ETC="''${OLIGARCHY_VAULT_ETC:-/etc/oligarchy}"
    RECIPIENTS_FILE="$VAULT_ETC/vault-recipients"
    MOUNTS_FILE="$VAULT_ETC/vault-mounts.json"

    die() { printf 'oligarchy-vault: %s\n' "$*" >&2; exit 1; }
    note() { printf 'oligarchy-vault: %s\n' "$*" >&2; }

    usage() {
      cat <<'EOF'
    usage: oligarchy-vault <command> [args]

      pack <path> [out.tar.gz.age]   encrypt a file or directory to an age blob
      unpack <blob> [dest]           decrypt an age blob into dest (default .)
      init-gocryptfs <cipherDir>     create a new gocryptfs cipher directory
      mount <name>                   mount a vault from vault-mounts.json
      umount <name|mountpoint>       unmount it
      init-fscrypt <dir>             mark an EMPTY directory encrypted
      status                         backends, recipients, declared vaults

    environment:
      OLIGARCHY_VAULT_IDENTITY  age identity file used by unpack
                                (default ~/.ssh/id_ed25519)
      OLIGARCHY_VAULT_ETC       config dir (default /etc/oligarchy)
    EOF
    }

    # Pure bash: findutils and gnugrep are deliberately not runtime inputs.
    dir_is_empty() {
      local d="$1"
      local entries=()
      shopt -s nullglob dotglob
      entries=("$d"/*)
      shopt -u nullglob dotglob
      [ "''${#entries[@]}" -eq 0 ]
    }

    # `read -r line` already strips leading/trailing IFS whitespace, so a blank
    # or indented-comment line lands here as "" or "#…".
    have_recipients() {
      [ -s "$RECIPIENTS_FILE" ] || return 1
      local line
      while read -r line || [ -n "$line" ]; do
        case "$line" in
          "" | "#"*) continue ;;
          *) return 0 ;;
        esac
      done < "$RECIPIENTS_FILE"
      return 1
    }

    is_mounted() {
      local mp="$1" point
      while read -r _ point _; do
        # /proc/self/mounts escapes spaces as \040.
        point="''${point//\\040/ }"
        if [ "$point" = "$mp" ]; then return 0; fi
      done < /proc/self/mounts
      return 1
    }

    cmd_pack() {
      [ "$#" -ge 1 ] || die "usage: oligarchy-vault pack <path> [out.tar.gz.age]"
      local src parent base out
      src="''${1%/}"
      [ -e "$src" ] || die "no such path: $src"
      parent="$(dirname -- "$src")"
      base="$(basename -- "$src")"
      out="''${2:-$base.tar.gz.age}"
      if [ -e "$out" ]; then die "refusing to overwrite $out"; fi

      # LOAD-BEARING: tar -C parent -cz base. Member names stay RELATIVE.
      # An archive full of absolute paths is how an unpack in the wrong
      # directory quietly overwrites the original.
      if have_recipients; then
        tar -C "$parent" -czf - -- "$base" | age -R "$RECIPIENTS_FILE" -o "$out"
      else
        note "no recipients in $RECIPIENTS_FILE — falling back to a passphrase"
        tar -C "$parent" -czf - -- "$base" | age -p -o "$out"
      fi
      printf '%s\n' "$out"
    }

    cmd_unpack() {
      [ "$#" -ge 1 ] || die "usage: oligarchy-vault unpack <blob> [dest]"
      local blob dest identity
      blob="$1"
      dest="''${2:-.}"
      [ -f "$blob" ] || die "no such blob: $blob"
      mkdir -p -- "$dest"
      identity="''${OLIGARCHY_VAULT_IDENTITY:-''${HOME:-/nonexistent}/.ssh/id_ed25519}"

      if [ -f "$identity" ]; then
        # age reads key FILES. It does NOT talk to ssh-agent: a passphrase-
        # protected ssh key prompts right here and `ssh-add` will not help.
        #
        # tar's stderr is muted on this TRIAL only: when the identity is wrong
        # age emits nothing, and the resulting "unexpected end of file" from
        # gzip buries age's real error. age's own stderr stays visible, and the
        # passphrase attempt below runs unmuted, so nothing is silently lost.
        if age -d -i "$identity" "$blob" | tar -C "$dest" -xz 2>/dev/null; then
          return 0
        fi
        note "identity $identity did not open $blob — trying a passphrase"
      fi
      # Bare `age -d` is the PASSPHRASE path only.
      age -d "$blob" | tar -C "$dest" -xz
    }

    cmd_init_gocryptfs() {
      [ "$#" -ge 1 ] || die "usage: oligarchy-vault init-gocryptfs <cipherDir>"
      local cipher="$1"
      mkdir -p -- "$cipher"
      if ! dir_is_empty "$cipher"; then
        die "cipher dir is not empty: $cipher (gocryptfs -init needs an empty directory)"
      fi
      gocryptfs -init "$cipher"
    }

    cmd_mount() {
      [ "$#" -ge 1 ] || die "usage: oligarchy-vault mount <name>"
      local name entry cipher mp passfile allowother
      name="$1"
      [ -f "$MOUNTS_FILE" ] || die "no $MOUNTS_FILE — is custom.vault.gocryptfs.enable set?"
      entry="$(jq -e --arg n "$name" '.[$n]' "$MOUNTS_FILE")" \
        || die "no vault named $name in $MOUNTS_FILE"

      cipher="$(jq -r '.cipherDir' <<<"$entry")"
      mp="$(jq -r '.mountPoint' <<<"$entry")"
      passfile="$(jq -r '.passFile // empty' <<<"$entry")"
      allowother="$(jq -r '.allowOther' <<<"$entry")"

      local args=(gocryptfs)
      if [ "$allowother" = "true" ]; then args+=(-allow_other); fi
      # passFile is a RUNTIME path by design; with none, gocryptfs prompts.
      if [ -n "$passfile" ]; then
        [ -f "$passfile" ] || die "passFile missing: $passfile"
        args+=(-passfile "$passfile")
      fi
      local extra=()
      mapfile -t extra < <(jq -r '.extraArgs[]?' <<<"$entry")
      if [ "''${#extra[@]}" -gt 0 ]; then args+=("''${extra[@]}"); fi

      mkdir -p -- "$mp"
      args+=("$cipher" "$mp")
      "''${args[@]}"
    }

    cmd_umount() {
      [ "$#" -ge 1 ] || die "usage: oligarchy-vault umount <name|mountpoint>"
      local target mp looked
      target="$1"
      mp="$target"
      if [ -f "$MOUNTS_FILE" ]; then
        looked="$(jq -r --arg n "$target" '.[$n].mountPoint // empty' "$MOUNTS_FILE")"
        if [ -n "$looked" ]; then mp="$looked"; fi
      fi
      if command -v fusermount >/dev/null 2>&1; then
        fusermount -u "$mp"
      else
        fusermount3 -u "$mp"
      fi
    }

    cmd_init_fscrypt() {
      [ "$#" -ge 1 ] || die "usage: oligarchy-vault init-fscrypt <dir>"
      local dir user
      dir="$1"
      mkdir -p -- "$dir"
      # LOAD-BEARING: there is NO in-place fscrypt encryption. The kernel can
      # only mark an EMPTY directory, so protecting existing data means:
      # create an empty dir, encrypt it, move the data in, then destroy the
      # plaintext copy yourself. This is why the module never does it at
      # activation time.
      if ! dir_is_empty "$dir"; then
        die "fscrypt only encrypts EMPTY directories: $dir is not empty. Make an empty one, encrypt it, then move data in."
      fi
      user="''${USER:-$(id -un)}"
      note "needs ext4 with the 'encrypt' feature (tune2fs -O encrypt) or F2FS, and 'sudo fscrypt setup' on that mountpoint"
      note "contents and filenames are encrypted; file SIZES, timestamps and permissions still leak"
      fscrypt encrypt "$dir" --user="$user"
    }

    cmd_status() {
      local b count line name mp
      printf 'config dir      : %s\n' "$VAULT_ETC"
      for b in age gocryptfs fscrypt; do
        if command -v "$b" >/dev/null 2>&1; then
          printf 'backend %-9s: available\n' "$b"
        else
          printf 'backend %-9s: not installed\n' "$b"
        fi
      done

      if have_recipients; then
        count=0
        while read -r line || [ -n "$line" ]; do
          case "$line" in
            "" | "#"*) continue ;;
            *) count=$((count + 1)) ;;
          esac
        done < "$RECIPIENTS_FILE"
        printf 'age recipients  : %s\n' "$count"
      else
        printf 'age recipients  : none (pack falls back to a passphrase)\n'
      fi

      if [ -f "$MOUNTS_FILE" ]; then
        while read -r name; do
          [ -n "$name" ] || continue
          mp="$(jq -r --arg n "$name" '.[$n].mountPoint' "$MOUNTS_FILE")"
          if is_mounted "$mp"; then
            printf 'vault %-10s: mounted at %s\n' "$name" "$mp"
          else
            printf 'vault %-10s: not mounted (%s)\n' "$name" "$mp"
          fi
        done < <(jq -r 'keys[]' "$MOUNTS_FILE")
      else
        printf 'vaults          : none declared\n'
      fi
    }

    if [ "$#" -eq 0 ]; then
      usage
      exit 1
    fi

    cmd="$1"
    shift
    case "$cmd" in
      pack) cmd_pack "$@" ;;
      unpack) cmd_unpack "$@" ;;
      init-gocryptfs) cmd_init_gocryptfs "$@" ;;
      mount) cmd_mount "$@" ;;
      umount | unmount) cmd_umount "$@" ;;
      init-fscrypt) cmd_init_fscrypt "$@" ;;
      status) cmd_status ;;
      -h | --help | help) usage ;;
      *) usage; die "unknown command: $cmd" ;;
    esac
  '';

  meta = {
    description = "User-data encryption helper for Oligarchy (age, fscrypt, gocryptfs)";
    mainProgram = "oligarchy-vault";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
