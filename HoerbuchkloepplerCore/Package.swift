// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoerbuchkloepplerCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "HoerbuchkloepplerCore",
            targets: ["HoerbuchkloepplerCore"]),
        .executable(
            name: "kloeppler",
            targets: ["kloeppler"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "HoerbuchkloepplerCore",
            dependencies: [],
            resources: [.copy("Resources/bin")]),
        .executableTarget(
            name: "kloeppler",
            dependencies: [
                "HoerbuchkloepplerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]),
        .testTarget(
            name: "HoerbuchkloepplerCoreTests",
            dependencies: ["HoerbuchkloepplerCore"])
    ]
)
