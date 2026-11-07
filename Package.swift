// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nox",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "nox", path: "Sources/nox")
    ],
    swiftLanguageVersions: [.v5]
)
