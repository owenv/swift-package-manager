// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "SourceLibraryTargets",
    products: [
        .executable(name: "Tool", targets: ["Tool"]),
    ],
    targets: [
        .target(name: "StaticLibCore"),
        .target(name: "DynamicLibCore"),
        .library(
            name: "StaticLib",
            type: .static,
            dependencies: ["StaticLibCore"]
        ),
        .library(
            name: "DynamicLib",
            type: .dynamic,
            dependencies: ["DynamicLibCore"]
        ),
        .library(
            name: "AutoLib"
        ),
        .executable(
            name: "Tool",
            dependencies: ["StaticLib", "DynamicLib", "AutoLib"]
        ),
    ]
)
