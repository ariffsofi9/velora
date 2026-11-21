pluginManagement {
    val flutterSdk = System.getenv("FLUTTER_ROOT")
        ?: error("Set FLUTTER_ROOT to the installed Flutter SDK.")
    includeBuild("$flutterSdk/packages/flutter_tools/gradle")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "8.11.1" apply false
}

// No Flutter plugin loader or production Android project in this build.
rootProject.name = "velora-offline-preview"
