import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Yayın imzası: `android/key.properties` varsa (bkz. key.properties.example)
// release derlemesi o anahtarla imzalanır. Dosya yoksa (geliştirici makinesi,
// `flutter run --release`) debug anahtarına düşülür — böyle bir APK mağazaya
// yüklenemez ve her makinede farklı imzalandığı için cihazda güncelleme olarak
// kurulamaz; dağıtım derlemeleri mutlaka gerçek anahtarla üretilmelidir.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "tr.com.pazarlik.kaydet"
    // permission_handler_android SDK 37'ye karşı derlenmiş; Flutter'ın
    // varsayılanı (flutter.compileSdkVersion, şu an 36) yetersiz kalıyor.
    // SDK'lar geriye dönük uyumlu, minSdk/targetSdk bundan etkilenmez.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications, eski Android sürümlerinde java.time
        // API'lerini kullanabilmek için core library desugaring ister.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "tr.com.pazarlik.kaydet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    testOptions {
        unitTests.all {
            // Robolectric, yerel kütüphane adını `os.name.toLowerCase()` ile kurar;
            // Türkçe yerelde "windows" → "wındows" (noktasız ı) olur ve
            // `conscrypt_openjdk_jni-wındows-x86_64` bulunamaz.
            it.jvmArgs("-Duser.language=en", "-Duser.country=US")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // Paylaşım gelen kutusu (bkz. ShareInbox.kt, ShareFileName.kt) JVM'de
    // sınanır. `org.json`, Android'de framework'ten gelir; birim testlerinde
    // ise gerçek uygulaması gerekir (framework'ün "stub"ı hep boş döner).
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    // ShareIntake'in (ContentResolver → dosya kopyalama) cihazsız sınanması için.
    testImplementation("org.robolectric:robolectric:4.16")
}

flutter {
    source = "../.."
}
