// swift-tools-version:5.9
// The Swift side of the device protocol (docs/protocol.md), for the Mac and
// iPad apps. The TypeScript side is the npm package in src/.
import PackageDescription

let package = Package(
    name: "GanymedeDevice",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "DeviceBridge", targets: ["DeviceBridge"]),
    ],
    targets: [
        .target(name: "DeviceBridge", path: "swift/Sources/DeviceBridge"),
        .testTarget(name: "DeviceBridgeTests", dependencies: ["DeviceBridge"], path: "swift/Tests/DeviceBridgeTests"),
    ]
)
