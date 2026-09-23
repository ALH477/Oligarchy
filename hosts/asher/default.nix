# ════════════════════════════════════════════════════════════════════════════
# hosts/asher — the maintainer's personal layer for the Framework 16.
#
# THIS IS NOT A HARDWARE PROFILE. The other four directories under hosts/
# (framework13, intel, optimus, builder) each carry a
# `hardware-configuration.nix` and are wired into their own `mkHost` call in
# flake.nix: they describe a *different machine*. This one describes the same
# machine as `nixosConfigurations.nixos` — the Framework 16 AMD 7040, same
# disks, same nixos-hardware profile — with one person's toggles layered on
# top. It is composed with `extendModules` in flake.nix rather than a second
# `mkHost` list precisely so that `.#nixos` is not edited at all; `git diff`
# proves that in one line, and the ~130-line module list has no second copy to
# drift out of sync.
#
# ── Why this file exists at all ────────────────────────────────────────────
#
# These settings used to live at `~/.config/oligarchy/local.nix`, outside the
# repo, reachable only through the two `builtins.pathExists` lines at the top
# of configuration.nix and only when `nixos-rebuild` was handed `--impure`.
# That channel has a failure mode with no signal whatsoever:
#
#   Pure evaluation does NOT error on `builtins.pathExists "/home/..."`. Nix
#   catches its own RestrictedPathError and answers `false`. So a forgotten
#   `--impure` does not fail the build, does not warn, and does not print
#   anything — it silently builds a DIFFERENT MACHINE, one where every toggle
#   below fell back to its fresh-clone-minimal default, and then happily
#   switches to it.
#
# That is not hypothetical. An `custom.session.autoLogin` flip arrived through
# this channel, landed a boot on hyprlock instead of the greeter, and never
# appeared in `git diff` — because the file it came from was not in the repo.
# There was nothing to review, nothing to bisect, and nothing to roll back.
#
# Now the maintainer's machine is `nixos-asher`: an ordinary flake attribute,
# evaluated PURELY, tracked in git, diffable, reviewable, and bisectable. The
# `~/.config/oligarchy` hatch stays (see configuration.nix's import comment)
# but reverts to what it should always have been — the fresh-user path that
# `oligarchy-adopt` writes — rather than the maintainer's daily channel.
#
#   Rebuild with:  sudo nixos-rebuild switch --flake .#nixos-asher
#   (no --impure; that is the entire point)
# ════════════════════════════════════════════════════════════════════════════
{ pkgs, lib, ... }:

let
  # The real checkout. Not /etc/nixos — that is a stale root-owned clone; see
  # the OLIGARCHY_FLAKE_DIR note below.
  flakeDir = "/home/asher/Documents/oligarchy2/Oligarchy";
in
{
  # ── Machine-written state ─────────────────────────────────────────────────
  # state.nix is the control center's write target (kernel/gpu/persona picks).
  # RELATIVE path, deliberately: a relative path resolves against the flake's
  # *copied source tree*, so `builtins.pathExists ./state.nix` is answerable
  # under pure evaluation — unlike the absolute `~/.config/oligarchy/...`
  # paths, which are exactly the thing this host exists to stop relying on.
  # The `optional` guard is defence in depth; the file is tracked in git and
  # should always be present.
  #
  # It must STAY tracked, too: Nix's local-flake source filtering drops
  # gitignored files from the evaluated source tree, so a gitignored state.nix
  # would disappear from `nixos-rebuild switch` on this very machine and every
  # control-center action would silently no-op — the same class of bug this
  # host exists to kill. Never add it to .gitignore.
  imports = lib.optional (builtins.pathExists ./state.nix) ./state.nix;

  # Baseline beneath state.nix. The control center overwrites that file
  # wholesale, so a fragment that happens not to mention the persona (or a
  # state.nix that is briefly `{ }`) must still evaluate. mkDefault, so the
  # machine-written value always wins without conflicting.
  custom.persona.active = lib.mkDefault "dev";

  # ── This host expects no out-of-repo overrides ────────────────────────────
  # Everything that used to live in ~/.config/oligarchy is right here, so the
  # pure-eval advisory in configuration.nix would be pure noise on this host.
  # Silence it. (It stays armed on `.#nixos`, which is where a forgotten
  # `--impure` actually costs something.)
  custom.localOverrides.expected = false;

  # ── Tooling handoff ───────────────────────────────────────────────────────
  # The control center (home/apps/control-center/oligarchy-ctl.sh) and the
  # updater read these. Set here rather than in configuration.nix because
  # every one of them is a property of *this* host, not of the distro:
  #
  #   OLIGARCHY_FLAKE_DIR   — where the flake actually is. The script default
  #                           is /etc/nixos, which on this machine is a stale
  #                           root-owned clone several commits behind the real
  #                           tree; pointing the tooling at it means `oligarchy
  #                           update`, `repo-pull` and the MCP dry-build all
  #                           inspect a tree nobody edits.
  #   OLIGARCHY_HOST        — the attribute to rebuild. "nixos" (the script
  #                           default) would drop every toggle in this file,
  #                           which is the original bug wearing a new hat.
  #   OLIGARCHY_REBUILD_FLAGS — SET, and set EMPTY. oligarchy-ctl.sh uses
  #                           `: "${OLIGARCHY_REBUILD_FLAGS=--impure}"`, which
  #                           defaults only when the variable is *unset*; an
  #                           empty-but-set value is therefore the way to say
  #                           "this host needs no --impure". Do not delete it
  #                           thinking it is a no-op — deleting it restores
  #                           --impure, and --impure on this host would re-read
  #                           ~/.config/oligarchy/local.nix on top of this file.
  #   OLIGARCHY_STATE_NIX   — redirects the control center's wholesale
  #                           overwrite at hosts/asher/state.nix instead of
  #                           ~/.config/oligarchy/state.nix, so a persona or
  #                           kernel switch lands somewhere a pure evaluation
  #                           can actually see (and somewhere `git status`
  #                           shows it).
  #
  # mkDefault on OLIGARCHY_FLAKE_DIR: modules/mcp-servers/nixos-module.nix
  # sets that same session variable from `custom.mcpServers.flakeDir` at
  # normal priority whenever the MCP surface is enabled (it is, below), and
  # two normal-priority definitions of one attribute is an eval error. So the
  # option is set to the same path just under this, and this line is only the
  # fallback for a configuration where the MCP servers are off.
  custom.mcpServers.flakeDir = flakeDir;
  environment.sessionVariables = {
    OLIGARCHY_FLAKE_DIR = lib.mkDefault flakeDir;
    OLIGARCHY_HOST = "nixos-asher";
    OLIGARCHY_REBUILD_FLAGS = "";
    OLIGARCHY_STATE_NIX = "${flakeDir}/hosts/asher/state.nix";
  };

  # ══════════════════════════════════════════════════════════════════════════
  # Everything below this line is ~/.config/oligarchy/local.nix, verbatim.
  # ══════════════════════════════════════════════════════════════════════════

  custom.desktopFeatures = {
    enableDev = true;
    enableGaming = true;
    enableAudio = true;
    enableScratchpads = true;
    enablePersonalApps = true;
  };

  services.boot-intro.enable = true;
  custom.steam.enable = true;
  custom.terminus-dev.enable = true;
  custom.vm.dsp.enable = true;

  # Window restore ONLY. autoLogin is deliberately OFF: it sets greetd's
  # initial_session, which skips tuigreet entirely and lands the boot on
  # hyprlock instead of the greeter (modules/session-resume.nix:178, and
  # lockOnLoginConfigured at home/hyprland/default.nix:116). restore is gated
  # separately (restoreOn, same file line 107), so the window set still comes
  # back after a normal greeter login. Do not re-add autoLogin.
  custom.session = {
    autoLogin.enable = false;
    restore.enable = true;
  };
  services.demod-ip-blocker.enable = true;
  custom.mcpServers.enable = true;
  custom.malwareShield.enable = true;
  custom.secrets.enable = true;
  custom.security.hardening.enable = true;
  networking.firewall.strictEgress.enable = true;
  networking.firewall.blocklists.enable = true;
  hardware.cpuSecurity.enable = true;
  custom.oligarchyForge.enable = true;

  # Windscribe vendor client (modules/windscribe-app): GUI, windscribe-cli and
  # the root helper. Mutually exclusive with custom.vpn — leave that one off.
  custom.windscribeApp.enable = true;
  services.ollamaAgentic.dedicatedSwap.enable = true;

  # Machine-specific: external drive, moved verbatim out of configuration.nix
  # (it referenced a physical drive UUID that only exists on this machine).
  swapDevices = [
    {
      device = "/run/media/asher/a82fcfcf-e913-413e-ab4f-4a3b104b2de0/.swapfile";
      priority = 10;
      options = [ "nofail" ];
    }
  ];

  system.activationScripts.btrfsSwapfile = ''
    swapfile=/run/media/asher/a82fcfcf-e913-413e-ab4f-4a3b104b2de0/.swapfile
    mountpoint=/run/media/asher/a82fcfcf-e913-413e-ab4f-4a3b104b2de0
    if [ -d "$mountpoint" ] && ${pkgs.util-linux}/bin/mountpoint -q "$mountpoint" && [ ! -e "$swapfile" ]; then
      ${pkgs.coreutils}/bin/truncate -s 0 "$swapfile"
      ${pkgs.e2fsprogs}/bin/chattr +C "$swapfile" 2>/dev/null || true
      ${pkgs.util-linux}/bin/fallocate -l 32G "$swapfile"
      ${pkgs.coreutils}/bin/chmod 600 "$swapfile"
      ${pkgs.util-linux}/bin/mkswap "$swapfile"
    fi
  '';
}
