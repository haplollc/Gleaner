// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gleaner",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Gleaner", targets: ["Gleaner"]),
        .executable(name: "gleaner-demo", targets: ["GleanerDemo"]),
    ],
    targets: [
        .target(name: "Gleaner"),
        .executableTarget(name: "GleanerDemo", dependencies: ["Gleaner"]),
        .testTarget(name: "GleanerTests", dependencies: ["Gleaner"]),
    ],
    swiftLanguageModes: [.v6]
)
