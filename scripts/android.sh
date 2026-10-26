#!/bin/sh
# Builds NotchlineCore for Android, runs its tests on a device and assembles the debug and release
# APKs.
#
# Usage:
#   scripts/android.sh core <jniLibs-dir>  build libNotchlineJNI.so (Swift runtime linked
#                                          statically) and libc++_shared.so into <dir>/arm64-v8a
#   scripts/android.sh test                build the core's tests and run them on the connected
#                                          device or emulator
#   scripts/android.sh apk                 assemble the debug APK (runs `core` through Gradle)
#   scripts/android.sh keystore            create the release keystore at $NOTCHLINE_KEYSTORE
#   scripts/android.sh release             assemble the signed release APK as
#                                          build/Notchline-<version>.apk and print its SHA-256
#
# The release keystore lives outside the repo. `keystore` and `release` read its path from
# NOTCHLINE_KEYSTORE and its alias from NOTCHLINE_KEY_ALIAS; `release` also needs
# NOTCHLINE_KEYSTORE_PASSWORD and NOTCHLINE_KEY_PASSWORD.
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
build_tools="$ANDROID_HOME/build-tools/36.0.0"
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
keystore)
    keystore="${NOTCHLINE_KEYSTORE:?set NOTCHLINE_KEYSTORE to the keystore path, outside the repo}"
    alias="${NOTCHLINE_KEY_ALIAS:?set NOTCHLINE_KEY_ALIAS}"
    [ ! -e "$keystore" ] || { echo "$keystore already exists" >&2; exit 1; }
    # Every update has to be signed with this key, so back it up. A lost key means users
    # uninstall and reinstall to update.
    keytool -genkeypair -keystore "$keystore" -alias "$alias" -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=appdin"
    ;;
release)
    for var in NOTCHLINE_KEYSTORE NOTCHLINE_KEYSTORE_PASSWORD NOTCHLINE_KEY_ALIAS NOTCHLINE_KEY_PASSWORD; do
        eval "[ -n \"\${$var:-}\" ]" || { echo "$var is not set. See the top of $0." >&2; exit 1; }
    done
    case "$NOTCHLINE_KEYSTORE" in /*) ;; *) echo "NOTCHLINE_KEYSTORE must be an absolute path." >&2; exit 1 ;; esac
    [ -f "$NOTCHLINE_KEYSTORE" ] || { echo "No keystore at $NOTCHLINE_KEYSTORE. Run $0 keystore." >&2; exit 1; }
    (cd android && ./gradlew assembleRelease)
    version="$(sed -n 's/.*versionName = "\(.*\)"/\1/p' android/app/build.gradle.kts)"
    apk="$root/build/Notchline-$version.apk"
    mkdir -p build
    cp android/app/build/outputs/apk/release/app-release.apk "$apk"
    "$build_tools/apksigner" verify "$apk"
    echo "$apk"
    shasum -a 256 "$apk"
    ;;
*)
    sed -n '2,21p' "$0"
    exit 2
    ;;
esac
