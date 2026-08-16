// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aria",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Aria",
            path: "Sources/Aria",
            // Only the Xcode/iOS build consumes the asset catalog; SwiftPM would
            // otherwise error on it as an unhandled resource.
            exclude: ["Assets.xcassets"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
