#!/bin/bash

# Build all bundled libretro cores (gpSP + FCEUmm + FBNeo)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${1:-android}"

echo "=== Building gpSP (GBA) ==="
"$SCRIPT_DIR/build_gpsp_libretro.sh" "$PLATFORM"

echo ""
echo "=== Building FCEUmm (NES/FC) ==="
"$SCRIPT_DIR/build_fceumm_libretro.sh" "$PLATFORM"

echo ""
echo "=== Building FBNeo (Arcade) ==="
"$SCRIPT_DIR/build_fbneo_libretro.sh" "$PLATFORM"

echo ""
echo "All cores built."
