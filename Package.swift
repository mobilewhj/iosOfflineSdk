// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "OfflineTool",
    platforms: [.iOS(.v12)],
    products: [.library(name: "OfflineTool", targets: ["OfflineTool"])],
    targets: [
        .binaryTarget(
            name: "OfflineTool",
            url: "https://github.com/mobilewhj/iosOfflineSdk/releases/download/v0.2.0/OfflineTool-0.2.0.xcframework.zip",
            checksum: "b8a4bcc96b1091c8ebfacf2ef6d3e6cf9d2e980278d1dc0e90f0d7dca42f2a98"
        )
    ]
)
