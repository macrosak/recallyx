// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Recallyx",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Recallyx",
            path: "Sources/Recallyx",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "RecallyxTests",
            dependencies: ["Recallyx"],
            path: "Tests/RecallyxTests"
        )
    ]
)
