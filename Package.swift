// swift-tools-version:5.9
// The Swift side of the device protocol (docs/protocol.md), for the Mac and
// iPad apps. The TypeScript side is the npm package in src/.
import PackageDescription

let package = Package(
    name: "GanymedeDevice",
    // The apps require macOS 26 and iOS 26 (#47). The string form keeps
    // tools 5.9; `.v26` needs 6.2, which also turns on Swift 6 mode.
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "DeviceBridge", targets: ["DeviceBridge"]),
    ],
    targets: [
        .target(name: "DeviceBridge", path: "swift/Sources/DeviceBridge"),
        .testTarget(name: "DeviceBridgeTests", dependencies: ["DeviceBridge"], path: "swift/Tests/DeviceBridgeTests"),
    ]
)
