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

    // Fix: flutter_bluetooth_serial compila contra un compileSdk < 31 y falla con
    // "resource android:attr/lStar not found". Forzamos compileSdk 34 solo en ese
    // plugin (los modernos como agora leen compileSdk durante la evaluación y no
    // admiten cambiarlo en afterEvaluate).
    if (project.name == "flutter_bluetooth_serial") {
        project.afterEvaluate {
            val androidExtension = project.extensions.findByName("android")
                    as? com.android.build.gradle.BaseExtension
            androidExtension?.compileSdkVersion(34)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
