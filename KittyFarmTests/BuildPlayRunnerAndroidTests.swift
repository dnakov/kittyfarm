import Foundation
import XCTest
@testable import KittyFarm

final class BuildPlayRunnerAndroidTests: XCTestCase {
    func testDiscoverAndroidProjectReadsGroovySingleQuotesDebugSuffixAndModuleTask() async throws {
        let root = try makeGradleRoot()
        let module = root.appending(path: "akari", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try """
        plugins {
            id 'com.android.application'
        }

        android {
            namespace = 'cz.danurbanek.lightup'

            defaultConfig {
                applicationId = 'cz.danurbanek.lightup'
            }

            signingConfigs {
                debug {
                    keyAlias = "androiddebugkey"
                }
            }

            buildTypes {
                debug {
                    applicationIdSuffix = ".debug"
                }
            }
        }
        """.write(to: module.appending(path: "build.gradle"), atomically: true, encoding: .utf8)

        let project = try await BuildPlayRunner.discoverAndroidProject(at: root)

        XCTAssertEqual(project.projectDirectoryPath, root.path)
        XCTAssertEqual(project.applicationID, "cz.danurbanek.lightup.debug")
        XCTAssertEqual(project.gradleTask, ":akari:installDebug")
    }

    func testDiscoverAndroidProjectListsMultipleApplicationTargets() async throws {
        let root = try makeGradleRoot()
        try writeAndroidAppModule(
            named: "akari",
            under: root,
            applicationID: "cz.danurbanek.lightup",
            debugSuffix: ".debug"
        )
        try writeAndroidAppModule(
            named: "hue",
            under: root,
            applicationID: "cz.dnesdan.hue",
            debugSuffix: ".debug"
        )

        let project = try await BuildPlayRunner.discoverAndroidProject(at: root)

        XCTAssertEqual(
            project.appTargets.map(\.gradleTask),
            [":akari:installDebug", ":hue:installDebug"]
        )
        XCTAssertEqual(project.appTargets[0].applicationID, "cz.danurbanek.lightup.debug")
        XCTAssertEqual(project.appTargets[1].applicationID, "cz.dnesdan.hue.debug")
    }

    func testDiscoverAndroidProjectKeepsRootInstallTaskForRootApplicationModule() async throws {
        let root = try makeGradleRoot()
        try """
        plugins {
            id("com.android.application")
        }

        android {
            defaultConfig {
                applicationId "cz.example.rootapp"
            }
        }
        """.write(to: root.appending(path: "build.gradle"), atomically: true, encoding: .utf8)

        let project = try await BuildPlayRunner.discoverAndroidProject(at: root)

        XCTAssertEqual(project.applicationID, "cz.example.rootapp")
        XCTAssertEqual(project.gradleTask, "installDebug")
    }

    func testAndroidProjectConfigurationDecodesOldSavedConfigWithoutTargets() throws {
        let data = Data("""
        {
            "projectDirectoryPath": "/tmp/game",
            "applicationID": "cz.example.game.debug",
            "gradleTask": ":game:installDebug"
        }
        """.utf8)

        let project = try JSONDecoder().decode(AndroidProjectConfiguration.self, from: data)

        XCTAssertEqual(project.applicationID, "cz.example.game.debug")
        XCTAssertEqual(project.gradleTask, ":game:installDebug")
        XCTAssertTrue(project.appTargets.isEmpty)
    }

    private func makeGradleRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "KittyFarmAndroidDiscovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gradlew = root.appending(path: "gradlew")
        try "#!/bin/sh\n".write(to: gradlew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gradlew.path)
        return root
    }

    private func writeAndroidAppModule(
        named name: String,
        under root: URL,
        applicationID: String,
        debugSuffix: String
    ) throws {
        let module = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try """
        plugins {
            id 'com.android.application'
        }

        android {
            defaultConfig {
                applicationId = '\(applicationID)'
            }

            buildTypes {
                debug {
                    applicationIdSuffix = "\(debugSuffix)"
                }
            }
        }
        """.write(to: module.appending(path: "build.gradle"), atomically: true, encoding: .utf8)
    }
}
