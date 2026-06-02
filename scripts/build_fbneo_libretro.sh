#!/bin/bash

# Build FBNeo libretro core (arcade) for mobile (Android & iOS)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build/libretro"
JNI_LIBS_DIR="$PROJECT_DIR/android/app/src/main/jniLibs"
IOS_FRAMEWORKS_DIR="$PROJECT_DIR/ios/Runner/Frameworks"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Building FBNeo libretro core (arcade)...${NC}"

# Libretro port lives in libretro/FBNeo (src/burner/libretro), not finalburnneo standalone tree.
FBNEO_DIR="$BUILD_DIR/FBNeo"
LIBRETRO_DIR="$FBNEO_DIR/src/burner/libretro"
if [ ! -f "$LIBRETRO_DIR/Makefile" ]; then
    echo -e "${YELLOW}Cloning libretro/FBNeo...${NC}"
    rm -rf "$FBNEO_DIR"
    mkdir -p "$BUILD_DIR"
    git clone --depth 1 https://github.com/libretro/FBNeo.git "$FBNEO_DIR"
fi

mkdir -p "$JNI_LIBS_DIR"

flutter_ndk_version() {
    local flutter_sdk=""
    local local_props="$PROJECT_DIR/android/local.properties"

    if [ -f "$local_props" ]; then
        flutter_sdk="$(grep '^flutter.sdk=' "$local_props" | cut -d= -f2- | tr -d '\r')"
    fi
    if [ -z "$flutter_sdk" ] && [ -n "${FLUTTER_ROOT:-}" ]; then
        flutter_sdk="$FLUTTER_ROOT"
    fi
    if [ -z "$flutter_sdk" ] && command -v flutter &> /dev/null; then
        flutter_sdk="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
    fi
    if [ -z "$flutter_sdk" ]; then
        return 1
    fi

    local ext="$flutter_sdk/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt"
    if [ ! -f "$ext" ]; then
        return 1
    fi

    grep 'val ndkVersion' "$ext" | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1
}

# Resolve ANDROID_NDK_HOME: use Flutter's ndkVersion unless ANDROID_NDK_HOME is already set
resolve_android_ndk_home() {
    if [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]; then
        export ANDROID_NDK_HOME
        return 0
    fi

    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    local ndk_root="$sdk_root/ndk"
    local version
    version="$(flutter_ndk_version)" || true
    if [ -z "$version" ]; then
        echo -e "${RED}Could not read Flutter ndkVersion (check android/local.properties flutter.sdk).${NC}" >&2
        return 1
    fi

    ANDROID_NDK_HOME="$ndk_root/$version"
    if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]; then
        echo -e "${RED}Flutter NDK $version not found at $ANDROID_NDK_HOME${NC}" >&2
        echo "Install it in Android Studio: SDK Manager → SDK Tools → NDK (Side by side) → $version" >&2
        return 1
    fi
    export ANDROID_NDK_HOME
}

copy_android_core() {
    local abi="$1"
    local src="$2"
    if [ ! -f "$src" ]; then
        echo -e "${RED}Build output not found: $src${NC}" >&2
        return 1
    fi

    mkdir -p "$JNI_LIBS_DIR/$abi"
    cp "$src" "$JNI_LIBS_DIR/$abi/libfbneo_libretro.so"
    echo -e "${GREEN}Android $abi: libfbneo_libretro.so${NC}"
}

build_android() {
    if ! resolve_android_ndk_home; then
        echo -e "${RED}Android NDK not found.${NC}" >&2
        echo "Install NDK in Android Studio (SDK Manager → NDK), or set:" >&2
        echo "  export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/<version>" >&2
        return 1
    fi

    export PATH="$ANDROID_NDK_HOME:$PATH"
    local ndk_build="$ANDROID_NDK_HOME/ndk-build"
    if [ ! -x "$ndk_build" ]; then
        echo -e "${RED}ndk-build not found at $ndk_build${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}Using Flutter NDK $(basename "$ANDROID_NDK_HOME"): $ANDROID_NDK_HOME${NC}"

    local abi="arm64-v8a"
    local jobs
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

    echo -e "${YELLOW}Building FBNeo for $abi (ndk-build)...${NC}"
    "$ndk_build" -C "$LIBRETRO_DIR/jni" clean APP_ABI="$abi" >/dev/null 2>&1 || true
    "$ndk_build" -C "$LIBRETRO_DIR/jni" -j"$jobs" APP_ABI="$abi"

    local src="$LIBRETRO_DIR/libs/$abi/libretro.so"
    if [ ! -f "$src" ]; then
        src="$(find "$LIBRETRO_DIR/libs" -name 'libretro.so' -type f 2>/dev/null | head -1)"
    fi
    copy_android_core "$abi" "$src"
}

build_ios() {
    echo -e "${GREEN}Building FBNeo for iOS...${NC}"
    local jobs
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

    make -C "$LIBRETRO_DIR" -f Makefile platform=ios-arm64 clean >/dev/null 2>&1 || true
    make -C "$LIBRETRO_DIR" -f Makefile platform=ios-arm64 -j"$jobs"

    local src="$LIBRETRO_DIR/fbneo_libretro_ios.dylib"
    if [ ! -f "$src" ]; then
        src="$(find "$LIBRETRO_DIR" -maxdepth 1 -name 'fbneo_libretro*.dylib' -type f 2>/dev/null | head -1)"
    fi
    if [ ! -f "$src" ]; then
        echo -e "${RED}iOS dylib not found under $LIBRETRO_DIR${NC}" >&2
        return 1
    fi

    mkdir -p "$IOS_FRAMEWORKS_DIR"
    cp "$src" "$IOS_FRAMEWORKS_DIR/fbneo_libretro_ios.dylib"
    echo -e "${GREEN}iOS: $IOS_FRAMEWORKS_DIR/fbneo_libretro_ios.dylib${NC}"
}

PLATFORM="${1:-android}"

case "$PLATFORM" in
    ios) build_ios ;;
    android) build_android ;;
    all)
        build_ios || true
        build_android || true
        ;;
    *)
        echo "Usage: $0 [android|ios|all]"
        exit 1
        ;;
esac

echo -e "${GREEN}FBNeo build done.${NC}"
