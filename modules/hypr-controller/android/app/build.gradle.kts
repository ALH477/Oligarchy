// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025-2026, Asher LeRoy
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "ltd.demod.hyprcontroller"
    // Pinned to 34 to match what this repo actually provides: configuration.nix
    // installs androidenv platform 34 + build-tools 34.0.0, and AGP 8.6.0 (see
    // the root build.gradle.kts) tops out near API 35 anyway. Raising this means
    // moving all three together — bump platformVersions/buildToolsVersions in
    // configuration.nix AND the AGP version — not just this line.
    compileSdk = 34

    defaultConfig {
        applicationId = "ltd.demod.hyprcontroller"
        minSdk = 26 // Oreo+: notification channels for the foreground service, no desugaring needed
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

        // Build-embedded Ed25519 private key for pairing-auth.
        // Injected by build-all.sh as a Gradle project property; empty string disables auth.
        val hyprPrivKey = project.findProperty("HYPR_PRIV_KEY") as? String ?: ""
        buildConfigField("String", "HYPR_CONTROLLER_PRIVATE_KEY",
            "\"${hyprPrivKey.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.04.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.navigation:navigation-compose:2.9.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
