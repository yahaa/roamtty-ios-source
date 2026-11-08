import Foundation

extension NSRegularExpression {
    /// A pattern written in the source. A typo in it is a programming error the tests catch, not a condition to handle.
    public convenience init(literal pattern: String, options: Options = []) {
        // swiftlint:disable:next force_try
        try! self.init(pattern: pattern, options: options)
    }
}
