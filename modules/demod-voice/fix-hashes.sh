#!/usr/bin/env bash
# Script to automatically fix package hashes in flake.nix
# Run this after a build failure shows hash mismatches

set -e

FLAKE_FILE="${1:-flake.nix}"

if [ ! -f "$FLAKE_FILE" ]; then
    echo "Error: $FLAKE_FILE not found"
    echo "Usage: $0 [flake.nix]"
    exit 1
fi

echo "=== DeMoD Voice Clone - Hash Fixer ==="
echo "Building to detect hash mismatches..."
echo ""

# Run build and capture errors
BUILD_LOG=$(mktemp)
nix build .#dockerImage-cpu-amd64 2>&1 | tee "$BUILD_LOG" || true

# Extract hash mismatches
MISMATCHES=$(grep -A 2 "hash mismatch" "$BUILD_LOG" || true)

if [ -z "$MISMATCHES" ]; then
    echo "✅ No hash mismatches found! Build may have succeeded."
    rm "$BUILD_LOG"
    exit 0
fi

echo "Found hash mismatches:"
echo "$MISMATCHES"
echo ""

# Parse and fix each mismatch
while IFS= read -r line; do
    if echo "$line" | grep -q "hash mismatch"; then
        PACKAGE=$(echo "$line" | grep -oP '/nix/store/[^/]+-\K[^-]+' | head -1)
        echo "📦 Package: $PACKAGE"
    fi
    
    if echo "$line" | grep -q "specified:"; then
        WRONG_HASH=$(echo "$line" | grep -oP 'sha256-[A-Za-z0-9+/=]+')
        echo "  ❌ Wrong: $WRONG_HASH"
    fi
    
    if echo "$line" | grep -q "got:"; then
        CORRECT_HASH=$(echo "$line" | grep -oP 'sha256-[A-Za-z0-9+/=]+')
        echo "  ✅ Correct: $CORRECT_HASH"
        
        # Replace in flake.nix
        if [ ! -z "$WRONG_HASH" ] && [ ! -z "$CORRECT_HASH" ]; then
            echo "  🔧 Fixing in $FLAKE_FILE..."
            sed -i "s|$WRONG_HASH|$CORRECT_HASH|g" "$FLAKE_FILE"
            WRONG_HASH=""
            CORRECT_HASH=""
        fi
    fi
done < "$BUILD_LOG"

rm "$BUILD_LOG"

echo ""
echo "=== Hash fixes applied! ==="
echo "Verifying changes..."
grep -n "sha256-" "$FLAKE_FILE" | grep -E "(g2pkk|bnnumerizer|bnunicodenormalizer|hangul-romanize)"
echo ""
echo "✅ Run 'nix build .#dockerImage-cpu-amd64' again to continue"
