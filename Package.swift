// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CVMControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CVMControl", path: "Sources/CVMControl")
    ]
)
