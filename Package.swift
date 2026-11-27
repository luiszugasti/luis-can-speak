// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LuisCanSpeak",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "LuisCanSpeak",
            path: "Sources/LuisCanSpeak",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
