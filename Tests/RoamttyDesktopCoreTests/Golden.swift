import Foundation
import XCTest

/// The plugin's golden samples, copied from roamtty #218 desktop-core/src/test/resources/desktop-proto.
enum Golden {
    static func bytes(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        let url = URL(fileURLWithPath: name)
        guard let found = Bundle.module.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension,
                                            subdirectory: "desktop-proto"),
              let data = try? Data(contentsOf: found) else {
            XCTFail("missing golden sample \(name)", file: file, line: line)
            return []
        }
        return Array(data)
    }
}

/// A seeded generator so the random tests are the same on every run (java.util.Random's role).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
