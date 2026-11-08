plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystore = providers.environmentVariable("QUICKCONNECT_KEYSTORE")
val releasePassword = providers.environmentVariable("QUICKCONNECT_KEYSTORE_PASSWORD")

android {
    namespace = "de.quickconnect.app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "de.quickconnect.app"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging.jniLibs.useLegacyPackaging = true
    if (releaseKeystore.isPresent) {
        val releaseSigning = signingConfigs.create("release") {
            storeFile = file(releaseKeystore.get())
            storePassword = releasePassword.get()
            keyAlias = "quickconnect"
            keyPassword = releasePassword.get()
        }
        buildTypes["release"].signingConfig = releaseSigning
    }
    sourceSets["main"].assets.srcDir(rootProject.layout.projectDirectory.dir("../licenses"))
}

dependencies {
    implementation("androidx.core:core:1.15.0")
    implementation("androidx.datastore:datastore-preferences:1.2.0")
    testImplementation("junit:junit:4.13.2")
}

val engine = rootProject.layout.projectDirectory.dir("../engine")
val nativeOutput = layout.buildDirectory.dir("generated/quickconnect/jni")
val goCommand = providers.environmentVariable("QUICKCONNECT_GO").orElse("go")
val sdkNdk = androidComponents.sdkComponents.ndkDirectory
val compileEngine = tasks.register("compileNetherNet") {
    inputs.files(fileTree(engine) { include("**/*.go", "**/*.c", "**/*.json", "**/*.mod", "**/*.sum") })
    inputs.property("goExecutable", goCommand)
    inputs.property("ndkVersion", "28.2.13676358")
    outputs.dir(nativeOutput)
    val runner = project.providers
    doLast {
        val os = System.getProperty("os.name").lowercase()
        val windows = os.startsWith("windows")
        val host = when {
            windows -> "windows-x86_64"
            os.startsWith("mac") -> "darwin-x86_64"
            else -> "linux-x86_64"
        }
        val clang = sdkNdk.get().asFile.resolve(
            "toolchains/llvm/prebuilt/$host/bin/" + if (windows) "clang.exe" else "clang"
        )
        check(clang.isFile) { "Android NDK 28.2.13676358 fehlt: $clang" }
        val targets = mapOf(
            "arm64-v8a" to ("arm64" to "aarch64-linux-android29"),
            "x86_64" to ("amd64" to "x86_64-linux-android29")
        )
        for ((abi, target) in targets) {
            val output = nativeOutput.get().asFile.resolve("$abi/libquickconnect.so")
            output.parentFile.mkdirs()
            val build = runner.exec {
                isIgnoreExitValue = true
                workingDir(engine.asFile)
                environment("GOOS", "android")
                environment("GOARCH", target.first)
                environment("CGO_ENABLED", "1")
                environment("CC", clang.absolutePath)
                environment("CGO_CFLAGS", "--target=${target.second}")
                environment("CGO_LDFLAGS", "--target=${target.second}")
                commandLine(goCommand.get(), "build", "-mod=readonly", "-trimpath",
                    "-buildmode=c-shared", "-ldflags=-s -w", "-o", output.absolutePath, "./mobile")
            }
            check(build.result.get().exitValue == 0) {
                "NetherNet-Build fehlgeschlagen ($abi): " + build.standardError.asText.get()
            }
            output.resolveSibling("libquickconnect.h").delete()
        }
    }
}
android.sourceSets["main"].jniLibs.srcDir(nativeOutput.get().asFile)
tasks.named("preBuild").configure { dependsOn(compileEngine) }

flutter { source = "../.." }




kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
