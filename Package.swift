// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapsTalk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CapsTalk", targets: ["CapsTalk"])],
    targets: [
        .executableTarget(name: "CapsTalk")
    ]
)
