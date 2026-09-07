// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MapperCore", platforms: [.macOS(.v14)], products: [.library(name: "MapperCore", targets: ["MapperCore"])], targets: [.target(name: "MapperCore", path: "ios/wifi mapper/Core"), .testTarget(name: "MapperCoreTests", dependencies: ["MapperCore"], path: "ios/wifi mapperTests")])
