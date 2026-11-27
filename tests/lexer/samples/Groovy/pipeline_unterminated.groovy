// Second Groovy sample: Jenkins-style pipeline DSL, ends inside an unterminated comment
@Library('shared-lib@main') _

import groovy.transform.Field
import java.util.regex.Matcher

@Field final String REGISTRY = 'registry.example.com'
@Field def deployTargets = ['staging', "prod-${env.REGION ?: 'us'}"]

def buildImage(String name, String tag = 'latest') {
    def full = "${REGISTRY}/${name}:${tag}"
    sh """
        docker build \\
            --build-arg VERSION=${tag} \\
            --build-arg GIT_SHA=\$(git rev-parse --short HEAD) \\
            -t ${full} .
        docker push ${full}
    """
    return full
}

def notify(String status, Map opts = [:]) {
    def color = status == 'SUCCESS' ? 'good' : status == 'UNSTABLE' ? 'warning' : 'danger'
    def msg = "*${env.JOB_NAME}* #${env.BUILD_NUMBER}: ${status} (<${env.BUILD_URL}|open>)"
    if (opts.details) {
        msg += "\n```${opts.details}```"
    }
    slackSend(color: color, message: msg, channel: opts.channel ?: '#ci')
}

pipeline {
    agent {
        kubernetes {
            yaml '''
                apiVersion: v1
                kind: Pod
                spec:
                  containers:
                    - name: build
                      image: "gradle:8-jdk21"
                      command: ['sleep']
                      args: ['infinity']
            '''
        }
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
    }

    parameters {
        string(name: 'BRANCH', defaultValue: 'main', description: "Branch to build (e.g. 'main')")
        booleanParam(name: 'DEPLOY', defaultValue: false)
        choice(name: 'ENV', choices: ['dev', 'staging', 'prod'])
    }

    environment {
        GRADLE_OPTS = '-Dorg.gradle.daemon=false -Xmx2g'
        VERSION = "1.${env.BUILD_NUMBER}.0"
        CREDS = credentials('deploy-creds')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_COMMIT_MSG = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
                    def m = env.GIT_COMMIT_MSG =~ /\[(skip ci|ci skip)\]/
                    if (m.find()) {
                        currentBuild.result = 'NOT_BUILT'
                        error "Skipping build: ${m.group(1)}"
                    }
                }
            }
        }

        stage('Build & Test') {
            parallel {
                stage('Unit') {
                    steps {
                        container('build') {
                            sh './gradlew test --no-daemon --parallel'
                        }
                    }
                    post {
                        always { junit '**/build/test-results/**/*.xml' }
                    }
                }
                stage('Lint') {
                    steps {
                        sh '''
                            ./gradlew ktlintCheck detekt
                            echo "lint done: $(date +%s)"
                        '''
                    }
                }
            }
        }

        stage('Image') {
            when {
                anyOf {
                    branch 'main'
                    expression { params.DEPLOY == true }
                }
            }
            steps {
                script {
                    env.IMAGE = buildImage('app', env.VERSION)
                }
            }
        }

        stage('Deploy') {
            when { expression { return params.DEPLOY && params.ENV != 'dev' } }
            steps {
                script {
                    deployTargets.each { target ->
                        echo "Deploying ${env.IMAGE} to ${target}"
                        sh "helm upgrade --install app ./chart --set image=${env.IMAGE} --namespace ${target}"
                    }
                    input message: "Promote to ${params.ENV}?", ok: 'Yes, promote'
                }
            }
        }
    }

    post {
        success { notify('SUCCESS') }
        unstable { notify('UNSTABLE', [details: currentBuild.description]) }
        failure {
            notify('FAILURE', [channel: '#alerts', details: "Stage failed: ${env.STAGE_NAME}"])
        }
        cleanup { cleanWs() }
    }
}

// Utility closures and regexes in a pipeline script
def semver = ~/^(\d+)\.(\d+)\.(\d+)(?:-([\w.]+))?$/
def parseVersion = { String v ->
    Matcher mm = v =~ semver
    mm.matches() ? [major: mm[0][1] as int, minor: mm[0][2] as int, patch: mm[0][3] as int] : null
}
def bump = { Map ver, String part = 'patch' ->
    switch (part) {
        case 'major': return "${ver.major + 1}.0.0"
        case 'minor': return "${ver.major}.${ver.minor + 1}.0"
        default: return "${ver.major}.${ver.minor}.${ver.patch + 1}"
    }
}
def dollarSlashyRegex = $/C:\path\to\$file\with\/slashes/$
def divisionNotSlashy = env.BUILD_NUMBER.toInteger() / 2 / 1
def numbers = [0x1F, 07, 0b11, 1_000L, 2.5G, 1e3f, 4d]

/* Pipeline notes — this block comment is never closed.
 * sh "echo ${notInterpolated}"
 * def x = 'not code'
 * stage('Fake') { steps { echo "still in comment" } }
 * /* not nested in Groovy, so this inner opener is plain text */
 * the line above contained a closer, but in a non-nesting language that DID close it!
def reallyCode = "this line is code again because the comment closed above"
/* and this one opens a fresh comment that never ends
pipeline { agent none }
