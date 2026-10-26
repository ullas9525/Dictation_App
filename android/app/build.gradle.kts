import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.dictation_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.0.13004108"

    externalNativeBuild {
        cmake {
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // Unique application ID — change before publishing.
        applicationId = "com.example.dictation_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (rootProject.file("key.properties").exists()) {
            val properties = Properties().also {
                it.load(FileInputStream(rootProject.file("key.properties")))
            }
            create("release") {
                storeFile = rootProject.file(properties.getProperty("storeFile", ""))
                storePassword = properties.getProperty("storePassword", "")
                keyAlias = properties.getProperty("keyAlias", "")
                keyPassword = properties.getProperty("keyPassword", "")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
        debug {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // Require key.properties for release builds only (evaluated when assembling,
    // not at configuration time, so debug builds keep working without it).
    tasks.findByName("assembleRelease")?.let { task ->
        task.doFirst {
            if (!rootProject.file("key.properties").exists()) {
                throw GradleException(
                    "Release signing credentials not found. Create android/key.properties " +
                    "with storeFile, storePassword, keyAlias, and keyPassword before building a release.",
                )
            }
        }
    }
}

flutter {
    source = "../.."
}
