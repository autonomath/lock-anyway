// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IdleLock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IdleLockCore", targets: ["IdleLockCore"]),
        .executable(name: "IdleLock", targets: ["IdleLock"]),
        .executable(name: "IdleLockSelfTest", targets: ["IdleLockSelfTest"])
    ],
    targets: [
        .target(
            name: "IdleLockCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "IdleLock",
            dependencies: ["IdleLockCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "IdleLockSelfTest",
            dependencies: ["IdleLockCore"],
            path: "Tests/IdleLockSelfTest",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
