// swift-tools-version:6.0
import PackageDescription

// The C driver that fronts Eternal Terminal's client core. It has no Swift in
// it and no Swift dependencies — ET itself is supplied as a prebuilt static
// archive (see scripts/et-ios/), linked in by the app target rather than
// declared here, because it is not a SwiftPM product.
let package = Package(
    name: "CQUTET",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "CQUTET", targets: ["CQUTET"])
    ],
    dependencies: [
        .package(path: "../CQUTTransport")
    ],
    targets: [
        // Header-only: the implementation lives in the prebuilt
        // Vendor/etclient/libetcore.a, because compiling it needs ET's source
        // tree, protobuf's headers and a working libsodium, which only
        // scripts/et-ios/ has.
        .target(
            name: "CQUTETC",
            path: "Sources/CQUTETC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CQUTET",
            dependencies: ["CQUTETC", .product(name: "CQUTTransport", package: "CQUTTransport")],
            path: "Sources/CQUTET"
        )
    ],
    swiftLanguageModes: [.v5]
)