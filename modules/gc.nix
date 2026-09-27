# custom.gc — the Oligarchy garbage collector.
#
# WHAT THIS REPLACES, AND WHY IT HAD TO. configuration.nix used to carry a
# weekly `nix-gc-generations` oneshot: prune /nix/var/nix/profiles/system to
# the last 5 generations, then run `nix-collect-garbage`. It ran for months on
# a machine that reached 94% disk, and it could not have helped, because the
# two things actually holding the store were both outside its reach:
#
#   - USER profiles. It named the SYSTEM profile and nothing else, so
#     ~/.local/state/nix/profiles and /nix/var/nix/profiles/per-user/* grew
#     without bound. Eleven generations were live when this module was written.
#   - GC ROOTS. A gcroot PREVENTS nix-collect-garbage from reclaiming its
#     closure. 122 auto-roots were live, 49 of them `result*` symlinks left in
#     project directories by past builds. Running the old timer more often
#     changed nothing at all; the garbage was pinned, not unnoticed.
#
# It was also unconditional — no `enable`, no `mkIf`, so every host importing
# configuration.nix got it — with no dry-run, no assertions and no gate, under
# a header that read "System Maintenance (unchanged)".
#
# WHAT THIS IS NOT. It is not a disk-pressure valve: there is no min-free /
# max-free here, because that is a build-time mechanism and belongs in
# nix.settings if it is ever wanted. It is not an archiver: `preserve` is a
# declared seam and an assertion refuses to let you use it (see below). And it
# has NO MCP SURFACE, deliberately — modules/mcp-servers/crates/core/src/
# allowlist.rs keeps the storage aspect free of any binary capable of deleting,
# and a `nix-collect-garbage --dry-run` tool was once written for that aspect
# and then removed on purpose, to keep the read-only property STRUCTURAL rather
# than conventional. `.#mcp-self-audit` fails the build if oligarchy-gc ever
# lands in .mcp.json.
#
# Opt-in, defaults OFF. With `enable = false` this module emits no unit, no
# timer, no package and no tmpfiles rule, so the ISO needs no `mkForce` for it
# — the property android-mirror, oligarchy-vault, reliquary and mounts have.
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.gc;

  # ── The denylist that cannot be emptied ────────────────────────────────────
  # `deny` is builtinDeny ++ extraDeny. There is deliberately no option that
  # REPLACES builtinDeny: each entry below is a place where deleting the wrong
  # thing breaks something that cannot be rebuilt from source, and an operator
  # who could switch them off would eventually switch them off.
  builtinDeny = [
    # oligarchy-plugins registers a gcroot per installed plugin under here.
    # Its own option description says these are "the GC roots that stop
    # `nix store gc` from deleting an installed plugin out from under a running
    # rig" — removing one unpins a live plugin's closure.
    "/var/lib/oligarchy/plugins"

    # The P2P artifact cache runs its OWN eviction budget over nar/ and tmp/,
    # and publishing an entry is a rename(2) that requires both to stay on one
    # filesystem. A second collector walking it would fight the first.
    "/var/lib/oligarchy/p2p"

    # reliquary's preservation store. A garbage collector that eats the archive
    # is not a garbage collector.
    "/var/lib/reliquary"

    # DeMoD Secure Protocol. Private, and deliberately local-only with no
    # remote — "no remote" here is a choice, not an oversight, so a sweep that
    # reads it as "unbacked, needs pushing" or "stale, needs reclaiming" has
    # misread the intent in both directions. Encoded here so the rule is
    # enforced by the collector rather than remembered: a root MAY contain
    # these (pointing at ~/Documents is reasonable), and the traversal prunes
    # them rather than descending and filtering afterwards.
    "/home/asher/Documents/dsp"
    "/home/asher/Documents/dsp-rust"
  ];

  deny = builtinDeny ++ cfg.extraDeny;

  isAbsolute = p: lib.hasPrefix "/" p;

  # Segment-aware containment: "/a/b" must not match "/a/bc". Same class of
  # bug oligarchy-p2p's scope::in_scope records for version suffixes, where
  # a bare prefix test let `glibc` reach `glibc-locales`.
  underAny = dirs: p: lib.any (d: p == d || lib.hasPrefix "${d}/" p) dirs;

  # Roots a workspace sweep must never be pointed at, even before the denylist
  # is consulted. "/" is the obvious one; the rest are whole-system trees where
  # a `target`-named directory is far more likely to be someone's data.
  forbiddenRoots = [ "/" "/nix" "/home" "/etc" "/var" "/usr" "/boot" "/run" ];

  # ── The config the CLI reads ───────────────────────────────────────────────
  # Rendered to the store as JSON rather than interpolated into the script, so
  # the gate can read the same file the CLI does and `oligarchy-gc status` can
  # print it without re-deriving anything.
  gcConfig = pkgs.writeText "oligarchy-gc.json" (builtins.toJSON {
    dryRun = cfg.dryRun;
    roots = cfg.roots;
    deny = deny;
    builtinDeny = builtinDeny;
    generations = {
      inherit (cfg.nix.generations) enable keepSystem keepUser;
    };
    gcroots = {
      inherit (cfg.nix.roots) enable minAgeDays;
    };
    collectGarbage = cfg.nix.collectGarbage;
    workspace = {
      inherit (cfg.workspace) enable patterns minAgeDays;
    };
    minFreeGB = cfg.timer.minFreeGB;
  });

  gcCli = pkgs.writeShellApplication {
    name = "oligarchy-gc";
    runtimeInputs = with pkgs; [ coreutils findutils jq nix gawk gnugrep ];
    text = ''
      set -euo pipefail

      CONF="''${OLIGARCHY_GC_CONF:-${gcConfig}}"

      die() { printf 'oligarchy-gc: %s\n' "$*" >&2; exit 1; }
      note() { printf 'oligarchy-gc: %s\n' "$*" >&2; }

      usage() {
        cat <<'EOF'
      usage: oligarchy-gc [plan|run|status|gate]

        plan     (default) print what WOULD be reclaimed, as JSON on stdout.
                 Deletes nothing, ever, regardless of custom.gc.dryRun.
        run      actually reclaim. Refuses while custom.gc.dryRun = true.
                 Needs root: it writes Nix profiles.
        status   what is enabled, and whether this host is DRY-RUN or ENFORCING.
        gate     what the timer runs: collect only if free space on /nix has
                 fallen to custom.gc.timer.minFreeGB, else exit 0 silently.

      Progress and diagnostics go to stderr; stdout carries only the JSON plan,
      so `oligarchy-gc plan | jq '.total_bytes'` works.
      EOF
      }

      [ -r "$CONF" ] || die "cannot read config: $CONF"

      TMPOUT=$(mktemp)
      trap 'rm -f "$TMPOUT"' EXIT

      # ── the path verdict, as a pure function ──────────────────────────────
      # Takes an absolute path and returns 0 (may reclaim) or 1 (refuse). Every
      # "couldn't determine" case is a REFUSAL, never a pass-through — the rule
      # modules/reliquary/src/usb.rs:136 states as "is refused, never waved
      # through", and the reason its earlier device check was unsafe: a
      # no-match silently skipped the guard instead of stopping.
      #
      # The deny list arrives on stdin as NUL-separated entries so the gate can
      # drive this with fixtures instead of the real config.
      path_is_reclaimable() {
        local p="$1"; shift
        local d
        case "$p" in
          /*) ;;
          *) return 1 ;;                      # not absolute -> refuse
        esac
        case "$p" in
          *..*) return 1 ;;                   # traversal -> refuse
        esac
        for d in "$@"; do
          [ "$p" = "$d" ] && return 1
          case "$p" in "$d"/*) return 1 ;; esac
        done
        return 0
      }

      mapfile -t DENY < <(jq -r '.deny[]' "$CONF")
      mapfile -t ROOTS < <(jq -r '.roots[]' "$CONF")
      DRYRUN=$(jq -r '.dryRun' "$CONF")

      # A denied tree is pruned at the TRAVERSAL layer, not merely filtered out
      # of the results: a root is allowed to contain a denied path (that is what
      # extraDeny is for — "collect under /srv/work but never /srv/work/keep"),
      # and the difference between skipping a match and never descending is the
      # difference between reading a private tree and leaving it alone.
      # path_is_reclaimable still re-checks every candidate afterwards, and the
      # `run` loop checks a third time before unlinking.
      PRUNE=()
      for _d in "''${DENY[@]:-}"; do
        [ -n "$_d" ] || continue
        PRUNE+=( -path "$_d" -o -path "$_d/*" -o )
      done
      PRUNE+=( -false )

      # ── collectors, each emitting "<bytes>\t<kind>\t<path>" ───────────────

      collect_gcroots() {
        [ "$(jq -r '.gcroots.enable' "$CONF")" = true ] || return 0
        local age; age=$(jq -r '.gcroots.minAgeDays' "$CONF")
        local r link target bytes
        for r in "''${ROOTS[@]:-}"; do
          [ -n "$r" ] || continue
          [ -d "$r" ] || { note "root does not exist, skipping: $r"; continue; }
          while IFS= read -r link; do
            path_is_reclaimable "$link" "''${DENY[@]:-}" || continue
            target=$(readlink -f -- "$link" 2>/dev/null) || continue
            [ -n "$target" ] || continue
            case "$target" in /nix/store/*) ;; *) continue ;; esac
            # Closure size, not output size: the closure is what the root pins
            # and therefore what removing it makes reclaimable. The storage MCP
            # aspect gives the same advice before removing a result link.
            bytes=$(nix path-info -S --json "$target" 2>/dev/null \
                     | jq -r 'if type=="object" then (to_entries[0].value.closureSize // 0) else (.[0].closureSize // 0) end' 2>/dev/null) || bytes=0
            [ -n "$bytes" ] || bytes=0
            printf '%s\tgcroot\t%s\n' "$bytes" "$link"
          done < <(find "$r" -mindepth 1 -maxdepth 3 -xdev \
                     \( "''${PRUNE[@]}" \) -prune -o \
                     -type l -name 'result*' -mtime "+$age" -print 2>/dev/null)
        done
      }

      collect_workspace() {
        [ "$(jq -r '.workspace.enable' "$CONF")" = true ] || return 0
        local age; age=$(jq -r '.workspace.minAgeDays' "$CONF")
        local pats; mapfile -t pats < <(jq -r '.workspace.patterns[]' "$CONF")
        local r p dir bytes
        for r in "''${ROOTS[@]:-}"; do
          [ -n "$r" ] || continue
          [ -d "$r" ] || continue
          for p in "''${pats[@]}"; do
            while IFS= read -r dir; do
              path_is_reclaimable "$dir" "''${DENY[@]:-}" || continue
              bytes=$(du -sb --one-file-system -- "$dir" 2>/dev/null | awk '{print $1}') || bytes=0
              [ -n "$bytes" ] || bytes=0
              printf '%s\tworkspace\t%s\n' "$bytes" "$dir"
            done < <(find "$r" -mindepth 1 -maxdepth 6 -xdev \
                       \( "''${PRUNE[@]}" \) -prune -o \
                       -type d -name "$p" -mtime "+$age" -print -prune 2>/dev/null)
          done
        done
      }

      collect_generations() {
        [ "$(jq -r '.generations.enable' "$CONF")" = true ] || return 0
        local ks ku prof n
        ks=$(jq -r '.generations.keepSystem' "$CONF")
        ku=$(jq -r '.generations.keepUser' "$CONF")
        n=$(nix-env -p /nix/var/nix/profiles/system --list-generations 2>/dev/null | wc -l) || n=0
        [ "$n" -gt "$ks" ] && printf '0\tgeneration-system\t%s surplus of %s\n' "$((n - ks))" "$n"
        # The half the old timer never touched.
        for prof in /nix/var/nix/profiles/per-user/*/profile "$HOME"/.local/state/nix/profiles/profile; do
          [ -e "$prof" ] || continue
          n=$(nix-env -p "$prof" --list-generations 2>/dev/null | wc -l) || continue
          [ "$n" -gt "$ku" ] && printf '0\tgeneration-user\t%s (surplus of %s)\n' "$prof" "$((n - ku))"
        done
        return 0
      }

      emit_plan() {
        local tmp rc=0
        tmp=$(mktemp)
        { collect_gcroots; collect_workspace; collect_generations; } > "$tmp" || rc=$?
        [ "$rc" -eq 0 ] || note "a collector exited $rc; the plan below may be partial"
        jq -Rs --argjson dry "$( [ "$DRYRUN" = true ] && echo true || echo false )" '
          split("\n") | map(select(length > 0)) | map(split("\t")) |
          map({ bytes: (.[0]|tonumber), kind: .[1], path: .[2] }) |
          { dry_run: $dry,
            items: .,
            total_bytes: (map(.bytes) | add // 0),
            by_kind: (group_by(.kind) | map({ key: .[0].kind, value: { count: length, bytes: (map(.bytes)|add // 0) } }) | from_entries) }
        ' < "$tmp"
        rm -f "$tmp"
      }

      # Free space on /nix in whole GiB. Used by `gate`, below.
      free_gib() { df -B1G --output=avail /nix 2>/dev/null | tail -1 | tr -dc '0-9'; }

      cmd="''${1:-plan}"
      case "$cmd" in
        -h|--help|help) usage; exit 0 ;;

        status)
          # Built as one string and written once. A sequence of printfs dies
          # on EPIPE the moment something downstream stops reading — `status |
          # grep -q` or `status | head -1` both do — and under `set -e` that
          # turns an ordinary pipeline into a failure. Caught by .#test-gc.
          {
            printf 'oligarchy-gc\n'
            printf '  Mode        : %s\n' "$( [ "$DRYRUN" = true ] && echo 'DRY-RUN (plans only)' || echo 'ENFORCING' )"
            printf '  Roots       : %s\n' "$(jq -r '.roots | if length==0 then "(none)" else join(" ") end' "$CONF")"
            printf '  Generations : %s (keep system %s, user %s)\n' \
              "$(jq -r '.generations.enable' "$CONF")" \
              "$(jq -r '.generations.keepSystem' "$CONF")" \
              "$(jq -r '.generations.keepUser' "$CONF")"
            printf '  GC roots    : %s (older than %s days)\n' \
              "$(jq -r '.gcroots.enable' "$CONF")" "$(jq -r '.gcroots.minAgeDays' "$CONF")"
            printf '  Workspace   : %s (%s, older than %s days)\n' \
              "$(jq -r '.workspace.enable' "$CONF")" \
              "$(jq -r '.workspace.patterns | join(",")' "$CONF")" \
              "$(jq -r '.workspace.minAgeDays' "$CONF")"
            printf '  Deny        : %s\n' "$(jq -r '.deny | join(" ")' "$CONF")"
          } > "$TMPOUT"
          cat "$TMPOUT" || true
          ;;

        plan) emit_plan ;;

        # What the timer invokes. Scheduled reclaim should answer pressure,
        # not arrive on a calendar: above the threshold this exits 0 having
        # done nothing, which is why the unit is not simply `run`.
        gate)
          want=$(jq -r '.minFreeGB' "$CONF")
          have=$(free_gib) || have=""
          if [ -z "$have" ]; then
            die "cannot determine free space on /nix; refusing to collect blind"
          fi
          if [ "$have" -gt "$want" ]; then
            note "$have GiB free on /nix, above the $want GiB threshold; nothing to do"
            exit 0
          fi
          note "$have GiB free on /nix, at or below the $want GiB threshold"
          exec "$0" "$( [ "$DRYRUN" = true ] && echo plan || echo run )"
          ;;

        run)
          if [ "$DRYRUN" = true ]; then
            die "refusing to run: custom.gc.dryRun = true. Read \`oligarchy-gc plan\` first, then set custom.gc.dryRun = false and rebuild."
          fi
          # Root is required only by the collectors that actually need it.
          # Retiring a `result` link or a `target/` dir in the operator's own
          # tree does not, and demanding sudo to rm your own files trains the
          # wrong reflex for no gain.
          needs_root=false
          [ "$(jq -r '.generations.enable' "$CONF")" = true ] && needs_root=true
          [ "$(jq -r '.collectGarbage' "$CONF")" = true ] && needs_root=true
          if [ "$needs_root" = true ] && [ "$(id -u)" -ne 0 ]; then
            die "run needs root: generations and nix-collect-garbage write Nix profiles. Disable those collectors to run unprivileged over roots you own."
          fi

          plan=$(emit_plan)
          printf '%s\n' "$plan" | jq -r '.items[] | [.kind, .path] | @tsv' |
            while IFS=$'\t' read -r kind path; do
              case "$kind" in
                gcroot)
                  path_is_reclaimable "$path" "''${DENY[@]:-}" || die "refusing $path"
                  note "removing stale build link: $path"; rm -f -- "$path" ;;
                workspace)
                  path_is_reclaimable "$path" "''${DENY[@]:-}" || die "refusing $path"
                  note "removing build artefacts: $path"; rm -rf -- "$path" ;;
                *) : ;;
              esac
            done

          if [ "$(jq -r '.generations.enable' "$CONF")" = true ]; then
            ks=$(jq -r '.generations.keepSystem' "$CONF")
            ku=$(jq -r '.generations.keepUser' "$CONF")
            # `+N` keeps the newest N and is what the old timer should have
            # used: its `--list-generations | awk | head -n -5` parse was
            # fragile against the trailing current-generation marker.
            note "pruning system profile to the newest $ks"
            nix-env -p /nix/var/nix/profiles/system --delete-generations "+$ks" || true
            for prof in /nix/var/nix/profiles/per-user/*/profile "$HOME"/.local/state/nix/profiles/profile; do
              [ -e "$prof" ] || continue
              note "pruning $prof to the newest $ku"
              nix-env -p "$prof" --delete-generations "+$ku" || true
            done
          fi

          # Last, and only last: a gcroot pins its closure, so collecting
          # before the roots above are gone reclaims nothing.
          if [ "$(jq -r '.collectGarbage' "$CONF")" = true ]; then
            note "nix-collect-garbage"
            nix-collect-garbage || true
          fi
          note "done"
          ;;

        *) usage; die "unknown command: $cmd" ;;
      esac
    '';
    meta = {
      description = "Plan and reclaim Nix generations, stale gcroots and build artefacts";
      mainProgram = "oligarchy-gc";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };
in
{
  options.custom.gc = {
    enable = lib.mkEnableOption "the Oligarchy garbage collector (custom.gc)";

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Plan but never delete. Defaults TRUE and stays true until an operator
        has read a plan: this is the soak pattern strict-egress uses with
        `recovery.dryRun`. `oligarchy-gc run` refuses outright while set.
      '';
    };

    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/home/asher/Documents/oligarchy2" ];
      description = ''
        Directories the collector may walk for stale `result*` links and build
        artefacts. Nothing outside a root is ever considered. Must be absolute.
      '';
    };

    extraDeny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra paths the collector must never touch. APPENDED to a built-in
        denylist that cannot be replaced or emptied; see the module banner for
        what is in it and why.
      '';
    };

    nix.generations = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Prune surplus Nix profile generations.";
      };
      keepSystem = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Generations to keep on /nix/var/nix/profiles/system.";
      };
      keepUser = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = ''
          Generations to keep on each USER profile. The timer this module
          replaces had no equivalent: it named the system profile only, which
          is why eleven user generations were live when this was written.
        '';
      };
    };

    nix.roots = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Retire stale `result*` symlinks under `roots`. These are the reason a
          large store will not shrink: a gcroot pins its whole closure, so
          nix-collect-garbage cannot touch it however often it runs.
        '';
      };
      minAgeDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Only consider build links older than this.";
      };
    };

    nix.collectGarbage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run nix-collect-garbage last, after roots and generations.";
    };

    workspace = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Reclaim build-artefact directories under `roots`. Defaults OFF
          because, unlike the Nix collectors, this one walks your source tree.
        '';
      };
      patterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "target" "node_modules" ];
        description = "Directory names treated as regenerable build output.";
      };
      minAgeDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Only consider artefact directories older than this.";
      };
    };

    timer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run the collector on a schedule as well as on demand.";
      };
      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "systemd OnCalendar expression for the timer.";
      };
      minFreeGB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = ''
          The timer exits 0 without collecting while more than this much is
          free on /nix. Scheduled reclaim should be a response to pressure, not
          a ritual.
        '';
      };
    };

    preserve = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        RESERVED, and asserted empty. The seam for archive-before-delete:
        pack with `oligarchy-archive`, gate on `reliquary verify` (which exits
        2 on a bad block), delete the source only on success. Not wired,
        because reliquary does not yet fsync after write and `reliquary push`
        does not verify the destination copy — so "archived" is not yet safely
        "deletable". See modules/reliquary/docs/ADVERSARY_REVIEW.md.
      '';
    };
  };

  config = lib.mkMerge [
    # Declaring roots without flipping the master switch would otherwise be
    # completely silent.
    (lib.mkIf (cfg.roots != [ ] && !cfg.enable) {
      warnings = [
        "custom.gc.roots declares ${toString (builtins.length cfg.roots)} root(s) but custom.gc.enable = false, so nothing is collected and no CLI is installed."
      ];
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.all isAbsolute cfg.roots;
          message = "custom.gc.roots: every entry must be an absolute path. A relative root resolves against the collector unit's working directory, which is not the directory you meant and is not stable across systemd versions.";
        }
        {
          assertion = !(lib.any (r: lib.elem r forbiddenRoots) cfg.roots);
          message = "custom.gc.roots: refusing a whole-system root (one of ${toString forbiddenRoots}). Inside these trees a directory named `target` or `node_modules` is far more likely to be someone's data than build output. Name the project directory you actually build in.";
        }
        {
          assertion = !(lib.any (r: underAny deny r) cfg.roots);
          message = "custom.gc.roots: a root lies inside the denylist. The denylist exists because deleting inside those trees breaks something that cannot be rebuilt — a plugin gcroot, the P2P cache's own eviction budget, the reliquary archive, or private DeMoD Secure Protocol work. Remove the root; do not try to carve an exception.";
        }
        {
          assertion = cfg.workspace.enable -> cfg.roots != [ ];
          message = "custom.gc.workspace.enable = true with custom.gc.roots = [ ]. The workspace collector only ever walks declared roots, so this combination silently collects nothing — which looks exactly like a collector that ran and found the disk clean. Declare a root, or leave the workspace collector off.";
        }
        {
          assertion = cfg.preserve == [ ];
          message = "custom.gc.preserve is reserved and must stay empty. Archive-before-delete is not wired: reliquary does not fsync after write and `reliquary push` does not verify the destination copy, so a successful archive is not yet proof the original is safe to delete. Use `oligarchy-archive` by hand and check the block before removing anything.";
        }
      ];

      environment.systemPackages = [ gcCli ];

      systemd.services.oligarchy-gc = {
        description = "Oligarchy garbage collector";
        serviceConfig = {
          Type = "oneshot";
          # `gate`, not `run`: it consults free space first and, in dryRun,
          # resolves to `plan` so the unit is safe to enable before soaking.
          ExecStart = "${lib.getExe gcCli} gate";
          Nice = 19;
          IOSchedulingClass = "idle";
          # Reclaim is never worth competing with interactive work.
          CPUSchedulingPolicy = "idle";
        };
      };

      systemd.timers.oligarchy-gc = lib.mkIf cfg.timer.enable {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.timer.onCalendar;
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
    })
  ];
}
