// swift-tools-version: 6.0
import PackageDescription

/// Shared code for the iOS and tvOS apps: API models, networking, login (password + passkey),
/// AniList, offline downloads and playback progress.
let package = Package(
    name: "AnimeRollKit",
    defaultLocalization: "it",
    platforms: [.iOS(.v18), .tvOS(.v18)],
    products: [.library(name: "AnimeRollKit", targets: ["AnimeRollKit"])],
    targets: [
        .target(name: "AnimeRollKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AnimeRollKitTests", dependencies: ["AnimeRollKit"]),
    ]
)
