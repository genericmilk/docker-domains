// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockerDomains",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DockerDomains", targets: ["DockerDomains"])],
    targets: [
        .target(name: "DomainCore"),
        .executableTarget(name: "DockerDomains", dependencies: ["DomainCore"]),
        .testTarget(name: "DomainCoreTests", dependencies: ["DomainCore"])
    ]
)
