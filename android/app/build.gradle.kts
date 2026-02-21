import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keystore configuration priority:
// 1. Environment variables (for CI/CD: GitHub Actions, etc.)
// 2. key.properties file (for local development)
// 3. Debug keystore fallback (for development without release keystore)

val useEnvVars = System.getenv("ANDROID_KEYSTORE_PATH") != null
val isCiBuild = System.getenv("CI")?.equals("true", ignoreCase = true) == true
val enableR8ForRelease =
    (project.findProperty("enableR8") as String?)?.toBooleanStrictOrNull() ?: isCiBuild

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (!useEnvVars && keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "dev.chuk.chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.chuk.chat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (useEnvVars) {
                // CI/CD: Use environment variables
                storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH")!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")!!
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")!!
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")!!
            } else if (keystorePropertiesFile.exists()) {
                // Local development: Use key.properties
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
            }
        }
    }

    buildTypes {
        release {
            // R8: Code shrinking, optimization, resource shrinking (NO obfuscation)
            // Local default: disabled for faster release builds.
            // CI default: enabled. Override with -PenableR8=true/false.
            isMinifyEnabled = enableR8ForRelease
            isShrinkResources = enableR8ForRelease
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            signingConfig = if (useEnvVars || keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Fallback to debug signing if no keystore configured
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
