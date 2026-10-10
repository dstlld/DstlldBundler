// swift-tools-version: 6.2
//
//  Package.swift
//  DstlldBundler
//
//  Turns a SwiftPM executable into a signed macOS `.app`. Three layers, because a plugin cannot
//  import a library:
//
//    DstlldBundlerCore — the logic: Info.plist, entitlements, bundle layout, codesign. Testable.
//    dstlld-bundler    — a small tool wrapping the core, which the plugin runs.
//    BundleApp         — the `bundle-app` command plugin: `swift package bundle-app --product MyApp`.
//    ExportApp         — the `export-app` command plugin, which makes a signed, notarized disk image:
//                        `swift package --disable-sandbox export-app --product MyApp`.
//
//  The contract with a project is the `App/<Product>/` folder. See README.md.
//

import PackageDescription

let package = Package(
    name: "DstlldBundler",
    platforms: [.macOS(.v13)],
    products: [
        .plugin(name: "BundleApp", targets: ["BundleApp"]),
        .plugin(name: "ExportApp", targets: ["ExportApp"]),
        .library(name: "DstlldBundlerCore", targets: ["DstlldBundlerCore"]),
    ],
    targets: [
        .target(
            name: "DstlldBundlerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "dstlld-bundler",
            dependencies: ["DstlldBundlerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .plugin(
            name: "BundleApp",
            capability: .command(
                intent: .custom(
                    verb: "bundle-app",
                    description: "Build an executable product and wrap it in a signed macOS .app"
                )
            ),
            dependencies: ["dstlld-bundler"]
        ),
        .plugin(
            name: "ExportApp",
            capability: .command(
                intent: .custom(
                    verb: "export-app",
                    description: "Build a release of an app, sign and notarize it, and put it on a disk image"
                )
            ),
            dependencies: ["dstlld-bundler"]
        ),
        .testTarget(
            name: "DstlldBundlerCoreTests",
            dependencies: ["DstlldBundlerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
