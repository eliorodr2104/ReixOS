// swift-tools-version: 6.3
//
//  Package.swift
//  ReixOS
//
//  The build front end. A package of its own, deliberately: declaring the
//  SwiftTUI dependency in the root manifest makes SwiftPM warn on every cross
//  build, because FREESTANDING=1 removes the host targets that would consume
//  it. Here the kernel's build graph never resolves it at all.

import PackageDescription

let package = Package(
    name: "reix",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "reix", targets: ["reix"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SwiftTUI/swift-tui.git", from: "0.13.2"),
    ],
    targets: [
        // The pipeline. No terminal, no SwiftTUI, so it is testable on its own.
        .target(name: "ReixBuild"),

        .executableTarget(
            name: "reix",
            dependencies: [
                "ReixBuild",
                .product(name: "SwiftTUI", package: "swift-tui"),
                .product(name: "SwiftTUICLI", package: "swift-tui"),
            ]
        ),

        .testTarget(name: "ReixBuildTests", dependencies: ["ReixBuild"]),
    ]
)
