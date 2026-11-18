// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Apparate",
    platforms: [.macOS(.v27)],
    products: [.library(name: "ApparateCore", targets: ["ApparateCore"])],
    targets: [
        .target(name: "ApparateCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ApparateFixtures", dependencies: ["ApparateCore"], path: "Tests/Fixtures"),
        .executableTarget(name: "Apparate", dependencies: ["ApparateCore", "ApparateFixtures"]),
        .executableTarget(name: "ApparateObserver", dependencies: ["ApparateCore"]),
        .executableTarget(name: "ApparateCoreTests", dependencies: ["ApparateCore", "ApparateFixtures"], path: "Tests/ApparateCoreTests")
    ]
)
