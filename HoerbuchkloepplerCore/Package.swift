// swift-tools-version: 6.0
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
        .library(
            name: "HoerbuchkloepplerAppSupport",
            targets: ["HoerbuchkloepplerAppSupport"]),
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
        .target(
            name: "HoerbuchkloepplerAppSupport",
            dependencies: ["HoerbuchkloepplerCore"]),
        .executableTarget(
            name: "kloeppler",
            dependencies: [
                "HoerbuchkloepplerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]),
        .testTarget(
            name: "HoerbuchkloepplerCoreTests",
            dependencies: ["HoerbuchkloepplerCore"]),
        .testTarget(
            name: "HoerbuchkloepplerAppSupportTests",
            dependencies: ["HoerbuchkloepplerAppSupport", "HoerbuchkloepplerCore"])
    ]
)
