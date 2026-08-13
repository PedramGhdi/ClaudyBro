// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudyBro",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Package.resolved is committed, so this floor plus the lockfile give
        // reproducible builds. Bump deliberately via `swift package update`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.18.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudyBro",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
