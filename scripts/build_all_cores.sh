#!/bin/bash

# Build all bundled libretro cores (mGBA + FCEUmm + FBNeo)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${1:-android}"

echo "=== Building mGBA (GBA/GB/GBC) ==="
"$SCRIPT_DIR/build_mgba_libretro.sh" "$PLATFORM"

echo ""
echo "=== Building FCEUmm (NES/FC) ==="
"$SCRIPT_DIR/build_fceumm_libretro.sh" "$PLATFORM"

echo ""
echo "=== Building FBNeo (Arcade) ==="
"$SCRIPT_DIR/build_fbneo_libretro.sh" "$PLATFORM"

echo ""
echo "All cores built."
