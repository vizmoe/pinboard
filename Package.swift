// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pinboard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PinboardKit",
            path: "Sources/PinboardKit"
        ),
        .executableTarget(
            name: "Pinboard",
            dependencies: ["PinboardKit"],
            path: "Sources/PinboardApp"
        ),
        .testTarget(
            name: "PinboardKitTests",
            dependencies: ["PinboardKit"],
            path: "Tests/PinboardKitTests"
        )
    ]
)
