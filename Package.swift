// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "exoshelf",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ExoShelf", targets: ["ExoShelf"]),
        .executable(name: "exoshelf-cli", targets: ["exoshelf-cli"]),
        .library(name: "ExoShelfCore", targets: ["ExoShelfCore"]),
    ],
    targets: [
        .target(name: "ExoShelfCore"),
        .executableTarget(name: "ExoShelf", dependencies: ["ExoShelfCore"]),
        .executableTarget(name: "exoshelf-cli", dependencies: ["ExoShelfCore"]),
        .testTarget(name: "ExoShelfCoreTests", dependencies: ["ExoShelfCore"]),
    ]
)
