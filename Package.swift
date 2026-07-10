// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vision-book-digitizer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "vbook", targets: ["vbook"])
    ],
    targets: [
        .executableTarget(
            name: "vbook",
            path: "Sources/vbook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
