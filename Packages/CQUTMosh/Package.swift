// swift-tools-version:6.0
import PackageDescription

// The C driver that fronts mosh's client libraries. It has no Swift in it and
// no Swift dependencies — mosh itself is supplied as a prebuilt static archive
// (see scripts/mosh-ios/), linked in by the app target rather than declared
// here, because it is not a SwiftPM product.
let package = Package(
    name: "CQUTMosh",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "CQUTMosh", targets: ["CQUTMosh"])
    ],
    dependencies: [
        .package(path: "../CQUTTransport")
    ],
    targets: [
        // Header-only: the implementation lives in the prebuilt
        // Vendor/moshclient/libmoshclient.a, because compiling it needs mosh's
        // source tree and protobuf's headers, which only scripts/mosh-ios/ has.
        .target(
            name: "CQUTMoshC",
            path: "Sources/CQUTMoshC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CQUTMosh",
            dependencies: ["CQUTMoshC", .product(name: "CQUTTransport", package: "CQUTTransport")],
            path: "Sources/CQUTMosh"
        )
    ],
    swiftLanguageModes: [.v5]
)