#!/bin/bash

# Build all bundled libretro cores (mGBA + FCEUmm)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Building mGBA (GBA/GB/GBC) ==="
"$SCRIPT_DIR/build_mgba_libretro.sh" "${1:-android}"

echo ""
echo "=== Building FCEUmm (NES/FC) ==="
"$SCRIPT_DIR/build_fceumm_libretro.sh" "${1:-android}"

echo ""
echo "All cores built."
