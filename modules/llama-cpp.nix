# ─────────────────────────────────────────────────────────────────────────────
# llama.cpp — dedicated MoE inference server (services.llamaCpp)
#
# Second, independent inference path alongside the Ollama container
# (modules/agentic-local-ai.nix, :11434). That stack is tuned for dense models
# that fit in VRAM; this one exists for large HuggingFace GGUF *MoE* models,
# where the winning move is to keep attention/shared tensors on the 8 GB dGPU
# and push the huge, sparsely-activated expert FFN tensors out to system RAM
# (and, past that, to disk via mmap).
#
# Hardware this is shaped for (Framework 16 AMD 7040):
#   dGPU  Radeon RX 7700S   Navi 33   gfx1102   8 GB VRAM   0000:03:00.0
#   iGPU  Radeon 780M       Phoenix1  gfx1103   GTT (system RAM)  0000:c5:00.0
#   RAM   22 GiB usable     CPU  7840HS, 7 schedulable cores (isolcpus=0,1)
#
# The iGPU drives the eDP panel, so the dGPU can be dedicated to inference
# without disturbing the Hyprland session — hence `defaultDevice = "ROCm0"`
# rather than letting llama.cpp auto-split across both GPUs. Splitting would
# pull the 780M in, and the 780M draws from the same LPDDR5 the CPU does: it
# adds a copy, not bandwidth. See `iGPU role` in docs/llama-cpp-moe.md.
#
# VRAM contention: this and the Ollama container cannot both own 8 GB. That is
# a runtime condition, not a config error, so `llamactl start` preflights it
# rather than the module asserting on it.
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.llamaCpp;

  # ── Package ────────────────────────────────────────────────────────────────
  # rocmGpuTargets covers BOTH GPUs in one binary, which is why this module
  # must never set HSA_OVERRIDE_GFX_VERSION: that variable is process-global
  # and would force one target onto both devices. (The "11.0.2" override in
  # modules/platform.nix is scoped to the Ollama *container* environment and
  # is deliberately left alone.)
  derivedPackage =
    if cfg.backend == "rocm" then
      pkgs.llama-cpp.override
        {
          rocmSupport = true;
          rocmGpuTargets = cfg.rocmGpuTargets;
        }
    else if cfg.backend == "vulkan" then
      pkgs.llama-cpp.override
        {
          vulkanSupport = true;
          rpcSupport = true;
        }
    else
      pkgs.llama-cpp;

  llamaPackage = if cfg.package != null then cfg.package else derivedPackage;

  # ── Paths ──────────────────────────────────────────────────────────────────
  paths = {
    state = "/var/lib/llama";
    activeProfile = "/var/lib/llama/active-profile";
    imported = "${cfg.storePath}/imported";
    unified = "${cfg.storePath}/unified";
  };

  # ── Profile -> argv ────────────────────────────────────────────────────────
  # Absolute model paths pass through; anything else is resolved against the
  # store, so profiles can say "gguf/Qwen3-30B-A3B-Q4_K_M.gguf".
  resolvePath = p: if hasPrefix "/" p then p else "${cfg.storePath}/${p}";

  profileArgs = name: p:
    let
      device = if p.device != null then p.device else cfg.defaultDevice;
      draftDevice = if p.draftDevice != null then p.draftDevice else cfg.defaultDraftDevice;
    in
    [
      "--alias"
      (if p.alias != null then p.alias else name)
      "--host"
      cfg.network.bindAddress
      "--port"
      (toString cfg.network.port)
      "--ctx-size"
      (toString p.ctx)
      "--threads"
      (toString p.threads)
      "--n-gpu-layers"
      (toString p.nGpuLayers)
      "--flash-attn"
      p.flashAttn
      "--cache-type-k"
      p.cacheTypeK
      "--cache-type-v"
      p.cacheTypeV
      "--parallel"
      (toString p.parallel)
      "--batch-size"
      (toString p.batchSize)
      "--ubatch-size"
      (toString p.ubatchSize)
    ]
    ++ optionals (p.model != null) [ "--model" (resolvePath p.model) ]
    ++ optionals (p.model == null && p.hfRepo != null) (
      [ "-hf" p.hfRepo ] ++ optionals (p.hfFile != null) [ "--hf-file" p.hfFile ]
    )
    # The MoE split. --n-cpu-moe N is llama.cpp's sugar for
    #   -ot "blk\.(0|…|N)\.ffn_(up|down|gate)_exps\.weight=CPU"
    # i.e. attention + embeddings + shared experts stay on the GPU (small,
    # compute-bound, big win) while the expert weights live in RAM (large,
    # memory-bound, only a couple activated per token). Raise it until the
    # model fits VRAM, lower it until it OOMs — `llamactl autotune` does that.
    ++ optionals (p.nCpuMoe != null) [ "--n-cpu-moe" (toString p.nCpuMoe) ]
    ++ optionals (p.overrideTensor != null) [ "--override-tensor" p.overrideTensor ]
    ++ optionals (device != null) [ "--device" device ]
    ++ optionals (p.tensorSplit != null) [ "--tensor-split" p.tensorSplit ]
    ++ optionals (p.threadsBatch != null) [ "--threads-batch" (toString p.threadsBatch) ]
    ++ optionals (!p.mmap) [ "--no-mmap" ]
    ++ optionals p.mlock [ "--mlock" ]
    ++ optionals p.jinja [ "--jinja" ]
    # Speculative decoding: draft model on the iGPU, target MoE on the dGPU.
    # This is the one arrangement where the 780M genuinely earns its keep.
    ++ optionals (p.draftModel != null) (
      [ "--model-draft" (resolvePath p.draftModel) "--draft-max" (toString p.nDraft) ]
      ++ optionals (draftDevice != null) [ "--device-draft" draftDevice ]
      ++ optionals (p.draftNGpuLayers != null) [ "--gpu-layers-draft" (toString p.draftNGpuLayers) ]
    )
    ++ p.extraArgs;

  # One newline-delimited argv file per profile; llamactl and the unit both
  # read these, so there is exactly one definition of a profile's arguments.
  profileFiles = pkgs.runCommand "llama-profiles" { } ''
    mkdir -p "$out"
    ${concatStringsSep "\n" (mapAttrsToList
      (name: p: ''
        cp ${pkgs.writeText "llama-${name}.args"
          (concatStringsSep "\n" (profileArgs name p) + "\n")} "$out/${name}.args"
      '')
      cfg.profiles)}
  '';

  profileNames = attrNames cfg.profiles;

  # ── Runtime env ────────────────────────────────────────────────────────────
  serviceEnv =
    optionalAttrs (cfg.backend == "rocm" && cfg.visibleDevices != null) {
      ROCR_VISIBLE_DEVICES = cfg.visibleDevices;
    }
    // optionalAttrs (cfg.backend == "rocm") {
      # Keep HIP's scratch/cache off the (91 %-full) root filesystem.
      HIP_VISIBLE_DEVICES_FORCE = "0";
    }
    // {
      LLAMA_CACHE = "${cfg.storePath}/hf-cache";
    }
    // cfg.extraEnvironment;

  # ── ExecStart shim ─────────────────────────────────────────────────────────
  # The unit is profile-agnostic; the active profile lives in a state file so
  # `llamactl start <profile>` is a write + restart rather than a rebuild.
  serverRunner = pkgs.writeShellScript "llama-server-run" ''
    set -euo pipefail

    PROFILE="${cfg.defaultProfile}"
    if [ -r "${paths.activeProfile}" ]; then
      PROFILE="$(cat "${paths.activeProfile}")"
    fi

    ARGS_FILE="${profileFiles}/''${PROFILE}.args"
    if [ ! -r "$ARGS_FILE" ]; then
      echo "llama-server: unknown profile '$PROFILE' (have: ${concatStringsSep " " profileNames})" >&2
      exit 78   # EX_CONFIG
    fi

    mapfile -t ARGS < "$ARGS_FILE"
    echo "llama-server: profile '$PROFILE'"
    printf '  %s\n' "''${ARGS[@]}"
    exec ${llamaPackage}/bin/llama-server "''${ARGS[@]}"
  '';

  # ── llamactl ───────────────────────────────────────────────────────────────
  # Single entry point for every verb, deliberately mirroring `ai-stack`
  # (modules/agentic-local-ai.nix). That shape is what keeps the MCP surface
  # to ONE allowlist entry — see modules/mcp-servers/crates/core/src/allowlist.rs.
  llamactl = pkgs.writeShellScriptBin "llamactl" ''
    #!/usr/bin/env bash
    set -euo pipefail

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
    success() { echo -e "''${GREEN}[OK]''${NC} $*"; }
    warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
    info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

    UNIT=llama-server.service
    STORE="${cfg.storePath}"
    PROFILES_DIR="${profileFiles}"
    ACTIVE="${paths.activeProfile}"
    ENDPOINT="http://${cfg.network.bindAddress}:${toString cfg.network.port}"
    MODEL_PATHS=(${concatMapStringsSep " " (p: ''"${p}"'') cfg.modelPaths})
    OLLAMA_ROOT="${cfg.ollamaModelsPath}"

    ensure_dirs() {
      for d in "''${MODEL_PATHS[@]}" "${paths.imported}" "${paths.unified}" "$STORE/hf-cache"; do
        mkdir -p "$d" 2>/dev/null || true
      done
    }

    list_profiles() {
      for f in "$PROFILES_DIR"/*.args; do
        [ -e "$f" ] || continue
        basename "$f" .args
      done
    }

    require_profile() {
      local want="$1"
      if [ ! -r "$PROFILES_DIR/''${want}.args" ]; then
        error "Unknown profile: $want"
        echo "Available:"; list_profiles | sed 's/^/  /'
        exit 1
      fi
    }

    # A model resident in the Ollama container and a model resident here cannot
    # both fit in 8 GB of VRAM. Warn loudly; do not decide for the user.
    preflight_vram() {
      if command -v ollama >/dev/null 2>&1; then
        local running
        running="$(ollama ps 2>/dev/null | tail -n +2 || true)"
        if [ -n "$running" ]; then
          warn "Ollama currently has a model resident — it is holding dGPU VRAM:"
          echo "$running" | sed 's/^/    /'
          warn "Free it with:  ai-stack stop"
        fi
      fi
    }

    case "''${1:-help}" in
      start|up)
        PROFILE="''${2:-${cfg.defaultProfile}}"
        require_profile "$PROFILE"
        ensure_dirs
        preflight_vram
        echo "$PROFILE" | ''${SUDO:-sudo} tee "$ACTIVE" >/dev/null
        ''${SUDO:-sudo} systemctl restart "$UNIT"
        success "llama-server starting with profile '$PROFILE'"
        info "Endpoint: $ENDPOINT  (OpenAI-compatible at $ENDPOINT/v1)"
        info "Follow the load with: llamactl logs -f"
        ;;

      stop|down)
        ''${SUDO:-sudo} systemctl stop "$UNIT"
        success "llama-server stopped"
        ;;

      restart)
        ''${SUDO:-sudo} systemctl restart "$UNIT"
        success "llama-server restarted"
        ;;

      status)
        echo -e "''${CYAN}=== llama.cpp ===''${NC}"
        echo "Backend:        ${cfg.backend}"
        echo "Package:        ${llamaPackage}"
        echo "Endpoint:       $ENDPOINT"
        echo "Default device: ${if cfg.defaultDevice == null then "(auto)" else cfg.defaultDevice}"
        echo "Store:          $STORE"
        if [ -r "$ACTIVE" ]; then
          echo "Active profile: $(cat "$ACTIVE")"
        else
          echo "Active profile: ${cfg.defaultProfile} (default)"
        fi
        echo ""
        systemctl status "$UNIT" --no-pager --lines 0 || true
        echo ""
        echo -e "''${CYAN}=== Health ===''${NC}"
        curl -fsS --max-time 3 "$ENDPOINT/health" 2>/dev/null || echo "(not responding)"
        echo ""
        ;;

      health)
        curl -fsS --max-time 5 "$ENDPOINT/health" || { error "no response from $ENDPOINT"; exit 1; }
        echo ""
        ;;

      logs)
        shift || true
        journalctl -u "$UNIT" --no-pager -n 200 "$@"
        ;;

      profiles)
        echo -e "''${CYAN}=== Profiles ===''${NC}"
        for name in $(list_profiles); do
          echo -e "''${GREEN}$name''${NC}"
          sed 's/^/    /' "$PROFILES_DIR/''${name}.args" | paste -sd' ' - | fold -s -w 100 | sed 's/^/    /'
        done
        ;;

      models)
        ensure_dirs
        echo -e "''${CYAN}=== GGUF models ===''${NC}"
        for d in "''${MODEL_PATHS[@]}" "${paths.imported}" "${paths.unified}"; do
          [ -d "$d" ] || continue
          echo -e "''${BLUE}$d''${NC}"
          find "$d" -maxdepth 2 \( -name '*.gguf' -o -type l \) -printf '    %f\t%s\n' 2>/dev/null \
            | numfmt --to=iec --field=2 --invalid=ignore || true
        done
        ;;

      devices)
        ${llamaPackage}/bin/llama-server --list-devices
        ;;

      pull)
        # Direct HF download into the store. Set HF_TOKEN for gated repos.
        REPO="''${2:-}"; FILE="''${3:-}"
        if [ -z "$REPO" ]; then
          error "usage: llamactl pull <hf-repo> [file.gguf]"
          echo "  e.g. llamactl pull unsloth/Qwen3-30B-A3B-GGUF Qwen3-30B-A3B-Q4_K_M.gguf"
          echo "  omit the file to let llama.cpp resolve it (llamactl pull <repo>:<quant>)"
          exit 1
        fi
        ensure_dirs
        DEST="''${MODEL_PATHS[0]}"
        if [ -n "$FILE" ]; then
          info "Downloading $REPO / $FILE -> $DEST"
          curl -fL --progress-bar \
            ''${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
            "https://huggingface.co/$REPO/resolve/main/$FILE?download=true" \
            -o "$DEST/$FILE"
          success "$DEST/$FILE"
        else
          info "Resolving $REPO via llama.cpp (LLAMA_CACHE=$STORE/hf-cache)"
          LLAMA_CACHE="$STORE/hf-cache" ${llamaPackage}/bin/llama-cli \
            -hf "$REPO" --no-warmup -n 0 -p "" >/dev/null
          success "cached under $STORE/hf-cache"
        fi
        ;;

      ollama-import)
        # Ollama stores GGUFs as content-addressed blobs. Resolve the model
        # layer of each manifest and symlink it under a human name — read-only,
        # no copy, so a 20 GB model is not duplicated on disk.
        ensure_dirs
        MANIFESTS="$OLLAMA_ROOT/manifests"
        BLOBS="$OLLAMA_ROOT/blobs"
        WANT="''${2:-}"
        if [ ! -d "$MANIFESTS" ]; then
          error "No Ollama manifests at $MANIFESTS"
          exit 1
        fi
        count=0
        while IFS= read -r manifest; do
          rel="''${manifest#"$MANIFESTS"/}"          # registry/ns/name/tag
          name="$(basename "$(dirname "$rel")")"
          tag="$(basename "$rel")"
          if [ -n "$WANT" ] && [ "$name:$tag" != "$WANT" ] && [ "$name" != "$WANT" ]; then
            continue
          fi
          digest="$(jq -r '.layers[] | select(.mediaType=="application/vnd.ollama.image.model") | .digest' "$manifest" 2>/dev/null || true)"
          [ -n "$digest" ] || { warn "no model layer in $name:$tag"; continue; }
          blob="$BLOBS/''${digest/:/-}"
          if [ ! -r "$blob" ]; then
            warn "blob missing or unreadable for $name:$tag ($blob)"
            continue
          fi
          link="${paths.imported}/''${name}-''${tag}.gguf"
          ln -sfn "$blob" "$link"
          success "$name:$tag -> $link"
          count=$((count + 1))
        done < <(find "$MANIFESTS" -type f)
        if [ "$count" -eq 0 ]; then
          warn "Nothing imported''${WANT:+ for '$WANT'}"
        else
          info "$count model(s) linked into ${paths.imported}"
        fi
        ;;

      shard)
        # llama.cpp has no cross-disk sharding primitive. What it DOES have is
        # one mmap per GGUF part — so putting the parts of a multi-part model
        # on different NVMes makes the page-fault streaming that dominates an
        # oversized MoE read from both queues at once. Single-file models get
        # no benefit and are reported as such rather than shuffled around.
        MODEL="''${2:-}"
        if [ -z "$MODEL" ]; then
          error "usage: llamactl shard <first-part.gguf>"
          exit 1
        fi
        if [ ''${#MODEL_PATHS[@]} -lt 2 ]; then
          warn "Only one model path configured — nothing to stripe across."
          warn "Add a second entry to services.llamaCpp.modelPaths."
          exit 0
        fi
        ensure_dirs
        base="$(basename "$MODEL")"
        dir="$(dirname "$(readlink -f "$MODEL")")"
        stem="''${base%-*-of-*.gguf}"
        if [ "$stem" = "$base" ]; then
          info "$base is a single-file GGUF — striping does not apply."
          ln -sfn "$(readlink -f "$MODEL")" "${paths.unified}/$base"
          success "linked into ${paths.unified}"
          exit 0
        fi
        mapfile -t parts < <(find "$dir" -maxdepth 1 -name "''${stem}-*-of-*.gguf" | sort)
        info "''${#parts[@]} part(s) of '$stem' across ''${#MODEL_PATHS[@]} disk(s)"
        i=0
        for part in "''${parts[@]}"; do
          target="''${MODEL_PATHS[$((i % ''${#MODEL_PATHS[@]}))]}"
          pbase="$(basename "$part")"
          if [ "$(dirname "$part")" != "$target" ]; then
            info "moving $pbase -> $target"
            mv "$part" "$target/$pbase"
          fi
          ln -sfn "$target/$pbase" "${paths.unified}/$pbase"
          i=$((i + 1))
        done
        success "unified view: ${paths.unified}/''${stem}-00001-of-*.gguf"
        info "Point a profile's `model` at that path."
        ;;

      autotune)
        # nCpuMoe is a one-dimensional knob: the fewer layers whose experts sit
        # on the CPU, the more of the model is GPU-resident and the faster it
        # runs — until it no longer fits 8 GB and llama-server dies on load.
        # Binary-search the smallest value that still loads.
        PROFILE="''${2:-${cfg.defaultProfile}}"
        require_profile "$PROFILE"
        MAXL="''${3:-64}"
        ensure_dirs
        mapfile -t BASE < "$PROFILES_DIR/''${PROFILE}.args"
        # Drop any baked-in --n-cpu-moe / --port so we can sweep on a scratch port.
        ARGS=(); skip=0
        for a in "''${BASE[@]}"; do
          if [ "$skip" -eq 1 ]; then skip=0; continue; fi
          case "$a" in
            --n-cpu-moe|--port) skip=1; continue ;;
          esac
          ARGS+=("$a")
        done
        PORT=$(( ${toString cfg.network.port} + 1 ))
        lo=0; hi="$MAXL"; best=""
        info "Sweeping --n-cpu-moe over [0, $MAXL] for profile '$PROFILE' on port $PORT"
        while [ "$lo" -le "$hi" ]; do
          mid=$(( (lo + hi) / 2 ))
          printf '  n-cpu-moe=%-3s ... ' "$mid"
          ${llamaPackage}/bin/llama-server "''${ARGS[@]}" \
            --port "$PORT" --n-cpu-moe "$mid" >/tmp/llama-autotune.log 2>&1 &
          pid=$!
          ok=0
          for _ in $(seq 1 120); do
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
              ok=1; break
            fi
            sleep 1
          done
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          if [ "$ok" -eq 1 ]; then
            echo -e "''${GREEN}loaded''${NC}"
            best="$mid"; hi=$(( mid - 1 ))
          else
            echo -e "''${RED}failed''${NC}"
            lo=$(( mid + 1 ))
          fi
        done
        echo ""
        if [ -n "$best" ]; then
          success "Smallest value that loads: --n-cpu-moe $best"
          info "Set it in configuration.nix:"
          echo "    services.llamaCpp.profiles.$PROFILE.nCpuMoe = $best;"
          warn "Leave 1-2 layers of headroom if you also run a compositor on this GPU."
        else
          error "No value in [0, $MAXL] loaded. Last log: /tmp/llama-autotune.log"
          exit 1
        fi
        ;;

      bench)
        PROFILE="''${2:-${cfg.defaultProfile}}"
        require_profile "$PROFILE"
        MODEL="$(grep -A1 -x -- '--model' "$PROFILES_DIR/''${PROFILE}.args" | tail -1 || true)"
        if [ -z "$MODEL" ]; then
          error "Profile '$PROFILE' has no --model (HF-resolved profiles cannot be benched directly)."
          exit 1
        fi
        NCM="$(grep -A1 -x -- '--n-cpu-moe' "$PROFILES_DIR/''${PROFILE}.args" | tail -1 || true)"
        info "llama-bench: $MODEL''${NCM:+ (n-cpu-moe=$NCM)}"
        ${llamaPackage}/bin/llama-bench -m "$MODEL" ''${NCM:+--n-cpu-moe "$NCM"} "''${@:3}"
        ;;

      help|--help|-h|*)
        cat <<EOF
    llamactl — dedicated llama.cpp MoE inference control

      start [profile]     Start/switch llama-server (default: ${cfg.defaultProfile})
      stop | restart      Stop / restart the service
      status              Backend, active profile, unit state, /health
      health              Just the /health probe
      logs [-f]           journalctl for llama-server.service
      profiles            List configured profiles and their argv
      models              List GGUFs across every configured model path
      devices             Enumerate GPUs llama.cpp can see
      pull <repo> [file]  Download a GGUF from HuggingFace into the store
      ollama-import [tag] Symlink models from ~/.ollama into the store
      shard <part1.gguf>  Stripe a multi-part GGUF across the configured disks
      autotune [profile]  Binary-search the best --n-cpu-moe for this hardware
      bench [profile]     llama-bench pp/tg numbers

    Endpoint: $ENDPOINT   (OpenAI-compatible at $ENDPOINT/v1)
    Backend:  ${cfg.backend}   Device: ${if cfg.defaultDevice == null then "(auto)" else cfg.defaultDevice}

    This is separate from the Ollama stack (ai-stack, :11434). They cannot both
    hold the dGPU's 8 GB — 'llamactl start' warns when Ollama has a model resident.
EOF
        ;;
    esac
  '';

  # ── Profile submodule ──────────────────────────────────────────────────────
  profileType = types.submodule {
    options = {
      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          GGUF path. Absolute paths are used as-is; anything else is resolved
          against `services.llamaCpp.storePath`.
        '';
        example = "gguf/Qwen3-30B-A3B-Q4_K_M.gguf";
      };

      hfRepo = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "HuggingFace repo to resolve when `model` is null (llama.cpp -hf).";
        example = "unsloth/Qwen3-30B-A3B-GGUF:Q4_K_M";
      };

      hfFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Specific file within `hfRepo`.";
      };

      alias = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Model name reported over the API. Defaults to the profile name.";
      };

      ctx = mkOption {
        type = types.ints.positive;
        default = 32768;
        description = "Context window. KV cache scales with this — see cacheTypeK/V.";
      };

      nGpuLayers = mkOption {
        type = types.int;
        default = 999;
        description = ''
          Layers offloaded to the GPU. For MoE the intended setting is 999
          ("all"), with `nCpuMoe` clawing the expert tensors back to the CPU.
          Lowering this instead moves *whole* layers off the GPU, which is
          strictly worse for MoE: it evicts the attention tensors that benefit
          most from the GPU.
        '';
      };

      nCpuMoe = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Keep the expert FFN tensors of the first N layers in system RAM
          (llama.cpp `--n-cpu-moe`). This is the knob that makes an MoE larger
          than VRAM viable. Raise until it fits 8 GB, lower until it OOMs;
          `llamactl autotune <profile>` searches it automatically.
        '';
      };

      overrideTensor = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Raw `--override-tensor` regex, for placements `nCpuMoe` cannot
          express (e.g. sending only up/gate projections to CPU).
        '';
        example = "blk\\..*\\.ffn_(up|gate)_exps\\.weight=CPU";
      };

      device = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Device to offload to. Null inherits `services.llamaCpp.defaultDevice`
          (the dGPU). Run `llamactl devices` for the names.
        '';
        example = "ROCm0";
      };

      tensorSplit = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Proportional split across the selected devices. Rarely useful here:
          the second GPU is the iGPU, which shares system RAM with the CPU and
          so adds a copy rather than bandwidth. Exposed for measurement.
        '';
        example = "1.0,0.0";
      };

      flashAttn = mkOption {
        type = types.enum [ "on" "off" "auto" ];
        default = "on";
        description = "Flash attention. Halves KV cache traffic at long context.";
      };

      cacheTypeK = mkOption {
        type = types.str;
        default = "q8_0";
        description = "KV cache K quantisation. Matches the Ollama stack's OLLAMA_KV_CACHE_TYPE.";
      };

      cacheTypeV = mkOption {
        type = types.str;
        default = "q8_0";
        description = "KV cache V quantisation.";
      };

      threads = mkOption {
        type = types.ints.positive;
        default = 7;
        description = ''
          Generation threads. Defaults to 7, not 16: the 7840HS has 8 physical
          cores and `isolcpus=0,1` (from vm-manager/modules/dsp-vm.nix) takes
          one of them away from the scheduler. Oversubscribing hurts MoE token
          generation, which is memory-bound.
        '';
      };

      threadsBatch = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Prompt-processing threads. Null uses `threads`.";
      };

      batchSize = mkOption {
        type = types.ints.positive;
        default = 2048;
        description = "Logical batch size for prompt processing.";
      };

      ubatchSize = mkOption {
        type = types.ints.positive;
        default = 512;
        description = "Physical micro-batch. Lower this first if prompt processing OOMs.";
      };

      parallel = mkOption {
        type = types.ints.positive;
        default = 1;
        description = ''
          Concurrent sequences. Each one costs a full KV cache slice, so on 8 GB
          this stays at 1 unless the model is small.
        '';
      };

      mmap = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Keep this on. mmap is what lets a model larger than RAM run at all:
          weights are demand-paged from NVMe and evicted as clean pages rather
          than being swapped.
        '';
      };

      mlock = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Pin weights in RAM. Counterproductive for an oversized MoE — it
          forbids the eviction that makes disk streaming work.
        '';
      };

      jinja = mkOption {
        type = types.bool;
        default = true;
        description = "Use the model's embedded chat template (needed for tool calling).";
      };

      draftModel = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Draft model for speculative decoding. Paired with `draftDevice` this
          is the one arrangement where the iGPU genuinely helps: it runs the
          small draft model while the dGPU stays entirely on the target MoE.
        '';
      };

      draftDevice = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Device for the draft model. Null inherits `defaultDraftDevice`.";
      };

      draftNGpuLayers = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "GPU layers for the draft model.";
      };

      nDraft = mkOption {
        type = types.ints.positive;
        default = 16;
        description = "Tokens drafted per speculation round.";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra llama-server arguments, appended last.";
      };
    };
  };

in
{
  # ── Options ────────────────────────────────────────────────────────────────
  options.services.llamaCpp = {
    enable = mkEnableOption "dedicated llama.cpp MoE inference server";

    backend = mkOption {
      type = types.enum [ "rocm" "vulkan" "cpu" ];
      default = "rocm";
      description = ''
        Compute backend.

        `rocm` — HIP against gfx1102 (RX 7700S) and gfx1103 (780M). Best
        prompt-processing throughput on RDNA3. The first build compiles rocBLAS
        and takes hours.

        `vulkan` — RADV. A much smaller build that also sees both GPUs, at some
        cost in prompt-processing speed on long contexts.

        `cpu` — OpenBLAS only.
      '';
    };

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "Override the llama.cpp package entirely. Null derives it from `backend`.";
    };

    rocmGpuTargets = mkOption {
      type = types.str;
      default = "gfx1102;gfx1103";
      description = ''
        ROCm targets compiled into one binary — the dGPU and the iGPU. Building
        both is what avoids HSA_OVERRIDE_GFX_VERSION, which is process-global
        and would force a single target onto both devices.
      '';
    };

    storePath = mkOption {
      type = types.str;
      default = "/mnt/models/llama";
      description = ''
        Model store root. Belongs on the second NVMe: the system disk is
        effectively full and MoE quants run to tens of gigabytes.
      '';
    };

    modelPaths = mkOption {
      type = types.listOf types.str;
      default = [ "${cfg.storePath}/gguf" ];
      defaultText = literalExpression ''[ "''${storePath}/gguf" ]'';
      description = ''
        Directories searched for GGUFs, in preference order. Listing paths on
        two physical disks lets `llamactl shard` stripe a multi-part GGUF
        across both, so the page-fault streaming of an oversized MoE reads from
        both NVMe queues at once.
      '';
    };

    ollamaModelsPath = mkOption {
      type = types.str;
      default = "/home/asher/.ollama/models";
      description = "Ollama blob store that `llamactl ollama-import` reads.";
    };

    defaultProfile = mkOption {
      type = types.str;
      default = "gpt-oss-20b";
      description = "Profile started when no explicit profile has been selected.";
    };

    defaultDevice = mkOption {
      type = types.nullOr types.str;
      default = if cfg.backend == "vulkan" then "Vulkan0" else "ROCm0";
      defaultText = literalExpression ''"ROCm0" (or "Vulkan0" when backend = "vulkan")'';
      description = ''
        Device profiles inherit when they do not set one. Defaults to the
        *discrete* GPU rather than letting llama.cpp auto-split: the eDP panel
        is driven by the iGPU, so pinning here dedicates all 8 GB of the RX
        7700S to inference while the Hyprland session keeps running on the
        780M. Set to null to let llama.cpp choose.
      '';
    };

    defaultDraftDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Device for speculative-decoding draft models. Set to the iGPU
        (`ROCm1`/`Vulkan1`) to run the draft model there while the dGPU stays
        on the target model.
      '';
      example = "ROCm1";
    };

    visibleDevices = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ROCR_VISIBLE_DEVICES for the service. Usually unnecessary — prefer
        `defaultDevice`, which selects without hiding the iGPU from draft
        models.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "asher";
      description = ''
        User the server runs as. Defaults to the primary user rather than a
        dedicated system account because `llamactl ollama-import` links models
        out of `~/.ollama`, which is mode 0700 and owned by that user.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Group the server runs as.";
    };

    autoStart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Start llama-server at boot. Off by default: loading a multi-gigabyte
        MoE at every boot is rarely what you want on a laptop, and it would
        claim the dGPU before you asked it to.
      '';
    };

    profiles = mkOption {
      type = types.attrsOf profileType;
      default = { };
      description = ''
        Named model configurations. Switching models is `llamactl start <name>`
        — no rebuild, because the unit reads the active profile from a state
        file.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables for llama-server.service.";
    };

    readaheadKB = mkOption {
      type = types.nullOr types.ints.positive;
      default = 2048;
      description = ''
        Per-NVMe read-ahead in KB, applied by udev. The default 128 KB is tuned
        for random I/O; an oversized MoE streams weights sequentially, so a
        larger window measurably helps the disk-bound case. Null leaves the
        kernel default alone.
      '';
    };

    network = {
      bindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Listen address. Keep on loopback unless you mean it.";
      };

      port = mkOption {
        type = types.port;
        default = 8080;
        description = "Listen port. `autotune` also uses port+1 as scratch.";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open the port. Ignored while bound to loopback.";
      };
    };
  };

  # ── Config ─────────────────────────────────────────────────────────────────
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.profiles != { };
        message = "services.llamaCpp: at least one profile must be defined.";
      }
      {
        assertion = cfg.profiles ? ${cfg.defaultProfile};
        message =
          "services.llamaCpp.defaultProfile is '${cfg.defaultProfile}', which is not in "
          + "services.llamaCpp.profiles (have: ${concatStringsSep ", " profileNames}).";
      }
      {
        assertion = all (p: p.model != null || p.hfRepo != null) (attrValues cfg.profiles);
        message = "services.llamaCpp: every profile needs either `model` or `hfRepo`.";
      }
    ];

    warnings =
      optional (cfg.backend == "rocm" && cfg.package == null)
        ("services.llamaCpp.backend = \"rocm\" builds rocBLAS from source on first "
          + "rebuild and will take hours. Set backend = \"vulkan\" for a fast path.");

    environment.systemPackages = [
      llamaPackage
      llamactl
      pkgs.curl
      pkgs.jq
    ] ++ optionals (cfg.backend == "rocm") [
      pkgs.rocmPackages.rocm-smi
      pkgs.rocmPackages.rocminfo
    ];

    environment.shellAliases = {
      llama = "llamactl";
      llama-start = "llamactl start";
      llama-stop = "llamactl stop";
      llama-logs = "llamactl logs -f";
    };

    systemd.tmpfiles.rules = [
      "d ${paths.state} 0755 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.llama-server = {
      description = "llama.cpp inference server (MoE)";
      documentation = [ "https://github.com/ggml-org/llama.cpp" ];
      after = [ "network.target" ];
      wantedBy = optional cfg.autoStart "multi-user.target";

      # Refuse to start when the model store's disk is not mounted, rather
      # than silently reading an empty directory on the root filesystem.
      unitConfig.RequiresMountsFor = unique ([ cfg.storePath ] ++ cfg.modelPaths);

      environment = serviceEnv;

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        # /dev/kfd + /dev/dri for ROCm; the render node for Vulkan.
        SupplementaryGroups = [ "video" "render" ];
        ExecStartPre = pkgs.writeShellScript "llama-server-pre" ''
          install -d -m 0755 ${escapeShellArgs (unique (
            [ paths.imported paths.unified "${cfg.storePath}/hf-cache" ] ++ cfg.modelPaths
          ))}
        '';
        ExecStart = serverRunner;
        Restart = "on-failure";
        RestartSec = 5;
        # A big MoE can take minutes to fault in from NVMe on a cold start.
        TimeoutStartSec = "15min";
        KillSignal = "SIGINT";

        # Hardening. Deliberately NOT MemoryHigh/MemoryMax: model pages are
        # clean, file-backed mmap pages, so the kernel reclaims them under
        # pressure. A cgroup limit would instead throttle the page cache that
        # makes disk streaming tolerable.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        ReadWritePaths = unique ([ paths.state cfg.storePath ] ++ cfg.modelPaths);
        DeviceAllow = [ "/dev/kfd rw" "/dev/dri rw" ];
        PrivateTmp = true;
        # Read-only view of $HOME so imported symlinks into ~/.ollama resolve.
        ProtectHome = "read-only";
      };
    };

    # Sequential-streaming read-ahead for the model store disks. The kernel
    # default (128 KB) is a random-I/O compromise; an oversized MoE faults its
    # weights in essentially sequentially.
    services.udev.extraRules = mkIf (cfg.readaheadKB != null) ''
      # services.llamaCpp: larger read-ahead for GGUF weight streaming
      ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="${toString cfg.readaheadKB}"
    '';

    networking.firewall.allowedTCPPorts =
      mkIf (cfg.network.openFirewall && cfg.network.bindAddress != "127.0.0.1")
        [ cfg.network.port ];
  };
}
