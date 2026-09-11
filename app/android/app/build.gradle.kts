plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firebase (push notifications) is optional: the plugin is applied only when
// android/app/google-services.json is present. Without the file the build is
// unchanged and the app runs with push off (Firebase.initializeApp() fails
// and services/notifications/push_service.dart treats that as "no push").
// To turn push on: drop google-services.json from the Firebase console into
// android/app/ — nothing else changes.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "dev.chuk.cowork"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications pulls in APIs (java.time, etc.) that need
        // core library desugaring on the minSdk we ship. Without this the AAR
        // metadata check fails the build outright.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.chuk.cowork"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Keep APKs to the ABIs Flutter was asked for. Flutter's
        // --target-platform limits the Dart/engine output, but transitive
        // Android libraries may still ship their prebuilt binaries for every
        // ABI unless Gradle filters them. The phone is arm64 and the local
        // emulator is x86_64, so follow the request instead of pinning one ABI.
        val abiForTarget = mapOf(
            "android-arm" to "armeabi-v7a",
            "android-arm64" to "arm64-v8a",
            "android-x64" to "x86_64",
        )
        val requestedAbis = (project.findProperty("target-platform") as String?)
            ?.split(",")
            ?.mapNotNull { abiForTarget[it.trim()] }
            ?.takeIf { it.isNotEmpty() }
            ?: listOf("arm64-v8a")
        ndk {
            abiFilters += requestedAbis
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
