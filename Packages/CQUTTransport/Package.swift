// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CQUTTransport",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CQUTTransport", targets: ["CQUTTransport"])
    ],
    dependencies: [
        // A vendored copy of swift-nio-ssh, not the upstream URL. It carries
        // one addition — the `auth-agent-req@openssh.com` channel request and
        // an event to send it — which is what SSH agent forwarding is made of.
        // Upstream does not model the request, and the child-channel request
        // path is internal, so this cannot be done from outside the package.
        // The patch is five small edits; see Packages/ThirdParty/README.md.
        .package(path: "../ThirdParty/swift-nio-ssh"),
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
        ),
        // Two checks, because the agent has two halves that fail differently.
        // The protocol one is pure byte-shuffling and needs no server; the
        // forwarding one needs a real sshd, because the thing being tested is
        // whether a server's agent channel reaches us and whether a program on
        // the host can use what it finds there.
        .executableTarget(
            name: "SSHAgentChecks",
            dependencies: ["CQUTTransport"],
            path: "Tests/SSHAgentChecks"
        ),
        .executableTarget(
            name: "AgentForwardingChecks",
            dependencies: [
                "CQUTTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/AgentForwardingChecks"
        )
    ],
    swiftLanguageModes: [.v5]
)