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
        // libass (ASS/SSA renderer, MPVKit's static builds) and what it links against.
        .binaryTarget(name: "Libass", url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libass.xcframework.zip", checksum: "3f4c576d2818ceb4544aa2a20e1f55846511c5e706fd19adc3ea9fd842270498"),
        .binaryTarget(name: "Libfreetype", url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfreetype.xcframework.zip", checksum: "496ca62488530e14b1e4624d20ee2b237c0bd675cd70c19da578a5768302d02d"),
        .binaryTarget(name: "Libfribidi", url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfribidi.xcframework.zip", checksum: "bc15e097b892f2f90424e4a27ba287070cc2f98a74a4da10e6d2481d15cf5ff9"),
        .binaryTarget(name: "Libharfbuzz", url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libharfbuzz.xcframework.zip", checksum: "aa8e0b9ca0387dac74e3e93c86e34d11982bb013b28022d0e6966a8427a35b2e"),
        .binaryTarget(name: "Libunibreak", url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libunibreak.xcframework.zip", checksum: "940d9833cf4477d0a260d9f2b4066125bc0ff7bbc111ac3c90e774765b77a559"),
        .target(name: "AnimeRollKit",
                dependencies: ["Libass", "Libfreetype", "Libfribidi", "Libharfbuzz", "Libunibreak"],
                resources: [.copy("Resources/Fonts")],
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedFramework("CoreText"), .linkedFramework("CoreFoundation"), .linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv"), .linkedLibrary("c++")]),
        .testTarget(name: "AnimeRollKitTests", dependencies: ["AnimeRollKit"]),
    ]
)
