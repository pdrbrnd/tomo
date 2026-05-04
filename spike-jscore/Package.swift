// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JSCoreSpike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "JSCoreSpike",
            dependencies: ["SwiftSoup"]
        )
    ]
)
