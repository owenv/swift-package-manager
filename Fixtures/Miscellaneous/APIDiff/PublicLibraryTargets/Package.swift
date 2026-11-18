// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "PublicLibraryTargets",
    targets: [
        .library(name: "One", dependencies: ["Foo"], visibility: .public),
        .library(name: "Two", dependencies: ["Bar", "Baz"], visibility: .public),
        .library(name: "Quux", type: .static, visibility: .public),
        .target(name: "Foo"),
        .target(name: "Bar", dependencies: ["Baz"]),
        .target(name: "Baz"),
        .target(name: "Qux"),
        .executable(name: "Exec", dependencies: ["Qux"])
    ]
)
