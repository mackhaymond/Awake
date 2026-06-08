// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Awake",
            path: "Sources/Awake"
            // The @main file is AwakeApp.swift, NOT main.swift (SPM top-level-code collision).
        )
    ]
)
