plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.crosswalk_app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.crosswalk_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Release builds must not be silently debug-signed outside CI.
            // GitHub Actions sets GITHUB_ACTIONS=true on every run (documented default env var:
            // https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables).
            // CI debug-signs here, then `.github/workflows/build_apk.yml`'s "APK 서명" step
            // re-signs the artifact with the real release key afterward.
            // For local testing only, pass -PallowDebugSigningForRelease=true to accept the risk.
            val isCi = System.getenv("GITHUB_ACTIONS") == "true"
            val allowDebugSigningForRelease = project.hasProperty("allowDebugSigningForRelease")
            if (isCi || allowDebugSigningForRelease) {
                // TODO: Add your own signing config for the release build.
                // Signing with the debug keys for now, so `flutter run --release` works.
                signingConfig = signingConfigs.getByName("debug")
            } else {
                throw GradleException(
                    "Refusing to build a release APK signed with the debug keystore. " +
                        "This is not a valid release signature and must not be distributed. " +
                        "Run this build via CI (which re-signs the artifact with the real key " +
                        "afterward), or pass -PallowDebugSigningForRelease=true if you understand " +
                        "and accept a debug-signed build for local testing only."
                )
            }
        }
    }
}

flutter {
    source = "../.."
}
