// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QUICSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "QUICSwift",
            targets: ["QUICSwift"]
        ),
        .executable(
            name: "QUICServer",
            targets: ["QUICServer"]
        ),
        .executable(
            name: "QUICClient", 
            targets: ["QUICClient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "QUICSwift",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "QUICServer",
            dependencies: ["QUICSwift"]
        ),
        .executableTarget(
            name: "QUICClient",
            dependencies: ["QUICSwift"]
        ),
        .testTarget(
            name: "QUICSwiftTests",
            dependencies: ["QUICSwift"]
        )
    ]
)