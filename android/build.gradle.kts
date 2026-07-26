allprojects {
    repositories {
        google()
        mavenCentral()
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

    // Forces every plugin subproject (including tflite_flutter, which
    // otherwise compiles its Kotlin against JVM 17 while its Java
    // compilation stays on 1.8 and Gradle refuses to mix the two) onto a
    // single consistent JVM target.
    //
    // This has to be wrapped in afterEvaluate: subprojects{} runs BEFORE
    // each subproject's own build.gradle applies the Android Gradle
    // Plugin, and AGP sets compileOptions from that plugin's own script
    // (tflite_flutter's still hardcodes JavaVersion.VERSION_1_8) AFTER
    // that point -- so without afterEvaluate, AGP's 1.8 silently
    // overwrites whatever we set here first.
    afterEvaluate {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}