// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Recast",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Recast", targets: ["Recast"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Recast",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Recast",
            exclude: ["Info.plist", "Recast.entitlements"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "RecastTests",
            dependencies: ["Recast"]
        )
    ]
)
