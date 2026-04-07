allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Reverted to default build directory to avoid path/permission issues on Windows
val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // 1. Force all standard Java/Kotlin tasks to Java 17
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }

    afterEvaluate {
        val android = project.extensions.findByName("android")
        if (android != null) {
            try {
                // 2. Force compileSdkVersion to 36
                val compileSdkMethod = android.javaClass.methods.find {
                    it.name == "compileSdkVersion" &&
                            it.parameterTypes.size == 1 &&
                            (it.parameterTypes[0].name == "int" || it.parameterTypes[0].name == "java.lang.Integer")
                }
                compileSdkMethod?.invoke(android, 36)

                // 3. THE FIX: Forcibly overwrite the plugin's internal Android compileOptions to Java 17
                val compileOptions = android.javaClass.getMethod("getCompileOptions").invoke(android)
                if (compileOptions != null) {
                    val setSource = compileOptions.javaClass.getMethod("setSourceCompatibility", JavaVersion::class.java)
                    val setTarget = compileOptions.javaClass.getMethod("setTargetCompatibility", JavaVersion::class.java)
                    setSource.invoke(compileOptions, JavaVersion.VERSION_17)
                    setTarget.invoke(compileOptions, JavaVersion.VERSION_17)
                }
            } catch (_: Exception) {
                // Ignore silent reflection errors
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}