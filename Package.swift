// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AgentKit",
            targets: ["AgentKit"]
        ),
    ],
    targets: [
        .target(
            name: "AgentKit"
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"]
        ),
    ]
)
