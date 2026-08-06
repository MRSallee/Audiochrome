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
            // AppIcon is copied into the .app by Scripts/package-app.sh (Finder icon).
            exclude: [
                "Resources/AppIcon.icns",
                "Resources/AppIcon-1024.png"
            ],
            resources: [
                .process("Resources/AudiochromeLogo.png"),
                // Keep as a directory so first-launch seeding can find DefaultEQProfiles/*.txt.
                .copy("Resources/DefaultEQProfiles")
            ]
        ),
        .executableTarget(
            name: "AudiochromeSmoke",
            dependencies: ["AudiochromeCore"],
            path: "Sources/AudiochromeSmoke"
        )
    ]
)
