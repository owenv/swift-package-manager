// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "AggregateLibraryTargets",
    products: [
        .executable(name: "Tool", targets: ["Tool"]),
    ],
    targets: [
        .target(name: "StaticMember"),
        .library(
            name: "StaticAggregate",
            type: .static,
            dependencies: ["StaticMember"]
        ),
        .target(name: "DynamicMember"),
        .library(
            name: "DynamicAggregate",
            type: .dynamic,
            dependencies: ["DynamicMember"]
        ),
        .target(name: "AutoMember"),
        .library(
            name: "AutoAggregate",
            dependencies: ["AutoMember"]
        ),
        .executable(
            name: "Tool",
            dependencies: ["StaticAggregate", "DynamicAggregate", "AutoAggregate"]
        ),
    ]
)
