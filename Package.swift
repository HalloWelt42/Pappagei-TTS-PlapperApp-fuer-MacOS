// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pappagei",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "pappagei",
            path: "Sources/pappagei",
            // Swift 5 language mode: relaxed concurrency for AppKit/SwiftUI glue.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
