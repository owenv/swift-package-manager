/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCUtility
import TSCBasic
import SourceControl
import PackageLoading
import PackageModel
import Workspace
import Foundation

/// An editor for Swift packages.
///
/// This class provides high-level functionality for performing
/// editing operations a package.
public final class PackageEditor {

    /// Reference to the package editor context.
    let context: PackageEditorContext

    /// Create a package editor instance.
    public convenience init(manifestPath: AbsolutePath,
                            repositoryManager: RepositoryManager,
                            toolchain: UserToolchain) throws {
        self.init(context: try PackageEditorContext(manifestPath: manifestPath,
                                                    repositoryManager: repositoryManager,
                                                    toolchain: toolchain))
    }

    /// Create a package editor instance.
    public init(context: PackageEditorContext) {
        self.context = context
    }

    /// The file system to perform disk operations on.
    var fs: FileSystem {
        return context.fs
    }

    /// Add a package dependency.
    public func addPackageDependency(url: String, requirement: PackageDependencyRequirement?) throws {
      var requirement = requirement
        let manifestPath = context.manifestPath
        // Validate that the package doesn't already contain this dependency.
        let loadedManifest = try context.loadManifest(at: context.manifestPath.parentDirectory)

        guard loadedManifest.toolsVersion >= .v5_2 else {
            throw StringError("mechanical manifest editing operations are only supported for packages with swift-tools-version 5.2 and later")
        }

        let containsDependency = loadedManifest.dependencies.contains {
            return PackageIdentity(url: url) == PackageIdentity(url: $0.url)
        }
        guard !containsDependency else {
            throw StringError("'\(url)' is already a package dependency")
        }

        // If the input URL is a path, force the requirement to be a local package.
        if TSCUtility.URL.scheme(url) == nil {
            guard requirement == nil || requirement == .localPackage else {
                throw StringError("'\(url)' is a local path, but a non-local requirement was specified")
            }
            requirement = .localPackage
        }

        // Load the dependency manifest depending on the inputs.
        let dependencyManifest: Manifest
        if requirement == .localPackage {
            let path = AbsolutePath(url, relativeTo: fs.currentWorkingDirectory!)
            dependencyManifest = try context.loadManifest(at: path)
            requirement = .localPackage
        } else {
            // Otherwise, first lookup the dependency.
            let spec = RepositorySpecifier(url: options.url)
            let handle = try temp_await{ context.repositoryManager.lookup(repository: spec, completion: $0) }
            let repo = try handle.open()

            // Compute the requirement.
            if let inputRequirement = requirement {
                requirement = inputRequirement
            } else {
                // Use the latest version or the master branch.
                let versions = repo.tags.compactMap{ Version(string: $0) }
                let latestVersion = versions.filter({ $0.prereleaseIdentifiers.isEmpty }).max() ?? versions.max()
                let mainExists = (try? repo.resolveRevision(identifier: "main")) != nil
                requirement = latestVersion.map{ PackageDependencyRequirement.upToNextMajor($0.description) } ??
                    (mainExists ? PackageDependencyRequirement.branch("main") : PackageDependencyRequirement.branch("master"))
            }

            // Load the manifest.
            let revision = try repo.resolveRevision(identifier: requirement!.ref!)
            let repoFS = try repo.openFileView(revision: revision)
            dependencyManifest = try context.loadManifest(at: .root, fs: repoFS)
        }

        // Add the package dependency.
        let manifestContents = try fs.readFileContents(manifestPath).cString
        let editor = try ManifestRewriter(manifestContents)
        try editor.addPackageDependency(name: dependencyManifest.name, url: url, requirement: requirement!)

        try context.verifyEditedManifest(contents: editor.editedManifest)
        try fs.writeFileContents(manifestPath, bytes: ByteString(encodingAsUTF8: editor.editedManifest))
    }

    /// Add a new target.
    public func addTarget(_ newTarget: NewTarget) throws {
        let manifestPath = context.manifestPath

        // Validate that the package doesn't already contain a target with the same name.
        let loadedManifest = try context.loadManifest(at: manifestPath.parentDirectory)

        guard loadedManifest.toolsVersion >= .v5_2 else {
            throw StringError("mechanical manifest editing operations are only supported for packages with swift-tools-version 5.2 and later")
        }

        if loadedManifest.targets.contains(where: { $0.name == newTarget.name }) {
            throw StringError("a target named '\(newTarget.name)' already exists")
        }

        let manifestContents = try fs.readFileContents(manifestPath).cString
        let editor = try ManifestRewriter(manifestContents)

        switch newTarget {
        case .library(name: let name, includeTestTarget: _, dependencyNames: let dependencyNames),
             .executable(name: let name, dependencyNames: let dependencyNames),
             .test(name: let name, dependencyNames: let dependencyNames):
            try editor.addTarget(targetName: newTarget.name, factoryMethodName: newTarget.factoryMethodName)
            // FIXME: support product dependencies properly
            for dependency in dependencyNames {
                try editor.addTargetDependency(target: name, dependency: dependency)
            }
        case .binary(name: let name, urlOrPath: let urlOrPath, checksum: let checksum):
            try editor.addBinaryTarget(targetName: name, urlOrPath: urlOrPath, checksum: checksum)
        }

        try context.verifyEditedManifest(contents: editor.editedManifest)
        try fs.writeFileContents(manifestPath, bytes: ByteString(encodingAsUTF8: editor.editedManifest))

        // Write template files.
        try writeTemplateFilesForTarget(newTarget)

        if case .library(name: let name, includeTestTarget: true, dependencyNames: _) = newTarget {
            try self.addTarget(.test(name: "\(name)Tests", dependencyNames: [name]))
        }
    }

    private func writeTemplateFilesForTarget(_ newTarget: NewTarget) throws {
        switch newTarget {
        case .library:
            let targetPath = context.manifestPath.parentDirectory.appending(components: "Sources", newTarget.name)
            if !localFileSystem.exists(targetPath) {
                let file = targetPath.appending(component: "\(newTarget.name).swift")
                try fs.createDirectory(targetPath)
                try fs.writeFileContents(file, bytes: "")
            }
        case .executable:
            let targetPath = context.manifestPath.parentDirectory.appending(components: "Sources", newTarget.name)
            if !localFileSystem.exists(targetPath) {
                let file = targetPath.appending(component: "main.swift")
                try fs.createDirectory(targetPath)
                try fs.writeFileContents(file, bytes: "")
            }
        case .test:
            let testTargetPath = context.manifestPath.parentDirectory.appending(components: "Tests", newTarget.name)
            if !fs.exists(testTargetPath) {
                let file = testTargetPath.appending(components: newTarget.name + ".swift")
                try fs.createDirectory(testTargetPath)
                try fs.writeFileContents(file) {
                    $0 <<< """
                    import XCTest
                    @testable import <#Module#>

                    final class <#TestCase#>: XCTestCase {
                        func testExample() {

                        }
                    }
                    """
                }
            }
        case .binary:
            break
        }
    }

    public func addProduct(name: String, type: ProductType, targets: [String]) throws {
        let manifestPath = context.manifestPath

        // Validate that the package doesn't already contain a product with the same name.
        let loadedManifest = try context.loadManifest(at: manifestPath.parentDirectory)

        guard loadedManifest.toolsVersion >= .v5_2 else {
            throw StringError("mechanical manifest editing operations are only supported for packages with swift-tools-version 5.2 and later")
        }

        if loadedManifest.products.contains(where: { $0.name == name }) {
            throw StringError("a product named '\(name)' already exists")
        }

        let manifestContents = try fs.readFileContents(manifestPath).cString
        let editor = try ManifestRewriter(manifestContents)
        try editor.addProduct(name: name, type: type)


        for target in targets {
            try editor.addProductTarget(product: name, target: target)
        }

        try context.verifyEditedManifest(contents: editor.editedManifest)
        try fs.writeFileContents(manifestPath, bytes: ByteString(encodingAsUTF8: editor.editedManifest))
    }
}

extension Array where Element == TargetDescription.Dependency {
    func containsDependency(_ other: String) -> Bool {
        return self.contains {
            switch $0 {
            case .target(name: let name, condition: _),
                 .product(name: let name, package: _, condition: _),
                 .byName(name: let name, condition: _):
                return name == other
            }
        }
    }
}

/// The types of target.
public enum NewTarget {
    case library(name: String, includeTestTarget: Bool, dependencyNames: [String])
    case executable(name: String, dependencyNames: [String])
    case test(name: String, dependencyNames: [String])
    case binary(name: String, urlOrPath: String, checksum: String?)

    /// The name of the factory method for a target type.
    var factoryMethodName: String {
        switch self {
        case .library, .executable: return "target"
        case .test: return "testTarget"
        case .binary: return "binaryTarget"
        }
    }

    /// The name of the new target.
    var name: String {
        switch self {
        case .library(name: let name, includeTestTarget: _, dependencyNames: _),
             .executable(name: let name, dependencyNames: _),
             .test(name: let name, dependencyNames: _),
             .binary(name: let name, urlOrPath: _, checksum: _):
            return name
        }
    }
}

public enum PackageDependencyRequirement: Equatable {
    case exact(String)
    case revision(String)
    case branch(String)
    case upToNextMajor(String)
    case upToNextMinor(String)
    case localPackage

    var ref: String? {
        switch self {
        case .exact(let ref): return ref
        case .revision(let ref): return ref
        case .branch(let ref): return ref
        case .upToNextMajor(let ref): return ref
        case .upToNextMinor(let ref): return ref
        case .localPackage: return nil
        }
    }
}

extension ProductType {
    var isLibrary: Bool {
        switch self {
        case .library:
            return true
        case .executable, .test:
            return false
        }
    }
}

/// The global context for package editor.
public final class PackageEditorContext {
    /// Path to the package manifest.
    let manifestPath: AbsolutePath

    /// The manifest loader.
    let manifestLoader: ManifestLoaderProtocol

    /// The repository manager.
    let repositoryManager: RepositoryManager

    /// The file system in use.
    let fs: FileSystem

    public init(manifestPath: AbsolutePath,
                repositoryManager: RepositoryManager,
                toolchain: UserToolchain,
                fs: FileSystem = localFileSystem) throws {
        self.manifestPath = manifestPath
        self.repositoryManager = repositoryManager
        self.fs = fs

        self.manifestLoader = ManifestLoader(manifestResources: toolchain.manifestResources)
    }

    func verifyEditedManifest(contents: String) throws {
        do {
            try withTemporaryDirectory {
                let path = $0
                try localFileSystem.writeFileContents(path.appending(component: "Package.swift"),
                                                      bytes: ByteString(encodingAsUTF8: contents))
                _ = try loadManifest(at: path, fs: localFileSystem)
            }
        } catch {
            throw StringError("failed to verify edited manifest: \(error)")
        }
    }

    /// Load the manifest at the given path.
    func loadManifest(
        at path: AbsolutePath,
        fs: FileSystem? = nil
    ) throws -> Manifest {
        let fs = fs ?? self.fs

        let toolsVersion = try ToolsVersionLoader().load(
            at: path, fileSystem: fs)
        return try manifestLoader.load(
            package: path,
            baseURL: path.pathString,
            toolsVersion: toolsVersion,
            packageKind: .local,
            fileSystem: fs
        )
    }
}