// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentsIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentsIsland",
            path: "Sources/AgentsIsland",
            resources: [.copy("Resources/agents")]
        )
    ]
)
