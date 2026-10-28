// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rephrase",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Rephrase",
            path: "Sources/Rephrase",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
