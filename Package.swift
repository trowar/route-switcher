// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcessRoute",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProcessRoute", targets: ["ProcessRoute"])
    ],
    targets: [
        .executableTarget(
            name: "ProcessRoute",
            path: "Sources"
        )
    ]
)
