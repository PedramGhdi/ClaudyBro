// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudyBro",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudyBro",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
