// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Recallyx",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RecallyxCore",
            path: "Sources/RecallyxCore"
        ),
        .executableTarget(
            name: "Recallyx",
            dependencies: ["RecallyxCore"],
            path: "Sources/Recallyx",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "RecallyxTests",
            dependencies: ["Recallyx", "RecallyxCore"],
            path: "Tests/RecallyxTests"
        )
    ]
)
