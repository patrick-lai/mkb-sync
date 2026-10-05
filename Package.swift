// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MKBSync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MKBSync", targets: ["MKBSync"]),
        .library(name: "MKBCore", targets: ["MKBCore"]),
    ],
    targets: [
        // Platform-independent logic: geometry, layout, cursor routing, wire protocol, policy.
        .target(name: "MKBCore"),
        // The macOS menu bar app: discovery, networking, input capture/injection, UI.
        .executableTarget(
            name: "MKBSync",
            dependencies: ["MKBCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "MKBCoreTests", dependencies: ["MKBCore"]),
    ]
)
