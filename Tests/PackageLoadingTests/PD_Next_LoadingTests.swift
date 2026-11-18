//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageLoading
import PackageModel
import _InternalTestSupport
import XCTest
import Testing

final class PackageDescriptionNextLoadingTests: PackageDescriptionLoadingTests {
    override var toolsVersion: ToolsVersion {
        .vNext
    }

    func testImplicitFoundationImportFails() async throws {
        let content = """
            import PackageDescription

            _ = FileManager.default

            let package = Package(name: "MyPackage")
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") {
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = $0 {
                XCTAssertMatch(error, .contains("cannot find 'FileManager' in scope"))
            } else {
                XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testAnyAppleOSPlatform() async throws {
        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .anyAppleOS(.v26), .driverKit(.v27),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.platforms, [
                PlatformDescription(name: "driverkit", version: "27.0"),
                PlatformDescription(name: "macos", version: "26.0"),
                PlatformDescription(name: "maccatalyst", version: "26.0"),
                PlatformDescription(name: "ios", version: "26.0"),
                PlatformDescription(name: "tvos", version: "26.0"),
                PlatformDescription(name: "watchos", version: "26.0"),
                PlatformDescription(name: "visionos", version: "26.0"),
            ])
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .macOS(.v27), .anyAppleOS(.v26), .iOS(.v27),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
            XCTAssertNoDiagnostics(observability.diagnostics)
            XCTAssertNoDiagnostics(validationDiagnostics)

            XCTAssertEqual(manifest.platforms, [
                PlatformDescription(name: "macos", version: "27.0"),
                PlatformDescription(name: "ios", version: "27.0"),
                PlatformDescription(name: "maccatalyst", version: "26.0"),
                PlatformDescription(name: "tvos", version: "26.0"),
                PlatformDescription(name: "watchos", version: "26.0"),
                PlatformDescription(name: "visionos", version: "26.0"),
            ])
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .anyAppleOS("18.0"),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                    XCTAssertEqual(errors, ["invalid anyAppleOS version 18.0; the minimum major version should be 26"])
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        do {
            let content = """
                import PackageDescription
                let package = Package(
                   name: "Foo",
                   platforms: [
                       .anyAppleOS(.v26), .anyAppleOS(.v27),
                   ]
                )
                """

            let observability = ObservabilitySystem.makeForTesting()
            await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") { error in
                if case ManifestParseError.runtimeManifestErrors(let errors) = error {
                    XCTAssertEqual(errors, ["found multiple declarations for the platform: anyAppleOS"])
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testAnyAppleOSCondition() async throws {
        let content = """
            import PackageDescription
            let package = Package(
               name: "Foo",
               targets: [
                   .target(name: "Foo", swiftSettings: [.define("APPLE", .when(platforms: [.anyAppleOS]))]),
               ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        XCTAssertEqual(manifest.targets[0].settings[0].condition, PackageConditionDescription(platformNames: ["anyappleos"]))
    }

    func testTargetDependencyInvalidPackage() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Trivial",
                dependencies: [
                    .package(url: "http://scm.com/org/foo", from: "1.0.0"),
                    .package(url: "http://scm.com/org/bar", from: "1.0.0"),
                ],
                targets: [
                    .target(
                        name: "Target1",
                        dependencies: [.target(name: "FooLib", package: "foo1")]),
                    .target(
                        name: "Target2",
                        dependencies: [.target(name: "FooLib", package: "foo")]),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (_, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        testDiagnostics(validationDiagnostics) { result in
            result.check(diagnostic: "unknown package 'foo1' in dependencies of target 'Target1'; valid packages are: 'foo' (from 'http://scm.com/org/foo'), 'bar' (from 'http://scm.com/org/bar')", severity: .error)
        }
    }

    func testTargetFactoriesWithoutTargetSuffix() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                targets: [
                    .target(name: "Regular"),
                    .library(name: "Lib", type: .static, dependencies: ["Regular"], visibility: .public),
                    .executable(name: "Exe", dependencies: ["Lib"]),
                    .test(name: "LibTests", dependencies: ["Lib"]),
                    .binary(name: "LocalBinary", path: "Local.xcframework"),
                    .binary(name: "RemoteBinary", url: "https://example.com/Remote.zip", checksum: "abc"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, validationDiagnostics) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)
        XCTAssertNoDiagnostics(observability.diagnostics)
        XCTAssertNoDiagnostics(validationDiagnostics)

        let targets = Dictionary(uniqueKeysWithValues: manifest.targets.map { ($0.name, $0) })
        XCTAssertEqual(targets["Regular"]?.type, .regular)
        XCTAssertEqual(targets["Lib"]?.type, .library(.static))
        XCTAssertEqual(targets["Lib"]?.visibility, .public)
        XCTAssertEqual(targets["Exe"]?.type, .executable)
        XCTAssertEqual(targets["LibTests"]?.type, .test)
        XCTAssertEqual(targets["LocalBinary"]?.type, .binary)
        XCTAssertEqual(targets["LocalBinary"]?.path, "Local.xcframework")
        XCTAssertEqual(targets["RemoteBinary"]?.type, .binary)
        XCTAssertEqual(targets["RemoteBinary"]?.url, "https://example.com/Remote.zip")
        XCTAssertEqual(targets["RemoteBinary"]?.checksum, "abc")
    }

    func testDeprecatedTargetSuffixedFactories() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                targets: [
                    .executableTarget(name: "Exe"),
                    .testTarget(name: "ExeTests", dependencies: ["Exe"]),
                    .binaryTarget(name: "LocalBinary", path: "Local.xcframework"),
                    .binaryTarget(name: "RemoteBinary", url: "https://example.com/Remote.zip", checksum: "abc"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        let (manifest, _) = try await loadAndValidateManifest(content, observabilityScope: observability.topScope)

        let targets = Dictionary(uniqueKeysWithValues: manifest.targets.map { ($0.name, $0) })
        XCTAssertEqual(targets["Exe"]?.type, .executable)
        XCTAssertEqual(targets["ExeTests"]?.type, .test)
        XCTAssertEqual(targets["LocalBinary"]?.type, .binary)
        XCTAssertEqual(targets["RemoteBinary"]?.type, .binary)

        let warnings = observability.diagnostics.filter { $0.severity == .warning }.map(\.message).joined(separator: "\n")
        XCTAssertMatch(warnings, .contains("'executableTarget(name:"))
        XCTAssertMatch(warnings, .contains("renamed to 'executable'"))
        XCTAssertMatch(warnings, .contains("renamed to 'test'"))
        XCTAssertMatch(warnings, .contains("renamed to 'binary'"))
    }

    func testLibraryTargetFactoryRemoved() async throws {
        let content = """
            import PackageDescription
            let package = Package(
                name: "Foo",
                targets: [
                    .libraryTarget(name: "Lib"),
                ]
            )
            """

        let observability = ObservabilitySystem.makeForTesting()
        await XCTAssertAsyncThrowsError(try await loadAndValidateManifest(content, observabilityScope: observability.topScope), "expected error") {
            if case ManifestParseError.invalidManifestFormat(let error, _, _) = $0 {
                XCTAssertMatch(error, .contains("libraryTarget"))
            } else {
                XCTFail("unexpected error: \($0)")
            }
        }
    }
}
