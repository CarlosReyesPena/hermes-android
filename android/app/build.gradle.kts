import java.io.FileInputStream
import java.util.Properties

plugins {
   id("com.android.application")
   id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePath = rootProject.projectDir.parentFile.resolve("key.properties")
val minimumInstalledVersionCode = 2127
if (keystorePath.exists()) {
   keystoreProperties.load(FileInputStream(keystorePath))
}

android {
   namespace = "com.hermesagent.hermes_android"
   compileSdk = 36

   compileOptions {
       sourceCompatibility = JavaVersion.VERSION_17
       targetCompatibility = JavaVersion.VERSION_17
       isCoreLibraryDesugaringEnabled = true
   }

   defaultConfig {
       check(flutter.versionCode > minimumInstalledVersionCode) {
           "versionCode ${flutter.versionCode} must be greater than " +
               "$minimumInstalledVersionCode to upgrade the accepted Hermes APK"
       }
       applicationId = "com.hermesagent.hermes_android"
       minSdk = 24
       targetSdk = 36
       versionCode = flutter.versionCode
       versionName = flutter.versionName
       manifestPlaceholders["appLabel"] = "Hermes Agent"
   }

   signingConfigs {
       create("release") {
           if (keystoreProperties.containsKey("storeFile")) {
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
           }
       }
   }

   buildTypes {
       debug {
           // The guarded Flutter versionCode is the base. `--split-per-abi`
           // adds 2000 to the packaged arm64 code; CI verifies both values.
           applicationIdSuffix = ".dev"
           versionNameSuffix = "-dev"
           manifestPlaceholders["appLabel"] = "Hermes Agent Dev"
       }
       release {
           // CI/local analysis may build a release artifact without access to
           // the private distribution keystore. Never fall back to the debug
           // key: leave the APK explicitly unsigned until the real
           // key.properties file is supplied.
           if (keystorePath.exists()) {
               signingConfig = signingConfigs.getByName("release")
           }
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
   coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
