// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "PackageVisibleRoot",
    dependencies: [
        .package(path: "../Dep"),
    ],
    targets: [
        .executable(
            name: "Tool",
            dependencies: [
                .target(name: "PackageOnly", package: "Dep"),
            ]
        ),
    ]
)
