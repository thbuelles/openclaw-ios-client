// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ios-ui",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .executable(name: "IOSUIApp", targets: ["IOSUIApp"])
    ],
    targets: [
        .executableTarget(
            name: "IOSUIApp",
            path: "Sources/IOSUIApp"
        )
    ]
)
