plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repoRoot = rootDir.parentFile
val jniLibsDir = layout.buildDirectory.dir("generated/notchlineCore/jniLibs")
val assetsDir = layout.buildDirectory.dir("generated/notchlineCore/assets")

android {
    namespace = "com.appdin.notchline"
    compileSdk = 37
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "com.appdin.notchline"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
    }

    // The release keystore stays out of the repo. Without these variables the release APK is left
    // unsigned, and `scripts/android.sh release` refuses to build it.
    val keystore = System.getenv("NOTCHLINE_KEYSTORE")
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("NOTCHLINE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("NOTCHLINE_KEY_ALIAS")
                keyPassword = System.getenv("NOTCHLINE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (keystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    // Compressed native libraries take the APK from 82 to about 47 MB, mostly ICU data in the core,
    // at the cost of Android extracting them on install.
    packaging { jniLibs.useLegacyPackaging = true }

    buildFeatures { compose = true }

    sourceSets["main"].jniLibs.directories += jniLibsDir.get().asFile.path
    sourceSets["main"].assets.directories += assetsDir.get().asFile.path
}

// The Swift core, built by scripts/android.sh with the Swift SDK for Android.
val buildNotchlineCore = tasks.register<Exec>("buildNotchlineCore") {
    inputs.dir(repoRoot.resolve("Sources/NotchlineCore"))
    inputs.dir(rootDir.resolve("swift/Sources"))
    inputs.file(rootDir.resolve("swift/Package.swift"))
    outputs.dir(jniLibsDir)
    val ndk = androidComponents.sdkComponents.ndkDirectory
    doFirst { environment("ANDROID_NDK_HOME", ndk.get().asFile.path) }
    commandLine(repoRoot.resolve("scripts/android.sh").path, "core", jniLibsDir.get().asFile.path)
}

// The location catalog and confidence table, passed to the core at startup since an app process can't use Bundle.module.
val copyNotchlineAssets = tasks.register<Copy>("copyNotchlineAssets") {
    from(repoRoot.resolve("Sources/NotchlineCore/Resources/locations.json"), repoRoot.resolve("Sources/NotchlineCore/Resources/confidence.json"))
    into(assetsDir)
}

tasks.named("preBuild") { dependsOn(buildNotchlineCore, copyNotchlineAssets) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.10.0")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("androidx.glance:glance-appwidget:1.2.0")
}
