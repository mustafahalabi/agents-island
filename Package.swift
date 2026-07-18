// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentsIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The app's only dependency, and a deliberate exception to the
        // otherwise dependency-free rule: an auto-updater installs code, so
        // its signature checking is worth taking from an audited
        // implementation rather than hand-rolling. See CONTRIBUTING.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "AgentsIsland",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AgentsIsland",
            resources: [.copy("Resources/agents")]
        )
    ]
)
