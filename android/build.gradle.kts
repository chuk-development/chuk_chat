import javax.inject.Inject
import org.gradle.process.ExecOperations

allprojects {
    repositories {
        google()
        mavenCentral()
    }
    
    // Force Java 17 and Kotlin JVM target 17 for all projects to avoid compatibility issues
    afterEvaluate {
        if (project.hasProperty("android")) {
            val android = project.extensions.findByName("android")
            if (android != null && android is com.android.build.gradle.BaseExtension) {
                android.compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
                // Some plugins still declare an old compileSdk (add_2_calendar 3.0.1
                // is on 33) while pulling androidx artifacts that demand 34+. Lift
                // every subproject to the app's compileSdk so the AAR metadata check
                // passes.
                val current =
                    android.compileSdkVersion
                        ?.substringAfter("android-")
                        ?.substringBefore(".")
                        ?.toIntOrNull() ?: 0
                if (current < 36) {
                    android.compileSdkVersion(36)
                }
            }
        }
        // Also configure Kotlin JVM target. Kotlin 2.2 removed the kotlinOptions
        // block, so this goes through the compilerOptions DSL.
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// AGP 9 throws while it evaluates a module that calls
// getDefaultProguardFile("proguard-android.txt"). flutter_inappwebview_android
// 1.1.3 (the newest stable, from 2024) still does that in its debug and
// release build types: pichillilorenzo/flutter_inappwebview#2852, fix for the
// 6.1.5 line in PR #2897 (open). 1.2.0-beta has the fix but is a beta.
// Gradle's closure lookup checks a build type's extra properties before the
// android extension, so a closure with the same name on each build type
// answers the call first and hands out the optimize file instead.
// Remove this block when a stable flutter_inappwebview_android ships the fix.
subprojects {
    if (name == "flutter_inappwebview_android") {
        pluginManager.withPlugin("com.android.library") {
            val android = extensions.getByType(com.android.build.gradle.LibraryExtension::class.java)
            android.buildTypes.configureEach {
                (this as ExtensionAware).extra.set(
                    "getDefaultProguardFile",
                    KotlinClosure1<String, File>({
                        android.getDefaultProguardFile(
                            if (this == "proguard-android.txt") "proguard-android-optimize.txt" else this,
                        )
                    }),
                )
            }
        }
    }
}

// CargoKit (the Rust build glue that irondash_engine_context 0.5.5 and
// super_native_extensions 0.9.1 ship, via markdraw -> super_clipboard) fails
// on AGP 9 + Gradle 9 in two places: it parses compileSdk "android-37.0" as an
// int, and its task calls Project.exec, which Gradle 9 removed.
// Upstream: superlistapp/super_native_extensions#565, fix in PR #585 (open);
// their 0.10 line drops CargoKit for native-assets hooks and is still -dev.
// CargoKit's own afterProject listener skips a build type whose task already
// exists. This listener is registered first, so it creates that task with the
// same name and the same environment, but with ExecOperations and the major
// API level. Remove it when a stable super_native_extensions has the fix.
abstract class CargokitBuildTask : DefaultTask() {
    @get:Inject abstract val execOperations: ExecOperations
    @get:Input abstract val environment: MapProperty<String, String>
    @get:Input abstract val buildTool: Property<String>

    @TaskAction
    fun build() {
        execOperations.exec { commandLine("chmod", "+x", buildTool.get()) }
        execOperations.exec {
            executable(buildTool.get())
            args("build-gradle")
            environment(this@CargokitBuildTask.environment.get())
        }
    }
}

gradle.afterProject {
    val cargokit = extensions.findByName("cargokit") as? groovy.lang.GroovyObject ?: return@afterProject
    val libname = cargokit.getProperty("libname") as String
    val manifestDir = cargokit.getProperty("manifestDir") as String
    val app = rootProject.project(":app").extensions.getByType(com.android.build.gradle.BaseExtension::class.java)
    // .../<package>/android/build.gradle -> .../<package>/cargokit/run_build_tool.sh
    val buildTool = buildFile.parentFile.resolve("../cargokit/run_build_tool.sh").canonicalPath
    val compileSdk = Regex("""\d+""").find(app.compileSdkVersion!!.removePrefix("android-"))!!.value
    val requested =
        (findProperty("target-platform") as String?)?.split(",")
            ?: listOf("android-arm", "android-arm64", "android-x64")
    app.buildTypes.names.forEach { buildType ->
        val suffix = buildType.replaceFirstChar { it.uppercase() }
        val platforms = if (buildType == "debug") requested + listOf("android-x86", "android-x64") else requested
        val cargoBuildDir = layout.buildDirectory.dir("build").get().asFile.path
        val task =
            tasks.register<CargokitBuildTask>(
                "cargokitCargoBuild${libname.replaceFirstChar { it.uppercase() }}$suffix",
            ) {
                this.buildTool.set(buildTool)
                environment.set(
                    mapOf(
                        "CARGOKIT_ROOT_PROJECT_DIR" to rootProject.projectDir.path,
                        "CARGOKIT_TOOL_TEMP_DIR" to "$cargoBuildDir/build_tool",
                        "CARGOKIT_MANIFEST_DIR" to buildFile.parentFile.resolve(manifestDir).path,
                        "CARGOKIT_CONFIGURATION" to buildType,
                        "CARGOKIT_TARGET_TEMP_DIR" to cargoBuildDir,
                        "CARGOKIT_OUTPUT_DIR" to layout.buildDirectory.dir("jniLibs/$buildType").get().asFile.path,
                        "CARGOKIT_NDK_VERSION" to app.ndkVersion,
                        "CARGOKIT_SDK_DIR" to app.sdkDirectory.path,
                        "CARGOKIT_COMPILE_SDK_VERSION" to compileSdk,
                        "CARGOKIT_MIN_SDK_VERSION" to app.defaultConfig.minSdkVersion!!.apiLevel.toString(),
                        "CARGOKIT_TARGET_PLATFORMS" to platforms.joinToString(","),
                        "CARGOKIT_JAVA_HOME" to System.getProperty("java.home"),
                    ),
                )
            }
        tasks.matching { it.name == "merge${suffix}NativeLibs" }.configureEach {
            dependsOn(task)
            outputs.upToDateWhen { false }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
