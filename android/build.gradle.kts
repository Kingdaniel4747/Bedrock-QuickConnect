allprojects {
    repositories { google(); mavenCentral() }
}
val output = rootProject.layout.projectDirectory.dir("../build")
rootProject.layout.buildDirectory.set(output)
subprojects {
    layout.buildDirectory.set(output.dir(name))
    if (name != "app") evaluationDependsOn(":app")
}
tasks.register<Delete>("clean") { delete(output) }
