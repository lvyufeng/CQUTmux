// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CQUTTransport",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CQUTTransport", targets: ["CQUTTransport"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.60.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CQUTTransport",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)