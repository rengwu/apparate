// swift-tools-version: 6.4
import PackageDescription
import Foundation

let testing = ProcessInfo.processInfo.environment["APPARATE_BUILD_TESTING"] == "1"
let appDrivers = ["TestProfile.swift", "AppTestDiagnostics.swift", "FullPerformance.swift",
                  "PanelVerification.swift", "PerformanceVerification.swift", "SettingsVerification.swift"]

let package = Package(
    name: "Apparate",
    platforms: [.macOS(.v27)],
    products: [.library(name: "ApparateCore", targets: ["ApparateCore"])],
    targets: [
        .target(name: "ApparateCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ApparateFixtures", dependencies: ["ApparateCore"], path: "Tests/Fixtures"),
        .executableTarget(name: "Apparate", dependencies: testing ? ["ApparateCore", "ApparateFixtures"] : ["ApparateCore"],
                          exclude: testing ? [] : appDrivers,
                          swiftSettings: testing ? [.define("APPARATE_TESTING")] : []),
        .executableTarget(name: "ApparateObserver", dependencies: ["ApparateCore"]),
        .executableTarget(name: "ApparateUpgradeCheck", dependencies: ["ApparateCore"], path: "Tests/UpgradeCheck"),
        .executableTarget(name: "ApparateCoreTests", dependencies: ["ApparateCore", "ApparateFixtures"], path: "Tests/ApparateCoreTests")
    ]
)
