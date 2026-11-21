buildscript {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    dependencies {
        // Match the cached Kotlin toolchain used by the isolated preview.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
        classpath("com.google.errorprone:error_prone_annotations:2.36.0")
    }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

check(gradle.startParameter.isOffline) { "Qualification requires --offline." }
check(!hasProperty("target") && !hasProperty("dart-defines")) {
    "Qualification has a fixed entry point and does not accept Dart defines."
}

layout.buildDirectory.set(file("../../build/journal-qualification"))

repositories {
    google()
    mavenCentral()
}

val flutterSdk = checkNotNull(System.getenv("FLUTTER_ROOT"))
val engineRevision = file("$flutterSdk/bin/cache/engine.stamp").readText().trim()
dependencies {
    implementation("io.flutter:flutter_embedding_release:1.0.0-$engineRevision")
}

kotlin.sourceSets.named("main") {
    kotlin.srcDir("../app/src/main/kotlin")
    kotlin.include(
        "com/example/velora/AndroidSqliteJournalPlugin.kt",
        "com/example/velora/journalqualification/JournalQualificationActivity.kt",
    )
}

android {
    namespace = "com.example.velora.journalqualification"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.velora.journalqualification"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 1
        versionName = "1.0-qualification"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
}

androidComponents {
    beforeVariants(selector().all()) { variant ->
        variant.enable = variant.buildType == "release"
    }
}

flutter {
    source = "../.."
    target = "lib/journal_qualification/main.dart"
}
