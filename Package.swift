// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Recallyx",
    // iOS 26 (string form: the 5.9 tools enum lacks `.v26`). The mac app +
    // `swift test` are unaffected (host build stays macOS); iOS only affects the
    // XcodeGen `RecallyxiOS` target that depends on the RecallyxCore library.
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [
        // Vended so the (additive, XcodeGen-generated) Xcode app target can
        // depend on the shared library. swift build/test are unaffected.
        .library(name: "RecallyxCore", targets: ["RecallyxCore"]),
        // The `recallyx` CLI. Build with
        // `swift build -c release --product recallyx-cli`.
        .executable(name: "recallyx-cli", targets: ["recallyx-cli"])
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
        // The `recallyx` command-line tool (product name `recallyx-cli`; install
        // the binary as `recallyx`). Reuses RecallyxCore; AppKit is linked only
        // for the `copy` command's NSPasteboard write. mac-only.
        .executableTarget(
            name: "recallyx-cli",
            dependencies: ["RecallyxCore"],
            path: "Sources/recallyx-cli"
        ),
        .testTarget(
            name: "RecallyxTests",
            dependencies: ["Recallyx", "RecallyxCore"],
            path: "Tests/RecallyxTests"
        )
    ]
)
