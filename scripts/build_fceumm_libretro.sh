#!/bin/bash

# Build FCEUmm libretro core (NES/FC) for mobile (Android & optional desktop)
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

echo -e "${GREEN}Building FCEUmm libretro core (NES/FC)...${NC}"

FCEUMM_DIR="$BUILD_DIR/libretro-fceumm"
if [ ! -d "$FCEUMM_DIR" ]; then
    echo -e "${YELLOW}Cloning libretro-fceumm...${NC}"
    mkdir -p "$BUILD_DIR"
    git clone --depth 1 https://github.com/libretro/libretro-fceumm.git "$FCEUMM_DIR"
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

resolve_android_ndk_home() {
    if [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]; then
        return 0
    fi

    local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    local ndk_root="$sdk_root/ndk"
    local version
    version="$(flutter_ndk_version)" || true
    if [ -z "$version" ]; then
        echo -e "${RED}Could not read Flutter ndkVersion.${NC}" >&2
        return 1
    fi

    ANDROID_NDK_HOME="$ndk_root/$version"
    if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]; then
        echo -e "${RED}NDK $version not found at $ANDROID_NDK_HOME${NC}" >&2
        return 1
    fi
    export ANDROID_NDK_HOME
}

ndk_prebuilt_dir() {
    local host
    case "$(uname -s)" in
        Darwin) host="darwin-x86_64" ;;
        Linux) host="linux-x86_64" ;;
        *) echo -e "${RED}Unsupported host OS for NDK build${NC}" >&2; return 1 ;;
    esac
    echo "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host"
}

copy_android_core() {
    local abi="$1"
    local src="$FCEUMM_DIR/fceumm_libretro.so"
    if [ ! -f "$src" ]; then
        echo -e "${RED}Build output not found: $src${NC}" >&2
        return 1
    fi

    mkdir -p "$JNI_LIBS_DIR/$abi"
    cp "$src" "$JNI_LIBS_DIR/$abi/libfceumm_libretro.so"
    echo -e "${GREEN}Android $abi: libfceumm_libretro.so${NC}"
}

build_android_abi() {
    local abi="$1"
    local clang_target="$2"

    local prebuilt
    prebuilt="$(ndk_prebuilt_dir)" || return 1
    local toolchain_bin="$prebuilt/bin"
    local jobs
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

    echo -e "${YELLOW}Building FCEUmm for $abi ($clang_target)...${NC}"

    make -C "$FCEUMM_DIR" -f Makefile.libretro platform=unix clean >/dev/null 2>&1 || true
    make -C "$FCEUMM_DIR" -f Makefile.libretro platform=unix -j"$jobs" \
        CC="$toolchain_bin/${clang_target}-clang" \
        AR="$toolchain_bin/llvm-ar" \
        LDFLAGS='-lm -Wl,-z,max-page-size=16384'

    copy_android_core "$abi"
}

build_android() {
    if ! resolve_android_ndk_home; then
        return 1
    fi

    echo -e "${GREEN}Using NDK: $ANDROID_NDK_HOME${NC}"

    build_android_abi "arm64-v8a" "aarch64-linux-android24"
}

build_ios() {
    echo -e "${GREEN}Building FCEUmm for iOS...${NC}"
    make -C "$FCEUMM_DIR" -f Makefile.libretro platform=ios-arm64 clean >/dev/null 2>&1 || true
    make -C "$FCEUMM_DIR" -f Makefile.libretro platform=ios-arm64 -j"$(sysctl -n hw.ncpu)"
    mkdir -p "$IOS_FRAMEWORKS_DIR"
    cp "$FCEUMM_DIR/fceumm_libretro_ios.dylib" "$IOS_FRAMEWORKS_DIR/fceumm_libretro_ios.dylib"
    echo -e "${GREEN}iOS: $IOS_FRAMEWORKS_DIR/fceumm_libretro_ios.dylib${NC}"
}

build_macos() {
    echo -e "${GREEN}Building FCEUmm for macOS...${NC}"
    make -C "$FCEUMM_DIR" -f Makefile.libretro platform=osx clean >/dev/null 2>&1 || true
    make -C "$FCEUMM_DIR" -f Makefile.libretro platform=osx -j"$(sysctl -n hw.ncpu)"
    local macos_dir="$BUILD_DIR/macos"
    mkdir -p "$macos_dir"
    cp "$FCEUMM_DIR/fceumm_libretro.dylib" "$macos_dir/fceumm_libretro.dylib"
    echo -e "${GREEN}macOS: $macos_dir/fceumm_libretro.dylib${NC}"
}

PLATFORM="${1:-android}"

case "$PLATFORM" in
    ios) build_ios ;;
    macos|osx) build_macos ;;
    android) build_android ;;
    all)
        build_macos || true
        build_ios || true
        build_android || true
        ;;
    *)
        echo "Usage: $0 [android|ios|macos|all]"
        exit 1
        ;;
esac

echo -e "${GREEN}FCEUmm build done.${NC}"
