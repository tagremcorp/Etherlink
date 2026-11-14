// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "EtherLink", platforms: [.macOS(.v13)], products: [
    .executable(name: "EtherLink", targets: ["EtherLink"])
], targets: [
    .target(name: "LinkCore"),
    .executableTarget(name: "EtherLink", dependencies: ["LinkCore"]),
    .executableTarget(name: "LinkCoreChecks", dependencies: ["LinkCore"], path: "Tests/LinkCoreTests")
])
