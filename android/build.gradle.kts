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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
