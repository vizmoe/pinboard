// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pinboard",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0")
    ],
    targets: [
        .target(name: "SafeImageDownload", linkerSettings: [.linkedLibrary("curl")]),
        .target(
            name: "PinboardKit",
            dependencies: [
                "SafeImageDownload",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ],
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
