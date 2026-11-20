// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CountYoTokens",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CountYoTokens", targets: ["CountYoTokens"]),
        .executable(name: "tokbench", targets: ["tokbench"]),
    ],
    targets: [
        .target(name: "TokenCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CountYoTokens", dependencies: ["TokenCore"]),
        .executableTarget(name: "tokbench", dependencies: ["TokenCore"]),
    ])
