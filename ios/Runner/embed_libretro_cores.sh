#!/bin/sh
# Copies libretro .dylib cores from Runner/Frameworks into the app bundle.
# Build cores first: ./scripts/build_all_cores.sh ios
set -e

SRC="${SRCROOT}/Runner/Frameworks"
DST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [ ! -d "$SRC" ]; then
  echo "warning: Libretro frameworks directory missing: $SRC"
  echo "warning: Run from project root: ./scripts/build_all_cores.sh ios"
  exit 0
fi

mkdir -p "$DST"
found=0

for lib in "$SRC"/*.dylib; do
  [ -f "$lib" ] || continue
  found=1
  name=$(basename "$lib")
  echo "Embedding libretro core: $name"
  cp -f "$lib" "$DST/$name"
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "$DST/$name" || true
  fi
done

if [ "$found" -eq 0 ]; then
  echo "warning: No .dylib in $SRC — run: ./scripts/build_all_cores.sh ios"
fi
