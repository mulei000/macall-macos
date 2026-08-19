// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "macall",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "macall",
            path: "Sources/macall"
        )
    ]
)
