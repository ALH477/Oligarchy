# MACHINE-WRITTEN. Do not hand-edit the values below.
#
# home/apps/control-center/oligarchy-ctl.sh `set_local()` WHOLESALE OVERWRITES
# this file on every kernel-* / gpu-* / persona-* action, so any comment or
# hand-made edit here is destroyed the next time somebody picks a persona from
# the control center. The durable explanation lives in ./default.nix next to
# the import; this header is a courtesy copy that will not survive.
#
# Two rules:
#   * It must stay TRACKED IN GIT and must never be gitignored. Nix's
#     local-flake source filtering drops gitignored files from the evaluated
#     source tree entirely, so a gitignored state.nix would vanish from
#     `nixos-rebuild switch` on this very machine and every control-center
#     action would silently no-op — the exact bug hosts/asher exists to kill.
#   * Change it with `oligarchy-ctl persona <name>` (or the kernel/gpu verbs),
#     not with an editor. Side benefit of living here: a persona switch now
#     shows up in `git status`.
#
# The baseline underneath these definitions is `custom.persona.active =
# lib.mkDefault "dev"` in ./default.nix, so this file may legitimately be
# empty (`{ }`) without breaking evaluation.
{ custom.persona.active = "dev"; }
