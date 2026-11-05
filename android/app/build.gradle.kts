import java.util.Base64

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep existing unflavored emulator commands unchanged. Only explicit staging
// tasks/defines expose the staging flavor; aggregate ordinary builds exclude it.
val veloraDartDefines = (project.findProperty("dart-defines") as String?)
    ?.split(",")?.filter { it.isNotBlank() }?.map {
        String(Base64.getDecoder().decode(it), Charsets.UTF_8)
    }.orEmpty()
val stagingProfile = veloraDartDefines.contains("VELORA_STAGING=true")
val stagingTask = gradle.startParameter.taskNames.any { it.contains("staging", ignoreCase = true) }
val stagingSelected = stagingProfile || stagingTask
val cloudProjectDefines = veloraDartDefines.filter { it.substringBefore("=") == "VELORA_FIREBASE_PROJECT" }
if (cloudProjectDefines.isNotEmpty()) {
    val conflicting = setOf("VELORA_STAGING", "USE_FIREBASE_EMULATORS", "FIREBASE_EMULATOR_HOST", "STAFF_DEMO", "AI1_MOCK_RECIPES", "RECIPE_CONNECTIVITY_DEMO", "AI1_LIVE_RECIPES")
    if (cloudProjectDefines != listOf("VELORA_FIREBASE_PROJECT=velora-73222") || stagingSelected ||
        veloraDartDefines.any { it.substringBefore("=") in conflicting }) {
        throw GradleException("Explicit Android cloud profile is invalid or conflicts with another profile.")
    }
    val cloudConfig = groovy.json.JsonSlurper().parse(file("google-services.json")) as? Map<*, *>
    val cloudInfo = cloudConfig?.get("project_info") as? Map<*, *>
    val cloudClient = (cloudConfig?.get("client") as? List<*>)?.singleOrNull() as? Map<*, *>
    val cloudClientInfo = cloudClient?.get("client_info") as? Map<*, *>
    val cloudAndroid = cloudClientInfo?.get("android_client_info") as? Map<*, *>
    if (cloudInfo?.get("project_id") != "velora-73222" ||
        cloudInfo?.get("project_number") != "384873169563" ||
        cloudClientInfo?.get("mobilesdk_app_id") != "1:384873169563:android:d83c95f3e2134983b63c3e" ||
        cloudAndroid?.get("package_name") != "com.example.velora") {
        throw GradleException("Android Google Services identity does not match the approved project/app/package.")
    }
}
if (stagingSelected) {
    if (!stagingProfile || !stagingTask) {
        throw GradleException("Android staging BLOCKED: --flavor staging and VELORA_STAGING=true must be selected together.")
    }
    val forbidden = setOf("USE_FIREBASE_EMULATORS", "FIREBASE_EMULATOR_HOST", "STAFF_DEMO", "AI1_MOCK_RECIPES", "RECIPE_CONNECTIVITY_DEMO", "AI1_LIVE_RECIPES")
    if (veloraDartDefines.any { it.substringBefore("=") in forbidden }) {
        throw GradleException("Android staging BLOCKED: conflicting emulator/demo/live-AI defines.")
    }
    // No Google Services search/fallback is allowed until this exact source file
    // exists and matches. Never read/copy the root legacy configuration here.
    val stagingJson = file("src/staging/google-services.json")
    if (!stagingJson.isFile) {
        throw GradleException("Android staging BLOCKED: missing src/staging/google-services.json; legacy fallback forbidden.")
    }
    val config = groovy.json.JsonSlurper().parse(stagingJson) as? Map<*, *>
    val info = config?.get("project_info") as? Map<*, *>
    val clients = config?.get("client") as? List<*>
    val client = clients?.singleOrNull() as? Map<*, *>
    val clientInfo = client?.get("client_info") as? Map<*, *>
    val androidInfo = clientInfo?.get("android_client_info") as? Map<*, *>
    val sender = info?.get("project_number") as? String
    val appId = clientInfo?.get("mobilesdk_app_id") as? String
    val keys = client?.get("api_key") as? List<*>
    val key = (keys?.singleOrNull() as? Map<*, *>)?.get("current_key") as? String
    if (info?.get("project_id") != "velora-fyp-staging" ||
        androidInfo?.get("package_name") != "com.example.velora.staging" ||
        sender == null || !sender.matches(Regex("[0-9]+")) ||
        appId == null || !appId.startsWith("1:$sender:android:") || appId.substringAfterLast(":").isBlank() || key.isNullOrBlank()) {
        throw GradleException("Android staging BLOCKED: native staging configuration is incomplete or mismatched.")
    }
    // Registration alone does not approve startup or prove merged resources.
    throw GradleException("Android staging BLOCKED: registration/configuration review and native verification require separate approval.")
}

android {
    namespace = "com.example.velora"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.velora"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (stagingSelected) {
        flavorDimensions += "environment"
        productFlavors {
            create("staging") {
                dimension = "environment"
                applicationId = "com.example.velora.staging"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

androidComponents {
    onVariants(selector().all()) { variant ->
        if (cloudProjectDefines.isNotEmpty() && variant.applicationId.get() != "com.example.velora") {
            throw GradleException("Explicit cloud profile requires package com.example.velora.")
        }
    }
}
