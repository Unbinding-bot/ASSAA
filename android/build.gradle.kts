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
}

// Runs once, after every project (including plugin subprojects like
// tflite_flutter) has fully finished configuring. This is what lets our
// JVM target override win over AGP's own compileOptions setting.
//
// Deliberately NOT a per-subproject afterEvaluate{} -- combined with
// evaluationDependsOn(":app") above, that caused "Cannot run
// Project.afterEvaluate(Action) when the project is already evaluated"
// for whichever project the dependency ordering had already forced
// through evaluation by the time the loop reached it. projectsEvaluated
// is a single Gradle-level lifecycle hook with no such per-project race.
gradle.projectsEvaluated {
    subprojects.forEach { sub ->
        sub.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
        sub.tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}