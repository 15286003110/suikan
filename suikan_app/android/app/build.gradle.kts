import java.util.Properties
import java.io.FileInputStream
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
val hasReleaseKeystore = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
    .all { !keystoreProperties.getProperty(it).isNullOrBlank() }

val syncDartQuickJsJniLibs = tasks.register("syncDartQuickJsJniLibs") {
    val projectRoot = rootProject.projectDir.parentFile
    val hooksRoot = projectRoot.resolve(".dart_tool/hooks_runner/dart_quickjs")
    val sharedBuildRoot = projectRoot.resolve(".dart_tool/hooks_runner/shared/dart_quickjs/build")
    val generatedRoot = projectDir.resolve("build/generated/dart_quickjs/jniLibs")
    val flutterNativeAssetsRoot = projectRoot.resolve("build/native_assets/android/jniLibs/lib")
    val abiByArch = mapOf(
        "arm" to "armeabi-v7a",
        "arm64" to "arm64-v8a",
        "x64" to "x86_64"
    )

    fun jsonStringValue(text: String, key: String): String? {
        return Regex("\"$key\"\\s*:\\s*\"([^\"]+)\"")
            .find(text)
            ?.groupValues
            ?.get(1)
    }

    doLast {
        val flutterNativeAssetsReady = abiByArch.values.all { abi ->
            flutterNativeAssetsRoot.resolve("$abi/libdart_quickjs.so").let { it.exists() && it.length() > 0 }
        }
        if (flutterNativeAssetsReady) {
            generatedRoot.deleteRecursively()
            logger.lifecycle("Using Flutter native assets for dart_quickjs Android libraries.")
            return@doLast
        }

        if (!hooksRoot.exists()) {
            logger.warn("dart_quickjs native asset hooks directory does not exist: $hooksRoot")
            return@doLast
        }

        val candidates = hooksRoot
            .walkTopDown()
            .filter { it.isFile && it.name == "input.json" }
            .mapNotNull { inputFile ->
                val inputText = inputFile.readText(Charsets.UTF_8)
                if (jsonStringValue(inputText, "target_os") != "android") {
                    return@mapNotNull null
                }
                val abi = abiByArch[jsonStringValue(inputText, "target_architecture")]
                    ?: return@mapNotNull null
                val buildId = inputFile.parentFile.name
                val source = sharedBuildRoot.resolve("$buildId/libdart_quickjs.so")
                if (!source.exists()) {
                    return@mapNotNull null
                }
                val linkingEnabled =
                    Regex("\"linking_enabled\"\\s*:\\s*true").containsMatchIn(inputText)
                Triple(abi, linkingEnabled, source)
            }
            .toList()

        if (candidates.isEmpty()) {
            logger.warn("No dart_quickjs Android native libraries were found under $hooksRoot")
            return@doLast
        }

        generatedRoot.deleteRecursively()
        candidates
            .groupBy { it.first }
            .forEach { (abi, items) ->
                val selected = items
                    .sortedWith(compareByDescending<Triple<String, Boolean, java.io.File>> { it.second }
                        .thenByDescending { it.third.lastModified() })
                    .first()
                    .third
                val target = generatedRoot.resolve("$abi/libdart_quickjs.so")
                target.parentFile.mkdirs()
                selected.copyTo(target, overwrite = true)
            }
    }
}

tasks.named("preBuild") {
    dependsOn(syncDartQuickJsJniLibs)
}

android {
    namespace = "com.suikan.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("build/generated/dart_quickjs/jniLibs")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.suikan.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ⚠️ 手机版体积铁律（2026-08-31 实测，改前先看这段）：
        // media_kit 的 libmpv.so 是 **AAR 依赖里的预编译 so**，按 ABI 全量打包。
        // `--target-platform android-arm64` 只管 Dart 的 libapp.so，管不到它。
        // 若编译时漏了 `--split-per-abi`，装出来的 universal 包会把
        // armeabi-v7a(11.2MB) + x86_64(15.1MB) 的 libmpv.so 一起打进去，
        // 安装包从 ~45MB 膨胀到 ~70MB，多出的 26MB 在 arm64 手机上永远用不到。
        // → **手机版编译命令必须带 `--split-per-abi`**，产物取 app-arm64-v8a-release.apk。
        //
        // ❌ 别试图用 `ndk { abiFilters += listOf("arm64-v8a") }` 解决：实测对这类
        // AAR so **完全不生效**（连续两次编译仍是 69.9MB，三个 ABI 的 mpv 全在）。
        // 而且它与 `--split-per-abi` 互斥，同时存在会直接构建失败：
        // "Conflicting configuration: 'arm64-v8a' in ndk abiFilters cannot be
        //  present when splits abi filters are set"。
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
                isV1SigningEnabled = true
                isV2SigningEnabled = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                // Default file with automatically generated optimization rules.
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

flutter {
    source = "../.."
}
