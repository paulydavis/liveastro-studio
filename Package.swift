// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveAstroStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveAstroCore", targets: ["LiveAstroCore"]),
    ],
    targets: [
        .target(name: "LiveAstroCore"),
        .executableTarget(name: "LiveAstroStudio", dependencies: ["LiveAstroCore"]),
        .executableTarget(name: "fakesiril", dependencies: ["LiveAstroCore"]),
        .testTarget(name: "LiveAstroCoreTests", dependencies: ["LiveAstroCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
