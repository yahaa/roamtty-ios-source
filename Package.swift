// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
#if os(macOS)
let nativeC: [CSetting] = [.headerSearchPath("../../Vendor/macosx/include")]
let nativeSwift: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I" + root + "/Vendor/macosx/include"])]
let nativeLink: [LinkerSetting] = [.unsafeFlags(["-L" + root + "/Vendor/macosx/lib"])]
#else
let nativeC: [CSetting] = [.headerSearchPath("../../Vendor/linux/include")]
let nativeSwift: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I" + root + "/Vendor/linux/include"])]
let nativeLink: [LinkerSetting] = [.unsafeFlags(["-L" + root + "/Vendor/linux/lib"])]
#endif
// The remote desktop core uses CryptoKit on Apple platforms and its open-source twin swift-crypto elsewhere.
#if os(Linux)
let desktopDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")]
let desktopCrypto: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let desktopDependencies: [Package.Dependency] = []
let desktopCrypto: [Target.Dependency] = []
#endif
let package = Package(
    name: "Roamtty",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RoamttyCore", targets: ["RoamttyCore"]),
        .library(name: "RoamttyTransport", targets: ["RoamttyTransport"]),
        .library(name: "RoamttyDesktopCore", targets: ["RoamttyDesktopCore"])
    ],
    dependencies: desktopDependencies,
    targets: [
        .target(name: "CNative", publicHeadersPath: "include", cSettings: nativeC, linkerSettings: nativeLink + [
            .linkedLibrary("ssh2"), .linkedLibrary("crypto"), .linkedLibrary("z"), .linkedLibrary("sqlite3")
        ]),
        .target(name: "RoamttyCore", dependencies: ["CNative"], resources: [.process("Resources")], swiftSettings: nativeSwift),
        .target(name: "RoamttyTransport", dependencies: ["RoamttyCore", "CNative", "RoamttyDesktopCore"], swiftSettings: nativeSwift),
        .target(name: "RoamttyDesktopCore", dependencies: desktopCrypto, resources: [.copy("Resources/desktop-plugin.json")]),
        .testTarget(name: "RoamttyCoreTests", dependencies: ["RoamttyCore"], swiftSettings: nativeSwift),
        .testTarget(name: "RoamttyTransportTests", dependencies: ["RoamttyTransport", "RoamttyDesktopCore"], swiftSettings: nativeSwift),
        .testTarget(name: "RoamttyDesktopCoreTests", dependencies: ["RoamttyDesktopCore"], resources: [.copy("Resources/desktop-proto")])
    ],
    swiftLanguageModes: [.v5]
)
