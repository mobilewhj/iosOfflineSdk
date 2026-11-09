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
            checksum: "d75250af56a9c5c122672420c3729858af9b58996102bc313aa4affdc2a1fc9d"
        )
    ]
)
