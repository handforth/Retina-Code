// Kotlin script (Gradle) sample for the lexer corpus
@file:Suppress("UnstableApiUsage")

import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    kotlin("jvm") version "2.0.21"
    kotlin("plugin.serialization") version "2.0.21"
    id("com.github.johnrengelman.shadow") version "8.1.1"
    `java-library`
    `maven-publish`
    application
}

/* Script-level block comment /* nested */ still a comment */

group = "com.example"
version = "1.2.3-SNAPSHOT"
description = """
    A "multi-line" description with ${project.name} interpolation
    and a literal ${'$'}{not.interpolated} sequence.
""".trimIndent()

val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

val apiKey: String = localProps.getProperty("api.key") ?: System.getenv("API_KEY") ?: ""
val buildNumber = (System.getenv("BUILD_NUMBER") ?: "0").toInt()
val isCi = System.getenv("CI")?.toBoolean() == true

repositories {
    mavenCentral()
    google()
    maven { url = uri("https://repo.example.com/releases/") }
    maven("https://jitpack.io") {
        content { includeGroupByRegex("com\\.github\\..*") }
    }
}

val ktorVersion: String by project
val coroutines = "1.9.0"

dependencies {
    implementation(kotlin("stdlib"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutines")
    implementation("io.ktor:ktor-server-netty:${ktorVersion}")
    implementation(platform("org.junit:junit-bom:5.11.0"))
    api(project(":core"))
    compileOnly(files("libs/a.jar", "libs/b.jar"))
    runtimeOnly(fileTree("libs") { include("*.jar") })
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_21)
        freeCompilerArgs.addAll(listOf("-Xjsr305=strict", "-opt-in=kotlin.RequiresOptIn"))
        allWarningsAsErrors = isCi
    }
}

application {
    mainClass.set("com.example.MainKt")
    applicationDefaultJvmArgs = listOf("-Xmx512m", "-Dfile.encoding=UTF-8")
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    maxParallelForks = (Runtime.getRuntime().availableProcessors() / 2).coerceAtLeast(1)
    testLogging {
        events("passed", "skipped", "failed")
        showStandardStreams = true
    }
    systemProperty("test.timeout", 30_000L)
    jvmArgs("-XX:+UseG1GC")
}

tasks.register<Copy>("copyAssets") {
    from(layout.projectDirectory.dir("assets")) {
        include("**/*.png", "**/*.svg")
        exclude("**/tmp/**")
        filter { line -> line.replace("@VERSION@", version.toString()) }
    }
    into(layout.buildDirectory.dir("assets"))
}

val generateBuildInfo by tasks.registering {
    val out = layout.buildDirectory.file("generated/BuildInfo.kt")
    outputs.file(out)
    doLast {
        out.get().asFile.apply {
            parentFile.mkdirs()
            writeText(
                """
                package com.example

                object BuildInfo {
                    const val VERSION = "$version"
                    const val BUILD = $buildNumber
                    const val TIMESTAMP = "${java.time.Instant.now()}"
                    const val DOLLAR = "${'$'}"
                }
                """.trimIndent()
            )
        }
    }
}

tasks.named("compileKotlin") { dependsOn(generateBuildInfo) }

tasks.jar {
    manifest {
        attributes(
            "Implementation-Title" to project.name,
            "Implementation-Version" to project.version,
            "Built-By" to (System.getProperty("user.name") ?: "unknown"),
        )
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
            pom {
                name.set("Example")
                url.set("https://example.com")
                licenses { license { name.set("MIT") } }
            }
        }
    }
}

fun String.shell(): String =
    ProcessBuilder("sh", "-c", this).redirectErrorStream(true).start().inputStream.bufferedReader().readText().trim()

val gitHash: String by lazy { runCatching { "git rev-parse --short HEAD".shell() }.getOrDefault("unknown") }

if (buildNumber > 0 && buildNumber % 2 == 0) {
    logger.lifecycle("Even build #$buildNumber at ${gitHash}")
} else if (buildNumber < 0) {
    throw GradleException("Invalid build number: $buildNumber (expected >= 0)")
}

val flags = mapOf(
    "hex" to 0xFF,
    "bin" to 0b101,
    "long" to 1_000L,
    "float" to 1.5f,
    "double" to 2.5e-3,
    "char" to 'A',
    "unsigned" to 42u,
)

// Last line is a line comment without trailing newline handling issues: "quote' `tick
