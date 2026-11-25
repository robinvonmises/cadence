// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Cadence",
    defaultLocalization: "de",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "Cadence", targets: ["Cadence"]),
        .library(name: "CadenceCore", targets: ["CadenceCore"])
    ],
    dependencies: [
        // WhisperKit (lokale Transkription) und SpeakerKit (lokale Sprechertrennung) von Argmax.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1")
    ],
    targets: [
        // Plattformunabhängige Logik: Datenmodell, Sprecherzuordnung, Export, Sprachabschnitt-Erkennung.
        // Bewusst ohne Apple-Frameworks, damit sie überall getestet werden kann.
        .target(
            name: "CadenceCore",
            path: "Sources/CadenceCore"
        ),
        .executableTarget(
            name: "Cadence",
            dependencies: [
                "CadenceCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit")
            ],
            path: "Sources/Cadence"
        ),
        .testTarget(
            name: "CadenceCoreTests",
            dependencies: ["CadenceCore"],
            path: "Tests/CadenceCoreTests"
        )
    ]
)
