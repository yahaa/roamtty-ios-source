// Adapted from the earlier Roamtty/iTermux Swift port of Android MarkdownParser.kt.
import Foundation

/// Resolve a document image lexically, without requiring intermediate directories to exist.
/// Query/fragment metadata is not part of the SFTP filename; encoded filename bytes stay intact.
public func resolveRelativeRemotePath(directory: String, source: String) -> String {
    let clean = source.prefix { $0 != "#" }.prefix { $0 != "?" }
    let absolute = clean.hasPrefix("/") || directory.hasPrefix("/")
    let joined = clean.hasPrefix("/") ? String(clean) : directory + "/" + clean
    var segments: [Substring] = []
    for segment in joined.split(separator: "/") {
        switch segment {
        case ".": continue
        case "..": if !segments.isEmpty { segments.removeLast() }
        default: segments.append(segment)
        }
    }
    return (absolute ? "/" : "") + segments.joined(separator: "/")
}

/// Android permits explicit web/mail links only. Other destinations are styled but inert.
public func markdownExternalURL(_ source: String) -> URL? {
    guard isMarkdownExternalLink(source) else { return nil }
    return URL(string: source)
}

private func isMarkdownExternalLink(_ source: String) -> Bool {
    source.hasPrefix("https://") || source.hasPrefix("http://") || source.hasPrefix("mailto:")
}

/// Web/mail/data references remain placeholders, including malformed URLs. Every other string
/// is a filename on the existing SSH host, never a URL to fetch or a local-device file to open.
public func markdownRemoteImagePath(directory: String, source: String) -> String? {
    guard !isMarkdownExternalLink(source), !source.hasPrefix("data:") else { return nil }
    return resolveRelativeRemotePath(directory: directory, source: source)
}

public enum MdStyle: String, Sendable { case bold, italic, strike, code, link, image }
public struct MdSpan: Equatable, Sendable { public var start: Int; public var end: Int; public var style: MdStyle; public var url: String? }
public struct MdText: Equatable, Sendable { public var text: String; public var spans: [MdSpan] }
public enum MdAlign: Equatable, Sendable { case start, center, end }

public enum MdBlock: Equatable, Sendable {
    case heading(Int, MdText)
    case paragraph(MdText)
    case code(String, String)
    case quote([MdBlock])
    case listItem(depth: Int, marker: String, checked: Bool?, text: MdText)
    case table(header: [MdText], alignments: [MdAlign], rows: [[MdText]])
    case image(String, String)
    case rule
}

public enum MarkdownParser {
    public static func parse(_ source: String) -> [MdBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var references: [String: String] = [:]
        let reference = NSRegularExpression(literal: #"^ {0,3}\[([^\]]+)]:\s*<?(\S+?)>?(?:\s+["'(].*["')])?\s*$"#)
        let content = lines.filter { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = reference.firstMatch(in: line, range: range), match.range.length == range.length,
                  let key = Range(match.range(at: 1), in: line), let url = Range(match.range(at: 2), in: line) else { return true }
            let name = line[key].lowercased()
            if references[name] == nil { references[name] = String(line[url]) }
            return false
        }
        return Parser(content, InlineParser(references)).blocks()
    }

    private final class Parser {
        let lines: [String]
        let inline: InlineParser
        var index = 0
        var out: [MdBlock] = []
        var listIndents: [Int] = []
        init(_ lines: [String], _ inline: InlineParser) { self.lines = lines; self.inline = inline }
        func blocks() -> [MdBlock] { while index < lines.count { block() }; return out }

        func startsBlock(_ line: String) -> Bool {
            whole(line, #"^ {0,3}(`{3,}|~{3,})\s*([^`]*)$"#) != nil || whole(line, #"^ {0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*$"#) != nil
                || whole(line, #"^ {0,3}([-*_])(\s*\1){2,}\s*$"#) != nil || line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
                || (whole(line, #"^(\s*)([-*+]|\d{1,9}[.)])(?:\s+(.*))?$"#) != nil && !(group(line, #"^(\s*)([-*+]|\d{1,9}[.)])(?:\s+(.*))?$"#, 3) ?? "").isEmpty)
                || isHtml(line)
        }
        func isHtml(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("<!--") || (trimmed.hasPrefix("<") && trimmed.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil)
        }
        func block() {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; listIndents.removeAll(); return }
            if let match = whole(line, #"^ {0,3}(`{3,}|~{3,})\s*([^`]*)$"#) {
                let marker = match[1]
                var code: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    code.append(lines[index]); index += 1
                }
                index += 1
                out.append(.code(match[2].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "", code.joined(separator: "\n")))
                return
            }
            if let match = whole(line, #"^ {0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*$"#) {
                out.append(.heading(match[1].count, inline.parse(match[2])))
                index += 1; return
            }
            if whole(line, #"^ {0,3}([-*_])(\s*\1){2,}\s*$"#) != nil && listIndents.isEmpty { out.append(.rule); index += 1; return }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") { quote(); return }
            if whole(line, #"^(\s*)([-*+]|\d{1,9}[.)])(?:\s+(.*))?$"#) != nil { listItem(); return }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { indented(); return }
            if index + 1 < lines.count && line.contains("|") && whole(lines[index + 1], #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#) != nil && lines[index + 1].contains("-") {
                table(); return
            }
            if isHtml(line) { html(); return }
            paragraph()
        }
        func quote() {
            var inner: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let current = lines[index]
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(">") { inner.append(String(trimmed.dropFirst()).dropPrefix(" ")) } else if startsBlock(current) { break } else { inner.append(current) }
                index += 1
            }
            out.append(.quote(Parser(inner, inline).blocks()))
        }
        func listItem() {
            let line = lines[index]
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" })).replacingOccurrences(of: "\t", with: "    ").count
            while let last = listIndents.last, last > indent { listIndents.removeLast() }
            if listIndents.isEmpty || listIndents.last! < indent { listIndents.append(indent) }
            let depth = listIndents.count - 1
            var body = group(line, #"^(\s*)([-*+]|\d{1,9}[.)])(?:\s+(.*))?$"#, 3) ?? ""
            let rawMarker = group(line, #"^(\s*)([-*+]|\d{1,9}[.)])(?:\s+(.*))?$"#, 2) ?? "•"
            index += 1
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces)
                .isEmpty && !startsBlock(lines[index]) && whole(lines[index], #"^(\s*)([-*+]|\d{1,9}[.)])(?:\s+(.*))?$"#) == nil {
                body += " " + lines[index].trimmingCharacters(in: .whitespaces); index += 1
            }
            let task = whole(body, #"^\[([ xX])](?:\s+(.*))?$"#)
            let marker = rawMarker.first?.isNumber == true ? String(rawMarker.dropLast()) + "." : "•"
            let checked: Bool? = task.map { $0[1] != " " }
            let text = (task?.indices.contains(2) == true && !(task?[2].isEmpty ?? true)) ? (task?[2] ?? body) : body
            out.append(.listItem(depth: depth, marker: marker, checked: checked, text: inline.parse(text)))
        }
        func indented() {
            var code: [String] = []
            while index < lines.count && (lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty) {
                var row = lines[index]
                if row.hasPrefix("\t") { row.removeFirst() }
                if row.hasPrefix("    ") { row.removeFirst(4) }
                code.append(row); index += 1
            }
            while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
            out.append(.code("", code.joined(separator: "\n")))
        }
        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
            var cells: [String] = []
            var cell = ""
            var code = false
            var i = trimmed.startIndex
            while i < trimmed.endIndex {
                let c = trimmed[i]
                if c == "\\", let next = trimmed.index(i, offsetBy: 1, limitedBy: trimmed.endIndex), next < trimmed.endIndex, trimmed[next] == "|" {
                    cell.append("|"); i = trimmed.index(after: next); continue
                }
                if c == "`" { code.toggle(); cell.append(c) } else if c == "|" && !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" } else { cell.append(c) }
                i = trimmed.index(after: i)
            }
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            return cells
        }
        func table() {
            let header = cells(lines[index])
            let alignments = cells(lines[index + 1]).map { cell -> MdAlign in
                if cell.hasPrefix(":") && cell.hasSuffix(":") { return .center }
                if cell.hasSuffix(":") { return .end }
                return .start
            }
            index += 2
            var rows: [[MdText]] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && lines[index].contains("|") {
                let row = cells(lines[index])
                rows.append((0..<header.count).map { inline.parse(row.indices.contains($0) ? row[$0] : "") })
                index += 1
            }
            out.append(.table(header: header.map(inline.parse), alignments: (0..<header.count).map { alignments.indices.contains($0) ? alignments[$0] : .start }, rows: rows))
        }
        func html() {
            var chunk = ""
            var inComment = false
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let current = lines[index]
                if current.contains("<!--") { inComment = true }
                if !inComment { chunk += current + "\n" }
                if current.contains("-->") { inComment = false }
                index += 1
            }
            if let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive) {
                let ns = chunk as NSString
                for match in regex.matches(in: chunk, range: NSRange(location: 0, length: ns.length)) {
                    let tag = ns.substring(with: match.range)
                    var attributes: [String: String] = [:]
                    if let attr = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s>]+)"#) {
                        let tagNS = tag as NSString
                        for found in attr.matches(in: tag, range: NSRange(location: 0, length: tagNS.length)) {
                            let key = tagNS.substring(with: found.range(at: 1)).lowercased()
                            var value = tagNS.substring(with: found.range(at: 2))
                            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
                            attributes[key] = value
                        }
                    }
                    if let src = attributes["src"] { out.append(.image(attributes["alt"] ?? "", src)) }
                }
            }
            let stripped = chunk.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<img\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
            let text = stripped.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(.paragraph(inline.parse(text))) }
        }
        func paragraph() {
            var raw: [String] = []
            while index < lines.count {
                let current = lines[index]
                if !raw.isEmpty, whole(current, #"^ {0,3}(=+|-+)\s*$"#) != nil {
                    let level = current.trimmingCharacters(in: .whitespaces).hasPrefix("=") ? 1 : 2
                    out.append(.heading(level, inline.parse(raw.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))))
                    index += 1; return
                }
                if current.trimmingCharacters(in: .whitespaces).isEmpty || (!raw.isEmpty && startsBlock(current)) { break }
                raw.append(current); index += 1
            }
            var text = ""
            for (n, line) in raw.enumerated() {
                let hard = line.hasSuffix("  ") || line.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
                text += line.trimmingCharacters(in: .whitespaces).dropSuffix("\\")
                if n < raw.count - 1 { text.append(hard ? "\n" : " ") }
            }
            if let match = whole(text, #"^!\[([^\]]*)]\(([^)\s]+)[^)]*\)$"#) {
                out.append(.image(match[1], match[2])); return
            }
            out.append(.paragraph(inline.parse(text)))
        }
    }
}

private final class InlineParser {
    let references: [String: String]
    init(_ references: [String: String]) { self.references = references }
    func parse(_ source: String) -> MdText {
        var out = ""
        var spans: [MdSpan] = []
        parseInto(source, &out, &spans)
        return MdText(text: out, spans: spans)
    }
    func parseInto(_ src: String, _ out: inout String, _ spans: inout [MdSpan]) {
        let chars = Array(src)
        var i = 0
        func append(_ text: String) { out += text }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>\"'".contains(chars[i + 1]) {
                append(String(chars[i + 1])); i += 2; continue
            }
            if c == "`" {
                var ticks = 1
                while i + ticks < chars.count && chars[i + ticks] == "`" { ticks += 1 }
                let fence = String(repeating: "`", count: ticks)
                if let close = src.range(of: fence, range: src.index(src.startIndex, offsetBy: i + ticks)..<src.endIndex) {
                    let start = out.utf16.count
                    var inner = String(src[src.index(src.startIndex, offsetBy: i + ticks)..<close.lowerBound])
                    if inner.count > 2 && inner.hasPrefix(" ") && inner.hasSuffix(" ") { inner = String(inner.dropFirst().dropLast()) }
                    append(inner)
                    spans.append(MdSpan(start: start, end: out.utf16.count, style: .code, url: nil))
                    i = src.distance(from: src.startIndex, to: close.upperBound); continue
                }
            }
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[" {
                if let close = src.dropFirst(i + 2).firstIndex(of: "]") {
                    let closeOffset = src.distance(from: src.startIndex, to: close)
                    if let target = linkTarget(src, closeOffset + 1) {
                        let start = out.utf16.count
                        let alt = String(src[src.index(src.startIndex, offsetBy: i + 2)..<close])
                        append(alt.isEmpty ? "image" : alt)
                        spans.append(MdSpan(start: start, end: out.utf16.count, style: .image, url: target.0))
                        i = target.1; continue
                    }
                }
            }
            if c == "[" {
                if let close = matchingBracket(chars, i), close > i {
                    let label = String(chars[(i + 1)..<close])
                    let inlineTarget = linkTarget(src, close + 1)
                    var referenceTarget: (String, Int)?
                    if inlineTarget == nil, close + 1 < chars.count, chars[close + 1] == "[", let end = src.dropFirst(close + 2).firstIndex(of: "]") {
                        let endOffset = src.distance(from: src.startIndex, to: end)
                        let key = String(src[src.index(src.startIndex, offsetBy: close + 2)..<end])
                        if let url = references[(key.isEmpty ? label : key).lowercased()] { referenceTarget = (url, endOffset + 1) }
                    }
                    let shortcut = inlineTarget == nil && referenceTarget == nil ? references[label.lowercased()].map { ($0, close + 1) } : nil
                    if let target = inlineTarget ?? referenceTarget ?? shortcut {
                        let start = out.utf16.count
                        parseInto(label, &out, &spans)
                        spans.append(MdSpan(start: start, end: out.utf16.count, style: .link, url: target.0))
                        i = target.1; continue
                    }
                }
            }
            if c == "<", let close = src.dropFirst(i + 1).firstIndex(of: ">") {
                let inner = String(src[src.index(src.startIndex, offsetBy: i + 1)..<close])
                let closeOffset = src.distance(from: src.startIndex, to: close)
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    let start = out.utf16.count
                    append(inner.hasPrefix("mailto:") ? String(inner.dropFirst(7)) : inner)
                    spans.append(MdSpan(start: start, end: out.utf16.count, style: .link, url: inner))
                    i = closeOffset + 1; continue
                }
                if inner.range(of: #"^br\s*/?$"#, options: [.regularExpression, .caseInsensitive]) != nil { append("\n"); i = closeOffset + 1; continue }
                if inner.range(of: #"^/?[A-Za-z][\w-]*(\s[^>]*)?/?$"#, options: .regularExpression) != nil { i = closeOffset + 1; continue }
            }
            if c == "h", src.dropFirst(i).hasPrefix("https://") || src.dropFirst(i).hasPrefix("http://"), i == 0 || !chars[i - 1].isLetter && !chars[i - 1].isNumber {
                var j = i
                while j < chars.count && !chars[j].isWhitespace && chars[j] != "<" { j += 1 }
                while j > i && ".,;:!?)'\"".contains(chars[j - 1]) { j -= 1 }
                let start = out.utf16.count
                append(String(chars[i..<j]))
                spans.append(MdSpan(start: start, end: out.utf16.count, style: .link, url: String(chars[i..<j])))
                i = j; continue
            }
            if c == "~", src.dropFirst(i).hasPrefix("~~"), let next = emphasis(chars, i, "~~", .strike, &out, &spans) { i = next; continue }
            if c == "*" || c == "_", i + 1 < chars.count, chars[i + 1] == c, let next = emphasis(chars, i, String(c) + String(c), .bold, &out, &spans) { i = next; continue }
            if c == "*" || c == "_", c == "*" || i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber), let next = emphasis(chars, i, String(c), .italic, &out, &spans) { i = next; continue }
            append(String(c)); i += 1
        }
    }
    func linkTarget(_ src: String, _ open: Int) -> (String, Int)? {
        let chars = Array(src)
        guard open < chars.count, chars[open] == "(" else { return nil }
        var depth = 0
        for j in open..<chars.count {
            if chars[j] == "(" { depth += 1 } else if chars[j] == ")" {
                depth -= 1
                if depth == 0 {
                    let raw = String(chars[(open + 1)..<j]).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                    return (raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), j + 1)
                }
            }
        }
        return nil
    }
    func matchingBracket(_ chars: [Character], _ open: Int) -> Int? {
        var depth = 0
        var j = open
        while j < chars.count {
            if chars[j] == "\\" { j += 1 } else if chars[j] == "[" { depth += 1 } else if chars[j] == "]" { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }
    func emphasis(_ chars: [Character], _ i: Int, _ delimiter: String, _ style: MdStyle, _ out: inout String, _ spans: inout [MdSpan]) -> Int? {
        let contentStart = i + delimiter.count
        guard contentStart < chars.count, !chars[contentStart].isWhitespace else { return nil }
        let src = String(chars)
        guard let range = src.range(of: delimiter, range: src.index(src.startIndex, offsetBy: contentStart)..<src.endIndex) else { return nil }
        let close = src.distance(from: src.startIndex, to: range.lowerBound)
        if close <= contentStart { return nil }
        if delimiter == "_", close + 1 < chars.count, chars[close + 1].isLetter || chars[close + 1].isNumber { return nil }
        let start = out.utf16.count
        parseInto(String(chars[contentStart..<close]), &out, &spans)
        spans.append(MdSpan(start: start, end: out.utf16.count, style: style, url: nil))
        return close + delimiter.count
    }
}

private func whole(_ line: String, _ pattern: String) -> [String]? {
    guard let regex = RegexCache.expression(pattern) else { return nil }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = regex.firstMatch(in: line, range: range), match.range.length == range.length else { return nil }
    return (0..<match.numberOfRanges).map { index in
        guard let r = Range(match.range(at: index), in: line) else { return "" }
        return String(line[r])
    }
}
private func group(_ line: String, _ pattern: String, _ index: Int) -> String? { whole(line, pattern).flatMap { $0.indices.contains(index) ? $0[index] : nil } }
private extension String {
    func dropPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
    func dropSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

/// Compiled patterns shared by the Markdown and syntax highlighters.
enum RegexCache {
    static let lock = NSLock()
    static var values: [String: NSRegularExpression] = [:]
    static func expression(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let value = values[pattern] { return value }
        guard let value = try? NSRegularExpression(pattern: pattern) else { return nil }
        values[pattern] = value; return value
    }
}
