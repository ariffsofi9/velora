buildscript {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    dependencies {
        // Align Flutter's build-time Kotlin dependency with the existing
        // Android toolchain. No Kotlin plugin is applied to the preview app.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
        classpath("com.google.errorprone:error_prone_annotations:2.36.0")
    }
}

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

check(gradle.startParameter.isOffline) { "The preview build requires --offline." }
check(!hasProperty("target") && !hasProperty("dart-defines")) {
    "The preview entry point is fixed and does not accept Dart defines."
}

layout.buildDirectory.set(file("../../build/offline-preview"))

repositories {
    google()
    mavenCentral()
}

// Flutter normally receives the embedding through Android plugin projects.
// This build excludes those projects and links the installed engine directly.
val flutterSdk = checkNotNull(System.getenv("FLUTTER_ROOT"))
val engineRevision = file("$flutterSdk/bin/cache/engine.stamp").readText().trim()
dependencies {
    implementation("io.flutter:flutter_embedding_release:1.0.0-$engineRevision")
}

android {
    namespace = "com.example.velora.offlinepreview"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.velora.offlinepreview"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 1
        versionName = "1.0-preview"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            // Local device preview, using the workstation's Android debug key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

androidComponents {
    beforeVariants(selector().all()) { variant ->
        variant.enable = variant.buildType == "release"
    }
}

flutter {
    source = "../.."
    target = "lib/offline_preview/main.dart"
}
