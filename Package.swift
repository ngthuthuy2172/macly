// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Macly",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Macly", path: "Sources")
    ]
)
