pluginManagement {
    val flutterSdk = System.getenv("FLUTTER_ROOT") ?: error("Set FLUTTER_ROOT to the installed SDK.")
    includeBuild("$flutterSdk/packages/flutter_tools/gradle")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

// Standalone build. No Flutter plugin loader or production Android app.
rootProject.name = "velora-journal-diagnostic"
