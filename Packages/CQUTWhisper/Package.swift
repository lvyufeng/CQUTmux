// swift-tools-version:6.0
import PackageDescription

// On-device speech-to-text via whisper.cpp.
//
// The codec is not compiled here. It arrives as the prebuilt archives in
// Vendor/whisper/, linked in by the app target, because building it needs
// whisper.cpp's own source tree, its ggml submodule and a CMake invoke that
// scripts/whisper-ios/build.sh performs. This package is the seam: a C shim
// that keeps the app out of whisper.cpp's struct layouts, and the Swift that
// drives it.
let package = Package(
    name: "CQUTWhisper",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CQUTWhisper", targets: ["CQUTWhisper"])
    ],
    targets: [
        // Header-only, like CQUTETC and CQUTMoshC: whisper_shim.h declares the
        // seam and whisper_shim.c's implementation is compiled into
        // Vendor/whisper/<platform>/libwhisperclient.a by scripts/whisper-ios/,
        // because it needs whisper.h and ggml's headers and SwiftPM will not
        // accept a header search path outside the package root.
        .target(
            name: "CQUTWhisperC",
            path: "Sources/CQUTWhisperC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CQUTWhisper",
            dependencies: ["CQUTWhisperC"],
            path: "Sources/CQUTWhisper"
        )
    ],
    swiftLanguageModes: [.v5]
)