// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AntonNotes", platforms: [.macOS(.v15)], products: [.executable(name: "AntonNotes", targets: ["AntonNotes"])], dependencies: [.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.9.4")], targets: [.executableTarget(name: "AntonNotes", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")], swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "AntonNotesTests", dependencies: ["AntonNotes"])])
