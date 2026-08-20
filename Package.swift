// swift-tools-version:6.2
import PackageDescription

/// Command Line Tools only — no Xcode. Two consequences are baked in below.
///
/// 1. The Swift Testing runtime ships with the CLT but is not on any default
///    search path, so the test target needs the macro plugin directory and two
///    rpaths spelled out. Without them `swift test` builds and then dies in
///    `dlopen`.
/// 2. SwiftUI's `@State` is an Xcode-only macro in this SDK. Nothing here can
///    enforce that; see `MonitorStore.shared` and STRATEGY.md §5.
let cltDeveloper = "/Library/Developer/CommandLineTools/Library/Developer"
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

let package = Package(
    name: "Conduit",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Conduit", targets: ["Conduit"])
    ],
    targets: [
        .executableTarget(
            name: "Conduit",
            path: "Sources/Conduit",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "ConduitTests",
            dependencies: ["Conduit"],
            path: "Tests/ConduitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-plugin-path", cltTestingPlugins])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "\(cltDeveloper)/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "\(cltDeveloper)/usr/lib"
                ])
            ]
        )
    ]
)
