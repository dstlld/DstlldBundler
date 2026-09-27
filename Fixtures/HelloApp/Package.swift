// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HelloApp",
    platforms: [.macOS(.v27)],
    products: [.executable(name: "HelloApp", targets: ["HelloApp"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "HelloApp", swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
