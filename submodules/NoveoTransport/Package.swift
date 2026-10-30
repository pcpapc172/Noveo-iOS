// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NoveoTransport", platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "NoveoTransport", targets: ["NoveoTransport"])],
    targets: [.target(name: "NoveoTransport"), .testTarget(name: "NoveoTransportTests", dependencies: ["NoveoTransport"])])
