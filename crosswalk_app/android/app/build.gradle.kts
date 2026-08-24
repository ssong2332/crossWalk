plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.ssong2332.walkguide"
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
        // T59: `com.example.*`는 Play 스토어가 거부한다. 보유 도메인이 없으므로
        // GitHub 계정 기반 역DNS를 쓴다 (io.github.<user>는 개인 개발자 표준 관행).
        // 이름을 `crosswalk`가 아니라 `walkguide`로 잡은 이유: 제품 범위가
        // 횡단보도 이탈 감지에서 시각장애인 보행 안내 전반으로 확장될 예정이라,
        // 영구 불변인 식별자에 한 기능 이름을 박으면 안 된다 (2026-08-24 사용자 확정).
        // **출시 후 변경 불가** — 바꾸려면 새 앱으로 등록해야 하고 기존 사용자는
        // 업데이트를 받지 못한다.
        applicationId = "io.github.ssong2332.walkguide"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
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
