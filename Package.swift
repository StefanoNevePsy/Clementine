// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clementine",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clementine",
            path: "Sources/Clementine"
        )
    ]
)
