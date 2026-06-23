// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Recallyx",
    platforms: [.macOS(.v13)],
    products: [
        // Vended so the (additive, XcodeGen-generated) Xcode app target can
        // depend on the shared library. swift build/test are unaffected.
        .library(name: "RecallyxCore", targets: ["RecallyxCore"])
    ],
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
