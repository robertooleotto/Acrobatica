// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NativePoseMeshViewer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NativePoseMeshViewer", targets: ["NativePoseMeshViewer"])
    ],
    targets: [
        .executableTarget(
            name: "NativePoseMeshViewer",
            path: "Sources/NativePoseMeshViewer"
        )
    ]
)
