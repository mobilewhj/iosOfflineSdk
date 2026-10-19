// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "OfflineTool",
    platforms: [.iOS(.v15)],
    products: [.library(name: "OfflineTool", targets: ["OfflineTool"])],
    targets: [
        .binaryTarget(
            name: "OfflineTool",
            url: "https://github.com/mobilewhj/iosOfflineSdk/releases/download/v0.3.1/OfflineTool-0.3.1.xcframework.zip",
            checksum: "524cafcf4dbeadc33d92dfdbf84b159ef698ff9521d19a6c83bf5b4d16c88e35"
        )
    ]
)
