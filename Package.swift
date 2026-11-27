// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LuisCanSpeak",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Parakeet speech-to-text on the Neural Engine. traits: [] leaves out
        // FluidAudio's text-to-speech and speaker-separation parts.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "LuisCanSpeak",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/LuisCanSpeak",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
