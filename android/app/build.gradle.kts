plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.meshscout.mesh_scout"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.meshscout.mesh_scout"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("production") {
            System.getenv("MESHSCOUT_RELEASE_KEYSTORE_PATH")?.let { path ->
                storeFile = file(path)
                storeType = "PKCS12"
                storePassword = System.getenv("MESHSCOUT_RELEASE_STORE_PASSWORD")
                keyAlias = System.getenv("MESHSCOUT_RELEASE_KEY_ALIAS")
                keyPassword = System.getenv("MESHSCOUT_RELEASE_KEY_PASSWORD")
            }
        }
        getByName("debug") {
            // CI supplies private test signing from encrypted repository secrets.
            // A stable signer lets later APK updates retain saved GPS sessions.
            System.getenv("MESHSCOUT_TEST_KEYSTORE_PATH")?.let { path ->
                storeFile = file(path)
                storeType = "PKCS12"
                storePassword = System.getenv("MESHSCOUT_TEST_KEYSTORE_PASSWORD")
                keyAlias = "androiddebugkey"
                keyPassword = System.getenv("MESHSCOUT_TEST_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Release builds require owner-controlled production secrets.
            // Candidate builds explicitly opt into the existing test signer.
            signingConfig = signingConfigs.getByName(
                if (System.getenv("MESHSCOUT_CANDIDATE") == "true") "debug" else "production"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

// Fail closed rather than producing an unsigned or accidentally test-signed release.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release") } &&
        System.getenv("MESHSCOUT_CANDIDATE") != "true") {
        listOf("MESHSCOUT_RELEASE_KEYSTORE_PATH", "MESHSCOUT_RELEASE_STORE_PASSWORD",
            "MESHSCOUT_RELEASE_KEY_ALIAS", "MESHSCOUT_RELEASE_KEY_PASSWORD").forEach {
            require(!System.getenv(it).isNullOrBlank()) { "Production signing configuration is required: $it" }
        }
    }
}
