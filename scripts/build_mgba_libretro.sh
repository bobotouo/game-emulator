#!/bin/bash

# Build mGBA libretro core for mobile (iOS & Android)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build/libretro"
OUTPUT_DIR="$PROJECT_DIR/assets/cores"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Building mGBA libretro core for mobile...${NC}"

# Check cmake
if ! command -v cmake &> /dev/null; then
    echo -e "${RED}cmake not found. Install it first:${NC}"
    echo "  brew install cmake"
    exit 1
fi

# Clone mGBA if not exists
MGBA_DIR="$BUILD_DIR/mgba"
if [ ! -d "$MGBA_DIR" ]; then
    echo -e "${YELLOW}Cloning mGBA repository...${NC}"
    mkdir -p "$BUILD_DIR"
    git clone --depth 1 --recurse-submodules https://github.com/mgba-emu/mgba.git "$MGBA_DIR"
fi

mkdir -p "$OUTPUT_DIR"

# Read ndkVersion from the Flutter SDK used by this project (matches flutter.ndkVersion)
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
    if [ -n "$ANDROID_NDK_HOME" ] && [ -f "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" ]; then
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
    if [ ! -f "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" ]; then
        echo -e "${RED}Flutter NDK $version not found at $ANDROID_NDK_HOME${NC}" >&2
        echo "Install it in Android Studio: SDK Manager → SDK Tools → NDK (Side by side) → $version" >&2
        return 1
    fi
    export ANDROID_NDK_HOME
}

# Build for iOS
build_ios() {
    echo -e "${GREEN}Building for iOS...${NC}"
    local BUILD_IOS="$BUILD_DIR/ios"
    mkdir -p "$BUILD_IOS"
    cd "$BUILD_IOS"

    cmake "$MGBA_DIR" \
        -DBUILD_LIBRETRO=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DBUILD_QT=OFF \
        -DBUILD_SDL=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_STATIC=ON

    make -j$(sysctl -n hw.ncpu)

    cp "$BUILD_IOS/mgba_libretro.dylib" "$OUTPUT_DIR/mgba_libretro_ios.dylib"
    echo -e "${GREEN}iOS build complete: $OUTPUT_DIR/mgba_libretro_ios.dylib${NC}"
}

# Build for Android
build_android() {
    if ! resolve_android_ndk_home; then
        echo -e "${RED}Android NDK not found.${NC}"
        echo "Install NDK in Android Studio (SDK Manager → NDK), or set:"
        echo "  export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/<version>"
        return 1
    fi

    echo -e "${GREEN}Using Flutter NDK $(basename "$ANDROID_NDK_HOME"): $ANDROID_NDK_HOME${NC}"
    echo -e "${GREEN}Building for Android...${NC}"
    local BUILD_ANDROID="$BUILD_DIR/android"
    mkdir -p "$BUILD_ANDROID"

    for ABI in armeabi-v7a arm64-v8a x86_64; do
        echo -e "${YELLOW}Building for Android $ABI...${NC}"
        local BUILD_ABI="$BUILD_ANDROID/$ABI"
        mkdir -p "$BUILD_ABI"
        cd "$BUILD_ABI"

        cmake "$MGBA_DIR" \
            -DBUILD_LIBRETRO=ON \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI="$ABI" \
            -DANDROID_PLATFORM=android-24 \
            -DBUILD_QT=OFF \
            -DBUILD_SDL=OFF \
            -DBUILD_TESTING=OFF

        make -j$(sysctl -n hw.ncpu)

        mkdir -p "$OUTPUT_DIR/android/$ABI"
        cp "$BUILD_ABI/mgba_libretro.so" "$OUTPUT_DIR/android/$ABI/libmgba_libretro.so"
        echo -e "${GREEN}Android $ABI build complete${NC}"
    done
}

# Parse args
PLATFORM="${1:-all}"

case "$PLATFORM" in
    ios) build_ios ;;
    android) build_android ;;
    all)
        build_ios
        if resolve_android_ndk_home; then
            build_android
        else
            echo -e "${YELLOW}Skipping Android (NDK not found)${NC}"
        fi
        ;;
    *)
        echo "Usage: $0 [ios|android|all]"
        exit 1
        ;;
esac

echo -e "${GREEN}Done!${NC}"
