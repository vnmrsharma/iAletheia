// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iAletheia",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iAletheia", targets: ["iAletheia"])
    ],
    targets: [
        .executableTarget(
            name: "iAletheia",
            path: "Sources/iAletheia",
            exclude: ["Resources/Info.plist"],
            resources: [.process("Resources")]
        )
    ]
)
