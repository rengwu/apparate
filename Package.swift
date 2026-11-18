// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Apparate",
    platforms: [.macOS(.v27)],
    products: [.library(name: "ApparateCore", targets: ["ApparateCore"])],
    targets: [
        .target(name: "ApparateCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Apparate", dependencies: ["ApparateCore"]),
        .executableTarget(name: "ApparateCoreTests", dependencies: ["ApparateCore"], path: "Tests/ApparateCoreTests")
    ]
)
