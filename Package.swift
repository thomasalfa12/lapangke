// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lapangke",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lapangke", targets: ["Lapangke"]),
    ],
    targets: [
        .target(name: "LapangkeCore"),
        .executableTarget(name: "Lapangke", dependencies: ["LapangkeCore"]),
        .testTarget(name: "LapangkeCoreTests", dependencies: ["LapangkeCore"]),
    ]
)
