# oligarchy-archive — pack a path with oligarchy-vault, then ingest the
# resulting encrypted blob as a checksummed, PAR2-protected reliquary block.
#
# Deliberately thin: this is a two-command pipeline (pack, then ingest) and
# nothing more. It stops at ingest — the resulting block stays in reliquary's
# LOCAL store. Pushing it to the USB pair, building an ISO, or burning a CD-R
# are separate, manual, higher-risk operations left to `reliquary push` /
# `reliquary iso` / `reliquary burn`, run by hand once the operator has
# checked the block. No timer, no service: on-demand only.
#
# custom.vault and services.reliquary are independent modules (see their own
# READMEs); this file wires nothing into either of them and needs neither
# enabled system-wide to install the CLI — it just needs their packages,
# threaded in via specialArgs the same way modules/hydramesh.nix consumes the
# hydramesh flake's packages.
{ config, lib, pkgs, oligarchy-vault, reliquary, ... }:

let
  cfg = config.custom.archive;
  system = pkgs.stdenv.hostPlatform.system;

  vaultCli = oligarchy-vault.packages.${system}.default or
    (throw "the oligarchy-vault flake has no default package for system ${system}");
  reliquaryCli = reliquary.packages.${system}.reliquary or
    (throw "the reliquary flake has no 'reliquary' package for system ${system}");

  archiveCli = pkgs.writeShellApplication {
    name = "oligarchy-archive";
    runtimeInputs = [ vaultCli reliquaryCli ];
    text = ''
      set -euo pipefail

      die() { printf 'oligarchy-archive: %s\n' "$*" >&2; exit 1; }

      usage() {
        cat <<'EOF'
      usage: oligarchy-archive <path> [--profile cd|usb] [--notes TEXT] [--out DIR]

      Pack <path> into an age-encrypted blob with `oligarchy-vault pack`, then
      hand that blob to `reliquary ingest` as a checksummed, PAR2-protected
      preservation block in the LOCAL reliquary store.

        --profile cd|usb   forwarded to `reliquary ingest` (default: cd)
        --notes TEXT       forwarded to `reliquary ingest`
        --out DIR          directory for the intermediate .tar.gz.age blob
                            (default: current directory, same as a bare
                            `oligarchy-vault pack` with no destination)

      This stops at ingest. Pushing the block onto the USB pair, building a
      CD-R ISO, or burning it are separate, manual steps:
        reliquary push <block-id>
        reliquary iso  <block-id>
        reliquary burn <iso> <device>
      EOF
      }

      profile="cd"
      notes=""
      outdir="."
      path=""

      # Positional and --flags may come in any order (`oligarchy-archive PATH
      # --notes TEXT` and `oligarchy-archive --notes TEXT PATH` both work) —
      # collect non-option args instead of assuming the first one ends parsing.
      positional=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --profile)
            [ "$#" -ge 2 ] || die "--profile needs an argument"
            profile="$2"
            shift 2
            ;;
          --notes)
            [ "$#" -ge 2 ] || die "--notes needs an argument"
            notes="$2"
            shift 2
            ;;
          --out)
            [ "$#" -ge 2 ] || die "--out needs an argument"
            outdir="$2"
            shift 2
            ;;
          -h | --help)
            usage
            exit 0
            ;;
          --)
            shift
            while [ "$#" -gt 0 ]; do
              positional+=("$1")
              shift
            done
            ;;
          -*)
            usage
            die "unknown option: $1"
            ;;
          *)
            positional+=("$1")
            shift
            ;;
        esac
      done

      [ "''${#positional[@]}" -eq 1 ] || { usage; die "expected exactly one path argument"; }
      path="''${positional[0]}"
      [ -e "$path" ] || die "no such path: $path"
      case "$profile" in
        cd | usb) : ;;
        *) die "--profile must be cd or usb, got: $profile" ;;
      esac

      base="$(basename -- "''${path%/}")"
      mkdir -p -- "$outdir"
      blob="$outdir/$base.tar.gz.age"
      [ -e "$blob" ] && die "refusing to overwrite existing blob: $blob"

      # Vault's `pack` prints the blob path on stdout so callers can do
      # `blob=$(oligarchy-vault pack ...)`. Here that would prepend a bare path
      # to reliquary's JSON manifest, so `oligarchy-archive PATH | jq .id` — the
      # obvious next composition, and the reason ingest emits JSON at all —
      # would choke on the first line. Send it to stderr with the rest of this
      # script's progress output and leave stdout to the manifest alone.
      oligarchy-vault pack "$path" "$blob" >&2
      printf 'oligarchy-archive: packed -> %s\n' "$blob" >&2

      ingest_args=(ingest "$blob" --profile "$profile")
      if [ -n "$notes" ]; then
        ingest_args+=(--notes "$notes")
      fi
      reliquary "''${ingest_args[@]}"
    '';

    meta = {
      description = "Pack a path with oligarchy-vault, then ingest it as a reliquary block";
      mainProgram = "oligarchy-archive";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };
in
{
  options.custom.archive.enable = lib.mkEnableOption
    "oligarchy-archive (pack with oligarchy-vault, then ingest into reliquary)";

  config = lib.mkIf cfg.enable {
    # The two tools this wraps go on PATH alongside it, not just into the
    # wrapper's runtimeInputs. The help text above tells the operator to finish
    # the job with `reliquary push` / `iso` / `burn`, and `services.reliquary`
    # — the only other thing that installs reliquary system-wide — is a
    # separate opt-in. Without this, following the documented workflow ends in
    # `command not found` with a valid block stranded in the local store and no
    # advertised way to get it onto media.
    environment.systemPackages = [ archiveCli vaultCli reliquaryCli ];
  };
}
