# Hash Fix - Progress Report

## What Just Happened

The `fix-hashes.sh` script successfully found the correct hashes for:
- ✅ **bnnumerizer 0.0.2**: `sha256-Qd9v0Le1GqTsR3a2ZDzt6+5f0R4zXX1W1KIMCFFeXw0=`
- ✅ **bnunicodenormalizer 0.1.6**: `sha256-qVC6+0SnAs25DFzKPHFUOoYPlrRvkGWFptjIVom8wJM=`

However, the script's sed replacement accidentally swapped them because both packages had the same placeholder hash.

## Current Status

**Hashes we have:**
1. ✅ hangul-romanize 0.1.0: `sha256-+uaboYGvbnWoZGD9f1emswTNXxlz2MQl7YYC/uLJJ2w=`
2. ✅ bnnumerizer 0.0.2: `sha256-Qd9v0Le1GqTsR3a2ZDzt6+5f0R4zXX1W1KIMCFFeXw0=`
3. ✅ bnunicodenormalizer 0.1.6: `sha256-qVC6+0SnAs25DFzKPHFUOoYPlrRvkGWFptjIVom8wJM=`
4. ⏳ g2pkk 0.1.2: Will get hash on next build

## What to Do Now

### Option 1: Use the Complete Fixed Flake (Recommended)

```bash
# Replace with the final version that has all correct hashes
cp flake.nix.final flake.nix

# Build - will get g2pkk hash
nix build .#dockerImage-cpu-amd64 2>&1 | tee build.log

# If g2pkk hash fails, copy the correct hash from build.log and update flake.nix
# Then build again
```

### Option 2: Manual Fix

Edit your current `flake.nix` and update the hashes:

**Line ~76 (bnnumerizer):**
```nix
src = pkgs.fetchPypi {
  inherit pname version;
  sha256 = "sha256-Qd9v0Le1GqTsR3a2ZDzt6+5f0R4zXX1W1KIMCFFeXw0=";  # ✅ Correct
};
```

**Line ~88 (bnunicodenormalizer):**
```nix
src = pkgs.fetchPypi {
  inherit pname version;
  sha256 = "sha256-qVC6+0SnAs25DFzKPHFUOoYPlrRvkGWFptjIVom8wJM=";  # ✅ Correct
};
```

**Line ~64 (g2pkk):**
```nix
src = pkgs.fetchPypi {
  inherit pname version;
  sha256 = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";  # ⏳ Will get from next build
};
```

## Understanding the Build Output

When you see this:
```
error: hash mismatch in fixed-output derivation '/nix/store/xxx-package-version.tar.gz.drv':
         specified: sha256-WRONG_HASH
            got:    sha256-CORRECT_HASH_HERE
```

The **"got:"** line contains the correct hash. Copy it into your flake.nix.

## Next Steps

1. **Apply the fix:**
   ```bash
   cp flake.nix.final flake.nix
   ```

2. **Build and watch for g2pkk:**
   ```bash
   nix build .#dockerImage-cpu-amd64
   ```

3. **If g2pkk fails:**
   - Look for "hash mismatch" error
   - Copy the hash from the "got:" line
   - Update line ~64 in flake.nix
   - Build again

4. **Success criteria:**
   The build will succeed when you see:
   ```
   /nix/store/xxx-demod-voice.tar.gz
   ```

## Complete Hash Reference

Once all hashes are correct, your flake.nix should have:

```nix
# Line ~50
hangul-romanize = prev.buildPythonPackage rec {
  pname = "hangul-romanize";
  version = "0.1.0";
  src = pkgs.fetchPypi {
    inherit pname version;
    sha256 = "sha256-+uaboYGvbnWoZGD9f1emswTNXxlz2MQl7YYC/uLJJ2w=";
  };
  ...
};

# Line ~64
g2pkk = prev.buildPythonPackage rec {
  pname = "g2pkk";
  version = "0.1.2";
  src = pkgs.fetchPypi {
    inherit pname version;
    sha256 = "sha256-WILL_BE_REVEALED_NEXT";  # ← Update this
  };
  ...
};

# Line ~76
bnnumerizer = prev.buildPythonPackage rec {
  pname = "bnnumerizer";
  version = "0.0.2";
  src = pkgs.fetchPypi {
    inherit pname version;
    sha256 = "sha256-Qd9v0Le1GqTsR3a2ZDzt6+5f0R4zXX1W1KIMCFFeXw0=";
  };
  ...
};

# Line ~88
bnunicodenormalizer = prev.buildPythonPackage rec {
  pname = "bnunicodenormalizer";
  version = "0.1.6";
  src = pkgs.fetchPypi {
    inherit pname version;
    sha256 = "sha256-qVC6+0SnAs25DFzKPHFUOoYPlrRvkGWFptjIVom8wJM=";
  };
  ...
};
```

## Why This Happens

Nix downloads packages and verifies their SHA256 hash matches what you specified. This ensures:
1. **Security**: The package hasn't been tampered with
2. **Reproducibility**: Everyone gets the exact same file
3. **Purity**: Builds are deterministic

The placeholder hashes (`sha256-AAAA...`) will always fail, forcing Nix to tell you the correct hash.

## Estimated Time

- First build (after fixing all hashes): **30-90 minutes**
- Subsequent builds: **<5 minutes** (cached)

## Files

- **flake.nix.final** - Complete fix with 3/4 hashes correct
- **HASH_FIX_GUIDE.md** - Detailed instructions
- **fix-hashes.sh** - Auto-fixer script (has a bug with duplicate hashes)

---

**Quick Commands:**

```bash
# Apply the fix
cp flake.nix.final flake.nix

# Build
nix build .#dockerImage-cpu-amd64

# Watch for g2pkk hash error, then:
# 1. Copy hash from error's "got:" line
# 2. Update flake.nix line ~64
# 3. Build again

# When successful:
docker load < result
```
