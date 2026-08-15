// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notifly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notifly",
            path: "Sources/Notifly",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
