# ═══════════════════════════════════════════════════════════════════════════════
# The canonical manifest of one portal-VM image — the activation reference.
# ═══════════════════════════════════════════════════════════════════════════════
# Everything the launcher needs to boot the guest, with a hash for each part:
#
#   kernel, initrd   sha256 — checked by captive-vm-run against copies it then
#                    hands QEMU, so what is checked is what boots
#   store disk       erofs image of the guest closure (microvm.nix)
#   verity           hash tree over the store disk + its root hash; the guest
#                    kernel checks every block it reads against it
#   cmdline          the exact kernel command line minus `captive.verity=`,
#                    which the launcher appends from this same file
#   policy           the egress ruleset's sha256 and the run limits
#   inputs           which flake inputs produced all of the above
#
# sha256(manifest.json) is the reference: it is baked into the launcher at
# build time (not IFD — a derivation reading another's output), checked at
# every launch, optionally signed per host, and stamped into the audit log.
#
# Reproducible on purpose: verity's salt and UUID default to random, which
# would give two builds of the same inputs two different references. Both
# are derived from the store disk's own hash instead.
{ pkgs, lib, guest, policyFile, limits, inputsInfo, extraCmdline ? [ ] }:

let
  cfg = guest.config;
  kernel = "${cfg.boot.kernelPackages.kernel}/${cfg.system.boot.loader.kernelFile}";
  initrd = cfg.microvm.initrdPath;
  storeDisk = cfg.microvm.storeDisk;
  cmdline = lib.concatStringsSep " " (
    [ "panic=-1" "reboot=t" "quiet" ] ++ extraCmdline ++ cfg.microvm.kernelParams
  );
  # Informational only: recorded without a store reference so the host
  # closure does not carry the guest closure twice (it is inside the disk).
  toplevel = builtins.unsafeDiscardStringContext (toString cfg.system.build.toplevel);
in
pkgs.runCommand "captive-vm-manifest"
{
  nativeBuildInputs = [ pkgs.cryptsetup pkgs.jq pkgs.coreutils pkgs.gnused ];
  inherit cmdline toplevel;
  inputsJson = builtins.toJSON inputsInfo;
  limitsJson = builtins.toJSON limits;
  passthru = { inherit kernel initrd storeDisk; };
} ''
  mkdir -p $out

  size=$(stat -c %s ${storeDisk})
  if [ $(( size % 4096 )) -ne 0 ]; then
    echo "store disk is $size bytes, not a multiple of 4096; verity needs whole blocks" >&2
    exit 1
  fi

  store_sha=$(sha256sum ${storeDisk} | cut -c1-64)
  uuid=$(printf '%s' "$store_sha" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')
  veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
    --salt="$store_sha" --uuid="$uuid" ${storeDisk} $out/verity.img > verity.txt
  root=$(sed -n 's/^Root hash:[[:space:]]*//p' verity.txt)
  case "$root" in
    *[!0-9a-f]* | "") echo "could not read the verity root hash" >&2; cat verity.txt >&2; exit 1 ;;
  esac
  # Belt and braces at build time: the tree must verify the disk it was made from.
  veritysetup verify ${storeDisk} $out/verity.img "$root"

  jq -n --sort-keys \
    --arg kernel ${kernel} --arg kernelSha "$(sha256sum ${kernel} | cut -c1-64)" \
    --arg initrd ${initrd} --arg initrdSha "$(sha256sum ${initrd} | cut -c1-64)" \
    --arg store ${storeDisk} --arg storeSha "$store_sha" \
    --arg tree "$out/verity.img" --arg treeSha "$(sha256sum $out/verity.img | cut -c1-64)" \
    --arg root "$root" \
    --arg cmdline "$cmdline" \
    --arg toplevel "$toplevel" \
    --arg nft ${policyFile} --arg nftSha "$(sha256sum ${policyFile} | cut -c1-64)" \
    --argjson limits "$limitsJson" \
    --argjson inputs "$inputsJson" \
    '{
      schema: "oligarchy-captive-vm/1",
      kernel: { path: $kernel, sha256: $kernelSha },
      initrd: { path: $initrd, sha256: $initrdSha },
      store: {
        path: $store, sha256: $storeSha,
        verity: { hashTree: $tree, hashTreeSha256: $treeSha, root: $root, algorithm: "sha256", blockSize: 4096 }
      },
      cmdline: $cmdline,
      guest: { toplevel: $toplevel },
      policy: { nft: $nft, nftSha256: $nftSha, limits: $limits },
      inputs: $inputs
    }' > $out/manifest.json

  sha256sum $out/manifest.json | cut -c1-64 > $out/reference
''
