// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Paster", platforms: [.macOS(.v14)], products: [.executable(name: "Paster", targets: ["Paster"])], targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .executableTarget(name: "Paster", dependencies: ["CSQLite"]),
    .testTarget(name: "PasterTests", dependencies: ["Paster"])
], swiftLanguageModes: [.v6])
