// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Pastrix", platforms: [.macOS(.v14)], products: [.executable(name: "Pastrix", targets: ["Pastrix"])], targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .executableTarget(name: "Pastrix", dependencies: ["CSQLite"]),
    .testTarget(name: "PastrixTests", dependencies: ["Pastrix"])
], swiftLanguageModes: [.v6])
