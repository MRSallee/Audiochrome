// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Audiochrome",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Audiochrome", targets: ["Audiochrome"]),
        .executable(name: "AudiochromeSmoke", targets: ["AudiochromeSmoke"]),
        .library(name: "AudiochromeCore", targets: ["AudiochromeCore"])
    ],
    targets: [
        .target(
            name: "AudiochromeCore",
            path: "Sources/AudiochromeCore"
        ),
        .executableTarget(
            name: "Audiochrome",
            dependencies: ["AudiochromeCore"],
            path: "Sources/Audiochrome",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AudiochromeSmoke",
            dependencies: ["AudiochromeCore"],
            path: "Sources/AudiochromeSmoke"
        )
    ]
)
