// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "InstallBundle",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "install-bundle", targets: ["InstallBundle"])],
    targets: [
        .executableTarget(name: "InstallBundle"),
        .testTarget(name: "InstallBundleTests", dependencies: ["InstallBundle"])
    ]
)
