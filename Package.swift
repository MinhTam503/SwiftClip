// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SwiftClip", defaultLocalization: "en", platforms: [.macOS(.v13)],
  products: [.executable(name: "SwiftClip", targets: ["SwiftClip"])],
  targets: [
    .executableTarget(
      name: "SwiftClip", resources: [.process("Resources")],
      linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "SwiftClipTests", dependencies: ["SwiftClip"]),
  ])
