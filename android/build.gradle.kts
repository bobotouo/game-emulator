import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Match app ndk.abiFilters — avoid building unused ABIs (pdfrx CMake on armeabi-v7a).
subprojects {
    afterEvaluate {
        extensions.findByType<LibraryExtension>()?.defaultConfig?.ndk?.apply {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
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
