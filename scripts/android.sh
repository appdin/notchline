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
#   scripts/android.sh keystore            create the release keystore
#   scripts/android.sh release             assemble the signed release APK as
#                                          build/Notchline-<version>.apk and print its SHA-256
#
# The release keystore lives outside the repo, at NOTCHLINE_KEYSTORE (default
# ~/Documents/android_keys/notchline.keystore) under the alias NOTCHLINE_KEY_ALIAS (default
# notchline). `release` reads the password from NOTCHLINE_KEYSTORE_PASSWORD, or else from the
# Keychain item stored with `security add-generic-password -a notchline -s notchline-keystore -w`.
# The key password NOTCHLINE_KEY_PASSWORD defaults to the keystore password.
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
keystore="${NOTCHLINE_KEYSTORE:-$HOME/Documents/android_keys/notchline.keystore}"
key_alias="${NOTCHLINE_KEY_ALIAS:-notchline}"
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
    [ ! -e "$keystore" ] || { echo "$keystore already exists" >&2; exit 1; }
    mkdir -p "$(dirname "$keystore")"
    # Every update has to be signed with this key, so back it up. A lost key means users
    # uninstall and reinstall to update.
    keytool -genkeypair -keystore "$keystore" -alias "$key_alias" -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=appdin"
    ;;
release)
    case "$keystore" in /*) ;; *) echo "NOTCHLINE_KEYSTORE must be an absolute path." >&2; exit 1 ;; esac
    [ -f "$keystore" ] || { echo "No keystore at $keystore. Run $0 keystore." >&2; exit 1; }
    export NOTCHLINE_KEYSTORE="$keystore" NOTCHLINE_KEY_ALIAS="$key_alias"
    # The passwords only live in this process's environment, never in a file or the shell history.
    if [ -z "${NOTCHLINE_KEYSTORE_PASSWORD:-}" ]; then
        NOTCHLINE_KEYSTORE_PASSWORD="$(security find-generic-password -a notchline -s notchline-keystore -w)" || {
            echo "No keystore password in the Keychain. Add it with" >&2
            echo "  security add-generic-password -a notchline -s notchline-keystore -w" >&2
            exit 1
        }
    fi
    # keytool's PKCS12 keystores use one password for the store and the key.
    export NOTCHLINE_KEYSTORE_PASSWORD
    export NOTCHLINE_KEY_PASSWORD="${NOTCHLINE_KEY_PASSWORD:-$NOTCHLINE_KEYSTORE_PASSWORD}"
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
    sed -n '2,23p' "$0"
    exit 2
    ;;
esac
