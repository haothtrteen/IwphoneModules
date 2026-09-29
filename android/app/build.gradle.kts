import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 从 key.properties 读取 release 签名配置。
// 该文件不入库；缺失时自动回退到 debug 签名，保证本地构建不中断。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasSigningConfig = keystorePropertiesFile.exists()
if (hasSigningConfig) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.shellmgr.shell_manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.shellmgr.shell_manager"
        // You can update the following values to match your application needs.
        // For more information on the Flutter Gradle Plugin, see:
        // https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasSigningConfig) {
            create("release") {
                storeFile = rootProject.file("app/" + keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasSigningConfig) {
                signingConfigs.getByName("release")
            } else {
                // 未配置签名时使用 debug 密钥，仅用于本地验证
                signingConfigs.getByName("debug")
            }
            // 体积与启动速度优化
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packaging {
        jniLibs {
            // ★ 必须为 true（等价于 android:extractNativeLibs="true"）。
            //
            // 我们用 jniLibs/arm64-v8a/libadb.so 夹带了一个 Android NDK 编译的
            // adb 可执行文件（开机自启要用它自连 127.0.0.1:5555 拿 shell）。
            // AGP 默认 useLegacyPackaging=false —— .so 会以未解压形式留在 APK 内、
            // 由 linker 直接从 APK 映射，这种形式 **无法被 Runtime.exec 执行**。
            // 只有解压到 nativeLibraryDir 才有文件系统路径、才带可执行位。
            //
            // 代价：所有 native 库都会被解压安装（安装体积略增），换取可执行能力。
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}
