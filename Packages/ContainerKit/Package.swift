// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContainerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContainerKit", targets: ["ContainerKit"])
    ],
    targets: [
        .target(name: "ContainerKit"),
        .testTarget(
            name: "ContainerKitTests",
            dependencies: ["ContainerKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
