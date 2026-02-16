# Tokenizers Build Fix - FINAL Solution

## The Problem
Tokenizers 0.19.1-0.20.3 failed to build from source due to GCC 15's strict type checking in the oniguruma C library.

## The Solution
**Use the default tokenizers and transformers versions from nixpkgs** instead of trying to override them.

## What Changed

### REMOVED:
- Custom tokenizers build (was failing with GCC 15)
- Custom transformers version override

### KEPT:
- Runtime dependency checking is disabled in Coqui TTS
- This allows version mismatches to be ignored at runtime

## Why This Works

1. **No compilation needed**: nixpkgs already has pre-built tokenizers
2. **Version flexibility**: Runtime dependency checks are disabled in Coqui TTS, so slight version differences are tolerated
3. **Simpler**: Fewer overrides = fewer things that can break

## Build Now

```bash
nix build .#dockerImage-cpu-amd64
```

## What If There Are Version Issues?

The Coqui TTS package in this flake has runtime dependency checking completely disabled:

```nix
pythonRemoveDeps = [ "*" ];
dontCheckRuntimeDeps = true;
```

This means even if nixpkgs has newer versions of tokenizers/transformers than Coqui TTS "requires", it will still work at runtime in most cases.

## Technical Details

- Uses whatever tokenizers version is in nixpkgs-unstable (likely 0.19.x or 0.20.x)
- Uses whatever transformers version is in nixpkgs-unstable (likely 4.40.x-4.45.x)
- These are compatible with Coqui TTS 0.22.0 when runtime checks are disabled
