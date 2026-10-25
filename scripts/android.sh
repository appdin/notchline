#!/bin/sh
# Builds NotchlineCore for Android, runs its tests on a device and assembles the debug APK.
#
# Usage:
#   scripts/android.sh core <jniLibs-dir>  build libNotchlineJNI.so (Swift runtime linked
#                                          statically) and libc++_shared.so into <dir>/arm64-v8a
#   scripts/android.sh test                build the core's tests and run them on the connected
#                                          device or emulator
#   scripts/android.sh apk                 assemble the debug APK (runs `core` through Gradle)
#
# Needs swiftly with the toolchain in android/swift/.swift-version, the matching Swift SDK for
# Android, and NDK r30. ANDROID_HOME defaults to ~/Library/Android/sdk and ANDROID_NDK_HOME to
# NDK r30 inside it.
set -eu
cd "$(dirname "$0")/.."
root="$PWD"

swift_version="$(cat android/swift/.swift-version)"
swift_sdk="swift-$swift_version-RELEASE_android"
triple="aarch64-unknown-linux-android28"
abi="arm64-v8a"
ndk_version="30.0.16248370"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$ndk_version}"
swiftly="${SWIFTLY:-$HOME/.swiftly/bin/swiftly}"
adb="$ANDROID_HOME/platform-tools/adb"
libcxx="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so)"

swift_build() {
    (cd android/swift && "$swiftly" run swift build --swift-sdk "$swift_sdk" --triple "$triple" "$@")
}

case "${1:-}" in
core)
    out="${2:?usage: scripts/android.sh core <jniLibs-dir>}"
    swift_build -c release --static-swift-stdlib --product NotchlineJNI
    mkdir -p "$out/$abi"
    cp android/swift/.build/release/libNotchlineJNI.so "$libcxx" "$out/$abi/"
    ;;
test)
    # Swift Testing ships in the SDK only as shared libraries, so the tests link the runtime
    # dynamically and every runtime library is pushed beside the runner. Only the test product is
    # built: a debug NotchlineJNI would look for the static TLS libraries among the shared ones.
    swift_build --product NotchlineAndroidPackageTests
    bin=android/swift/.build/debug
    sdks="$HOME/Library/org.swift.swiftpm/swift-sdks"
    [ -d "$sdks" ] || sdks="$HOME/.swiftpm/swift-sdks"
    runtime="$sdks/$swift_sdk.artifactbundle/swift-android/swift-resources/usr/lib/swift-aarch64/android"
    dir=/data/local/tmp/notchline-tests
    "$adb" shell "rm -rf $dir && mkdir -p $dir"
    "$adb" push -q "$bin/NotchlineTests-test-runner" "$bin/NotchlineTests.so" "$bin"/*.bundle "$runtime"/*.so "$libcxx" "$dir/"
    "$adb" shell "cd $dir && LD_LIBRARY_PATH=. ./NotchlineTests-test-runner --testing-library swift-testing"
    ;;
apk)
    cd android && ./gradlew assembleDebug
    echo "$root/android/app/build/outputs/apk/debug/app-debug.apk"
    ;;
*)
    sed -n '2,13p' "$0"
    exit 2
    ;;
esac
