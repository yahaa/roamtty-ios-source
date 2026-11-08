// swift-tools-version:5.9
// Checks the app's terminal URL finder, cursor taps, wide cell repair and scrollback count against SwiftTerm's real emulator;
// run through scripts/test-terminal-url.sh.
import PackageDescription

let swiftTerm = "https://github.com/yahaa/SwiftTerm.git"
let package = Package(
    name: "TerminalUrlChecks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: swiftTerm, revision: "0a311223749cf1b96294772a2c5478be67915572")],
    targets: [
        .executableTarget(name: "TerminalMemoryChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "TerminalUrlChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "TerminalWideCellChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "TerminalScrollbackChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "TerminalCursorTapChecks", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
