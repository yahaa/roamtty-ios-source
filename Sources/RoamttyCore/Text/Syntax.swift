// Roamtty Android code preview types and language identities, adapted from the earlier Swift port.
import Foundation

public enum TokenType: Int, CaseIterable, Sendable {
    case keyword, type, string, number, comment, function, property, variable, constant, meta
    case tag, attribute, punctuation, heading, strong, emphasis, link, inserted, deleted, error, warning, info
}

public enum LanguageMode: Sendable { case plain, code, markup, markdown }

public struct CodeLine: Equatable, Sendable {
    public var number: Int
    public var text: String
    /// Spans are UTF-16 (start, end, TokenType.rawValue) triples, suitable for NSRange.
    public var spans: [Int]
}

public struct CodeDocument: Sendable {
    public var language: CodeLanguage
    public var lines: [CodeLine]
    public var lineCount: Int
    public var maxColumns: Int
}

public struct CodeLanguage: Sendable {
    public var id: String
    public var displayName: String
    public var mode: LanguageMode
    public var lineComments: [String]
    public var words: [String: TokenType]
    public init(id: String, displayName: String, mode: LanguageMode = .code, lineComments: [String] = [], words: [String: TokenType] = [:]) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.lineComments = lineComments
        self.words = words
    }
}

public enum Languages {
    public static let plain = CodeLanguage(id: "plaintext", displayName: "Plain Text", mode: .plain)
    public static let kotlin = code("kotlin", "Kotlin", comments: ["//"], words: words([
        .keyword: "package import class interface fun val var object if else when for while return true false null",
        .type: "String Int Boolean Long Double",
        .constant: "true false null"
    ]))
    public static let python = code("python", "Python", comments: ["#"], words: words([
        .keyword: "def class if else elif return import from for while pass",
        .constant: "True False None self"
    ]))
    public static let shell = code("shell", "Shell", comments: ["#"], words: words([
        .keyword: "if then else fi for while do done function",
        .function: "echo printf cd ls rm git ssh"
    ]))
    public static let json = code("json", "JSON", words: words([.constant: "true false null"]))
    public static let javascript = code("javascript", "JavaScript", comments: ["//"], words: words([.keyword: "let const function return class import export", .constant: "true false null"]))
    public static let typescript = code("typescript", "TypeScript", comments: ["//"], words: javascript.words)
    public static let java = code("java", "Java", comments: ["//"], words: words([.keyword: "class public static void if else return import package", .type: "String int boolean"]))
    public static let go = code("go", "Go", comments: ["//"], words: words([.keyword: "func package import if else return var const type struct", .constant: "true false nil"]))
    public static let rust = code("rust", "Rust", comments: ["//"], words: words([.keyword: "fn let mut struct enum impl pub use if else return", .type: "str i32 u8 String", .constant: "true false"]))
    public static let c = code("c", "C", comments: ["//"], words: words([.keyword: "if else return for while struct typedef", .type: "int char void long"]))
    public static let cpp = code("cpp", "C++", comments: ["//"], words: c.words)
    public static let csharp = code("csharp", "C#", comments: ["//"], words: words([.keyword: "class public static void if else return using namespace", .type: "string int bool"]))
    public static let swift = code("swift", "Swift", comments: ["//"], words: words([.keyword: "func let var struct class enum if else return import", .constant: "true false nil"]))
    public static let html = CodeLanguage(id: "html", displayName: "HTML", mode: .markup)
    public static let xml = CodeLanguage(id: "xml", displayName: "XML", mode: .markup)
    public static let markdown = CodeLanguage(id: "markdown", displayName: "Markdown", mode: .markdown)
    public static let yaml = code("yaml", "YAML", comments: ["#"], words: words([.constant: "true false yes no null"]))
    public static let toml = code("toml", "TOML", comments: ["#"])
    public static let ini = code("ini", "Config", comments: ["#", ";"])
    public static let css = code("css", "CSS", words: words([.constant: "inherit initial unset none auto"]))
    public static let scss = code("scss", "SCSS", comments: ["//"], words: css.words)
    public static let sql = code("sql", "SQL", comments: ["--"], words: words([.keyword: "select from where insert update delete create table"]))
    public static let dockerfile = code("dockerfile", "Dockerfile", comments: ["#"], words: words([.keyword: "FROM RUN CMD COPY ADD ENV EXPOSE WORKDIR ENTRYPOINT"]))
    public static let diff = code("diff", "Diff")
    public static let log = code("log", "Log", words: words([.error: "ERROR FATAL", .warning: "WARN WARNING", .info: "INFO"]))
    public static let ruby = code("ruby", "Ruby", comments: ["#"], words: words([.keyword: "def class end if else module require"]))
    public static let php = code("php", "PHP", comments: ["//", "#"], words: words([.keyword: "function class if else return echo"]))
    public static let lua = code("lua", "Lua", comments: ["--"], words: words([.keyword: "function local if then else end return"]))
    public static let dart = code("dart", "Dart", comments: ["//"], words: words([.keyword: "class void if else return import"]))
    public static let makefile = code("makefile", "Makefile", comments: ["#"])
    public static let powershell = code("powershell", "PowerShell", comments: ["#"])
    public static let batch = code("bat", "Batch", comments: ["::"])

    public static func forFence(_ info: String) -> CodeLanguage? {
        let key = info.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: " ").first?.split(separator: "{").first.map(String.init) ?? ""
        return aliases[key]
    }

    public static func detect(fileName: String, firstLine: String = "") -> CodeLanguage {
        let name = fileName.lowercased()
        if let language = byName[name] { return language }
        if name.hasPrefix(".env") { return ini }
        if name.hasPrefix("dockerfile") { return dockerfile }
        if name.hasSuffix("_history") { return shell }
        if let dot = name.lastIndex(of: "."), let language = byExtension[String(name[name.index(after: dot)...])] { return language }
        if firstLine.hasPrefix("#!") {
            var interpreter = firstLine.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if interpreter.hasPrefix("env ") { interpreter = String(interpreter.dropFirst(4)) }
            interpreter = interpreter.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            if interpreter.hasPrefix("python") { return python }
            if ["node", "deno", "bun"].contains(where: interpreter.hasPrefix) { return javascript }
            if interpreter.hasPrefix("ruby") { return ruby }
            if interpreter.hasPrefix("php") { return php }
            if interpreter.hasPrefix("lua") { return lua }
            if interpreter.hasPrefix("pwsh") { return powershell }
            return shell
        }
        if firstLine.hasPrefix("<?xml") || firstLine.hasPrefix("<svg") { return xml }
        if firstLine.lowercased().hasPrefix("<!doctype html") || firstLine.lowercased().hasPrefix("<html") { return html }
        return plain
    }

    private static func code(_ id: String, _ name: String, comments: [String] = [], words: [String: TokenType] = [:]) -> CodeLanguage {
        CodeLanguage(id: id, displayName: name, lineComments: comments, words: words)
    }
    private static func words(_ groups: [TokenType: String]) -> [String: TokenType] {
        var map: [String: TokenType] = [:]
        for (type, list) in groups { for word in list.split(separator: " ") { map[String(word)] = type } }
        return map
    }
    private static let aliases: [String: CodeLanguage] = [
        "sh": shell, "bash": shell, "shell": shell, "console": shell, "zsh": shell, "js": javascript,
        "javascript": javascript, "ts": typescript, "typescript": typescript, "py": python, "python": python, "kotlin": kotlin,
        "java": java, "go": go, "golang": go, "rust": rust, "c": c, "cpp": cpp,
        "c++": cpp, "csharp": csharp, "cs": csharp, "swift": swift, "dart": dart, "php": php,
        "ruby": ruby, "rb": ruby, "lua": lua, "sql": sql, "json": json, "yaml": yaml,
        "yml": yaml, "toml": toml, "ini": ini, "css": css, "scss": scss, "html": html,
        "xml": xml, "diff": diff, "dockerfile": dockerfile, "docker": dockerfile, "makefile": makefile, "make": makefile,
        "powershell": powershell, "ps1": powershell, "kt": kotlin, "md": markdown, "markdown": markdown
    ]
    private static let byExtension: [String: CodeLanguage] = [
        "kt": kotlin, "kts": kotlin, "gradle": kotlin, "java": java, "groovy": java, "scala": java,
        "js": javascript, "mjs": javascript, "cjs": javascript, "jsx": javascript, "ts": typescript, "tsx": typescript,
        "mts": typescript, "cts": typescript, "py": python, "pyi": python, "pyw": python, "go": go,
        "rs": rust, "c": c, "h": c, "cc": cpp, "cpp": cpp, "cxx": cpp,
        "hpp": cpp, "hh": cpp, "hxx": cpp, "m": c, "mm": cpp, "cs": csharp,
        "swift": swift, "dart": dart, "php": php, "rb": ruby, "rake": ruby, "lua": lua,
        "sql": sql, "sh": shell, "bash": shell, "zsh": shell, "ksh": shell, "fish": shell,
        "ps1": powershell, "psm1": powershell, "bat": batch, "cmd": batch, "json": json, "jsonc": json,
        "json5": json, "geojson": json, "webmanifest": json, "ipynb": json, "yaml": yaml, "yml": yaml,
        "toml": toml, "ini": ini, "conf": ini, "cfg": ini, "properties": ini, "env": ini,
        "service": ini, "desktop": ini, "css": css, "scss": scss, "less": scss, "sass": scss,
        "html": html, "htm": html, "xhtml": html, "vue": html, "svelte": html, "xml": xml,
        "svg": xml, "plist": xml, "xsd": xml, "xsl": xml, "md": markdown, "markdown": markdown,
        "mdx": markdown, "diff": diff, "patch": diff, "log": log, "out": log, "err": log,
        "tf": ini, "dockerfile": dockerfile
    ]
    private static let byName: [String: CodeLanguage] = [
        "dockerfile": dockerfile, "containerfile": dockerfile, "makefile": makefile, "gnumakefile": makefile, "gemfile": ruby, "rakefile": ruby,
        "cmakelists.txt": makefile, ".bashrc": shell, ".bash_profile": shell, ".zshrc": shell, ".profile": shell, ".bash_aliases": shell,
        ".bash_logout": shell, ".zprofile": shell, ".zshenv": shell, "gradlew": shell, ".gitconfig": ini, ".editorconfig": ini,
        ".npmrc": ini, ".gitmodules": ini, ".tmux.conf": ini, "config": ini, "ssh_config": ini, "sshd_config": ini,
        ".gitignore": ini, ".dockerignore": ini, "jenkinsfile": java, "cargo.lock": toml, "pipfile": toml, "go.mod": go
    ]
}

/// UTF-16 units drawn two columns wide: Hangul Jamo, CJK, Hangul syllables, compatibility ideographs, CJK forms and
/// fullwidth forms.
private let wideUnits: [ClosedRange<UInt16>] = [0x1100...0x115f, 0x2e80...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe4f,
                                                0xff00...0xff60, 0xffe0...0xffe6]

public enum SyntaxHighlighter {
    public static let maxRowLength = 2000
    public static func highlight(_ rawText: String, _ language: CodeLanguage) -> CodeDocument {
        var expanded: [UInt16] = [], column = 0
        for unit in rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").utf16 {
            if unit == 9 {
                let count = 4 - column % 4
                expanded.append(contentsOf: repeatElement(32, count: count))
                column += count
            } else {
                expanded.append(unit)
                column = unit == 10 ? 0 : column + 1
            }
        }
        let lexer = PreviewLexer(expanded)
        switch language.mode {
        case .plain: break
        case .code: lexer.code(language, from: 0, to: expanded.count)
        case .markup: lexer.markup(from: 0, to: expanded.count)
        case .markdown: lexer.markdown()
        }
        return lexer.document(language)
    }
}

private final class PreviewLexer {
    struct Span { var start: Int; var end: Int; var type: TokenType }
    let units: [UInt16]
    let source: NSString
    var spans: [Span] = []
    init(_ units: [UInt16]) { self.units = units; source = String(decoding: units, as: UTF16.self) as NSString }
    func text(_ from: Int, _ to: Int) -> String { source.substring(with: NSRange(location: from, length: max(0, to - from))) }
    func add(_ start: Int, _ end: Int, _ type: TokenType) { if end > start { spans.append(Span(start: start, end: end, type: type)) } }
    func starts(_ value: String, at: Int, to: Int) -> Bool { let value = Array(value.utf16); return at + value.count <= to && units[at..<(at + value.count)].elementsEqual(value) }
    func find(_ value: String, from: Int, to: Int, insensitive: Bool = false) -> Int? {
        guard from < to else { return nil }
        let range = source.range(of: value, options: insensitive ? .caseInsensitive : [], range: NSRange(location: from, length: to - from))
        return range.location == NSNotFound ? nil : range.location
    }
    func lineEnd(_ from: Int, _ to: Int) -> Int { units[from..<to].firstIndex(of: 10) ?? to }
    func letter(_ c: UInt16) -> Bool { Unicode.Scalar(c).map { CharacterSet.letters.contains($0) } ?? false }
    func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }
    func space(_ c: UInt16) -> Bool { Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
    func identifier(_ c: UInt16, dash: Bool = false) -> Bool { letter(c) || digit(c) || c == 95 || (dash && c == 45) }
    func next(_ from: Int, _ to: Int) -> UInt16 { var at = from; while at < to && (units[at] == 32 || units[at] == 9) { at += 1 }; return at < to ? units[at] : 10 }
    func regex(_ pattern: String, at: Int, to: Int) -> NSTextCheckingResult? {
        RegexCache.expression(pattern)?.firstMatch(in: source as String, options: [.anchored, .withTransparentBounds], range: NSRange(location: at, length: to - at))
    }

    func scanString(_ at: Int, _ to: Int, language: String) -> Int? {
        let c = units[at]
        guard c == 34 || c == 39 || (c == 96 && ["javascript", "typescript", "go"].contains(language)) else { return nil }
        let triple = ["kotlin", "java", "python", "toml", "swift"].contains(language) && at + 2 < to && units[at + 1] == c && units[at + 2] == c
        let width = triple ? 3 : 1
        let multiline = triple || c == 96 || ["shell", "powershell", "ruby", "php"].contains(language)
        let bounded = c == 39 && ["rust", "c", "cpp", "go", "java", "kotlin", "swift"].contains(language)
        var atEnd = at + width
        while atEnd < to {
            if units[atEnd] == 92 && !(c == 39 && ["shell", "yaml", "toml"].contains(language)) { atEnd += min(2, to - atEnd); continue }
            if units[atEnd] == c && (!triple || atEnd + 2 < to && units[atEnd + 1] == c && units[atEnd + 2] == c) { return atEnd + width }
            if units[atEnd] == 10 && !multiline { return bounded ? nil : atEnd }
            if bounded && atEnd - at > (language == "rust" ? 10 : 12) { return nil }
            atEnd += 1
        }
        return bounded ? nil : to
    }

    // swiftlint:disable:next cyclomatic_complexity - one pass over the text; its branches share the scan's position and state
    func code(_ language: CodeLanguage, from: Int, to: Int) {
        let id = language.id, dash = ["shell", "powershell", "css", "scss"].contains(language.id)
        let block: [(String, String)] = id == "powershell" ? [("<#", "#>")] : id == "lua" ? [("--[[", "]]")] : id == "ruby" ? [("=begin", "=end")] : [
            "python", "shell", "yaml", "toml", "ini", "makefile", "dockerfile", "bat", "log", "diff"].contains(id) ? [] : [("/*", "*/")]
        let words = (androidPreviewWords[id] ?? [:]).merging(language.words) { exact, _ in exact }
        let caseInsensitive = ["sql", "powershell", "bat"].contains(id)
        var i = from, lineStart = from, depth = 0, previous: TokenType?, last: UInt16 = 32
        let declarators: [String: TokenType] = ["class": .type, "interface": .type, "struct": .type, "enum": .type, "trait": .type, "object": .type,
            "protocol": .type, "typealias": .type, "type": .type, "fun": .function, "function": .function, "func": .function, "fn": .function,
            "def": .function]
        scan: while i < to {
            let c = units[i]
            if c == 10 { i += 1; lineStart = i; previous = nil; continue }
            if space(c) { i += 1; continue }
            if id == "diff" {
                let end = lineEnd(i, to), line = text(i, end)
                if line.hasPrefix("+++") || line.hasPrefix("---") {
                    add(i, end, .strong)
                } else if line.hasPrefix("+") {
                    add(i, end, .inserted)
                } else if line.hasPrefix("-") {
                    add(i, end, .deleted)
                } else if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                    add(i, end, .meta)
                }
                i = end; continue
            }
            for (open, close) in block where starts(open, at: i, to: to) {
                let end = find(close, from: i + open.utf16.count, to: to).map { $0 + close.utf16.count } ?? to
                add(i, end, .comment); i = end; continue scan
            }
            for prefix in language.lineComments where starts(prefix, at: i, to: to) {
                if ["shell", "yaml"].contains(id) && i != lineStart && !space(units[i - 1]) { continue }
                let end = lineEnd(i, to); add(i, end, .comment); i = end; continue scan
            }
            if c == 35 && ["c", "cpp"].contains(id) && units[lineStart..<i].allSatisfy(space) {
                var end = i + 1; while end < to && (letter(units[end]) || units[end] == 32) { end += 1 }
                add(i, end, .meta); i = end; continue
            }
            if let end = scanString(i, to, language: id) { add(i, end, id == "json" && next(end, to) == 58 ? .property : .string); i = end; previous = nil; last = 34; continue }
            if c == 104 && (starts("https://", at: i, to: to) || starts("http://", at: i, to: to)), let match = regex(#"https?://[^\s\"'<>()\[\]]+"#, at: i, to: to) {
                add(i, NSMaxRange(match.range), .link); i = NSMaxRange(match.range); continue
            }
            if id == "log", digit(c), let match = regex(#"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?"#, at: i, to: to) {
                add(i, NSMaxRange(match.range), .constant); i = NSMaxRange(match.range); continue
            }
            if c == 64 && ["kotlin", "java", "python", "swift", "css", "scss"].contains(id), i + 1 < to, identifier(units[i + 1]) {
                var end = i + 2; while end < to && (identifier(units[end], dash: dash) || units[end] == 46) { end += 1 }
                add(i, end, .meta); i = end; continue
            }
            if c == 36 && ["shell", "powershell", "php", "ruby", "makefile", "scss"].contains(id), i + 1 < to {
                var end = i + 1
                if units[end] == 123 || (units[end] == 40 && id == "makefile") {
                    end = find(units[end] == 123 ? "}" : ")", from: end + 1, to: lineEnd(i, to)).map { $0 + 1 } ?? end
                } else {
                    while end < to && identifier(units[end]) { end += 1 }
                    if end == i + 1 && "@#?$!*-".utf16.contains(units[end]) { end += 1 }
                }
                if end > i + 1 { add(i, end, .variable); i = end; continue }
            }
            if digit(c), i == from || !identifier(units[i - 1], dash: dash) {
                if let match = regex(#"(?:0[xXbBoO][A-Za-z0-9_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)[A-Za-z%]*"#, at: i, to: to) {
                    add(i, NSMaxRange(match.range), .number); i = NSMaxRange(match.range); previous = nil; last = 48; continue
                }
            }
            if letter(c) || c == 95 {
                var end = i + 1; while end < to && identifier(units[end], dash: dash) { end += 1 }
                let word = text(i, end), nextChar = next(end, to)
                if id == "python", end - i <= 2, word.allSatisfy({ "rRbBfFuU".contains($0) }), end < to, let stringEnd = scanString(end, to, language: id) {
                    add(i, stringEnd, .string)
                    i = stringEnd
                    continue
                }
                if ["kotlin", "java", "go"].contains(id) && ["package", "import"].contains(word) {
                    add(i, end, .keyword)
                    var pathEnd = end
                    let stop = lineEnd(end, to)
                    while pathEnd < stop && !language.lineComments.contains(where: { starts($0, at: pathEnd, to: stop) }) { pathEnd += 1 }
                    i = pathEnd; previous = nil; continue
                }
                var kind = words[caseInsensitive ? word.lowercased() : word] ?? previous
                if kind == nil {
                    if id == "rust" && end < to && units[end] == 33 {
                        kind = .function
                        end += 1
                    } else if id == "css" || id == "scss" {
                        if depth == 0 { kind = .tag } else if nextChar == 58 { kind = .property }
                    } else if ["yaml", "toml", "ini"].contains(id) && (nextChar == 58 || nextChar == 61) {
                        kind = .property
                    } else if nextChar == 40 {
                        kind = .function
                    } else if last == 46 {
                        kind = .property
                    } else if ["kotlin", "java", "python", "rust", "swift", "csharp", "typescript"].contains(id), word.first?.isUppercase == true {
                        kind = word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } ? .constant : .type
                    }
                }
                if let kind { add(i, end, kind) }
                previous = declarators[word]; i = end; last = 97; continue
            }
            if c == 123 { depth += 1 }; if c == 125 { depth = max(0, depth - 1) }
            previous = nil; last = c; i += 1
        }
    }

    func markup(from: Int, to: Int) {
        var i = from
        while i < to {
            if units[i] == 60 {
                if starts("<!--", at: i, to: to) { let end = find("-->", from: i + 4, to: to).map { $0 + 3 } ?? to; add(i, end, .comment); i = end; continue }
                if starts("<![CDATA[", at: i, to: to) { let end = find("]]>", from: i + 9, to: to).map { $0 + 3 } ?? to; add(i, end, .string); i = end; continue }
                if i + 1 < to && (units[i + 1] == 33 || units[i + 1] == 63) { let end = find(">", from: i + 2, to: to).map { $0 + 1 } ?? to; add(i, end, .meta); i = end; continue }
                if i + 1 < to && (units[i + 1] == 47 || letter(units[i + 1])) {
                    let closing = units[i + 1] == 47, start = i
                    i += closing ? 2 : 1; add(start, i, .punctuation)
                    let nameStart = i
                    while i < to && !" \t\n/>=\"'".utf16.contains(units[i]) { i += 1 }
                    let name = text(nameStart, i).lowercased(); add(nameStart, i, .tag)
                    var selfClosing = false
                    while i < to {
                        if units[i] == 62 { add(i, i + 1, .punctuation); i += 1; break }
                        if starts("/>", at: i, to: to) { add(i, i + 2, .punctuation); i += 2; selfClosing = true; break }
                        if units[i] == 34 || units[i] == 39 {
                            let quote = String(decoding: [units[i]], as: UTF16.self)
                            let end = find(quote, from: i + 1, to: to).map { $0 + 1 } ?? to
                            add(i, end, .string)
                            i = end
                            continue
                        }
                        if space(units[i]) || units[i] == 61 { i += 1; continue }
                        let start = i
                        while i < to && !" \t\n/>=\"'".utf16.contains(units[i]) { i += 1 }
                        if i == start { i += 1 } else { add(start, i, .attribute) }
                    }
                    if !closing && !selfClosing && ["script", "style"].contains(name) {
                        let end = find("</" + name, from: i, to: to, insensitive: true) ?? to
                        code(name == "script" ? Languages.javascript : Languages.css, from: i, to: end); i = end
                    }
                    continue
                }
            }
            if units[i] == 38, let result = regex(#"&[A-Za-z0-9#]{1,10};"#, at: i, to: to) { let end = NSMaxRange(result.range); add(i, end, .constant); i = end; continue }
            i += 1
        }
    }

    func markdown() {
        var start = 0
        while start < units.count {
            let end = lineEnd(start, units.count)
            if let fence = regex(#" {0,3}(`{3,}|~{3,})\s*([^`\s]*)"#, at: start, to: end) {
                let marker = source.substring(with: fence.range(at: 1)), info = source.substring(with: fence.range(at: 2))
                add(start, end, .meta)
                let bodyStart = min(end + 1, units.count)
                var bodyEnd = units.count, closingEnd = units.count, cursor = bodyStart
                while cursor < units.count {
                    let nextEnd = lineEnd(cursor, units.count)
                    if text(cursor, nextEnd).trimmingCharacters(in: .whitespaces).hasPrefix(marker) { bodyEnd = cursor; closingEnd = nextEnd; break }
                    cursor = nextEnd + 1
                }
                if let language = Languages.forFence(info), language.mode == .code {
                    code(language, from: bodyStart, to: bodyEnd)
                } else if let language = Languages.forFence(info), language.mode == .markup {
                    markup(from: bodyStart, to: bodyEnd)
                } else {
                    add(bodyStart, bodyEnd, .string)
                }
                if bodyEnd < units.count { add(bodyEnd, closingEnd, .meta) }
                start = closingEnd + 1; continue
            }
            if regex(#" {0,3}#{1,6}(?:\s|$)"#, at: start, to: end) != nil {
                add(start, end, .heading)
            } else if regex(#" {0,3}([-*_])(?:\s*\1){2,}\s*$"#, at: start, to: end) != nil {
                add(start, end, .punctuation)
            } else if text(start, end).trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                add(start, end, .comment)
            } else {
                var inlineStart = start
                if let marker = regex(#"\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s)?"#, at: start, to: end) { inlineStart = NSMaxRange(marker.range); add(start, inlineStart, .keyword) }
                inline(from: inlineStart, to: end)
            }
            start = end + 1
        }
    }

    func inline(from: Int, to: Int) {
        var i = from
        while i < to {
            let c = units[i]
            if c == 96, let end = find("`", from: i + 1, to: to) { add(i, end + 1, .string); i = end + 1; continue }
            if c == 42 || c == 95 {
                let doubled = i + 1 < to && units[i + 1] == c
                let width = doubled ? 2 : 1, marker = String(decoding: Array(repeating: c, count: doubled ? 2 : 1), as: UTF16.self)
                if let end = find(marker, from: i + width, to: to), end > i + width { add(i, end + width, doubled ? .strong : .emphasis); i = end + width; continue }
            }
            if c == 91 || c == 33 && i + 1 < to && units[i + 1] == 91 {
                if let close = find("](", from: i + 1, to: to), let end = find(")", from: close + 2, to: to) { add(i, close + 1, .link); add(close + 1, end + 1, .string); i = end + 1; continue }
            }
            if c == 104, let link = regex(#"https?://[^\s)>]+"#, at: i, to: to) { add(i, NSMaxRange(link.range), .link); i = NSMaxRange(link.range); continue }
            if c == 124 { add(i, i + 1, .punctuation) }
            i += 1
        }
    }

    func document(_ language: CodeLanguage) -> CodeDocument {
        var rows: [CodeLine] = [], line = 0, start = 0, spanIndex = 0, maxColumns = 0
        while start <= units.count {
            line += 1
            let end = lineEnd(start, units.count)
            var rowStart = start
            repeat {
                var rowEnd = min(end, rowStart + SyntaxHighlighter.maxRowLength)
                if rowEnd < end && rowEnd > rowStart && (0xd800...0xdbff).contains(units[rowEnd - 1]) && (0xdc00...0xdfff).contains(units[rowEnd]) { rowEnd -= 1 }
                while spanIndex < spans.count && spans[spanIndex].end <= rowStart { spanIndex += 1 }
                var at = spanIndex, rowSpans: [Int] = []
                while at < spans.count && spans[at].start < rowEnd {
                    let span = spans[at], from = max(span.start, rowStart) - rowStart, to = min(span.end, rowEnd) - rowStart
                    if to > from { rowSpans += [from, to, span.type.rawValue] }; at += 1
                }
                var columns = rowEnd - rowStart
                for unit in units[rowStart..<rowEnd] where wideUnits.contains(where: { $0.contains(unit) }) { columns += 1 }
                maxColumns = max(maxColumns, columns)
                rows.append(CodeLine(number: rowStart == start ? line : 0, text: text(rowStart, rowEnd), spans: rowSpans)); rowStart = rowEnd
            } while rowStart < end
            if end == units.count { break }; start = end + 1
        }
        return CodeDocument(language: language, lines: rows, lineCount: line, maxColumns: maxColumns)
    }
}

// Language word lists ported directly from Android CodeLanguage.kt.
// swiftlint:disable line_length - word tables, one language per line, as in the Android source.
private let androidPreviewWords: [String: [String: TokenType]] = [
    "kotlin": ["package": .keyword, "import": .keyword, "class": .keyword, "interface": .keyword, "fun": .keyword, "val": .keyword, "var": .keyword, "object": .keyword, "typealias": .keyword, "if": .keyword, "else": .keyword, "when": .keyword, "for": .keyword, "while": .keyword, "do": .keyword, "return": .keyword, "break": .keyword, "continue": .keyword, "throw": .keyword, "try": .keyword, "catch": .keyword, "finally": .keyword, "in": .keyword, "is": .keyword, "as": .keyword, "by": .keyword, "get": .keyword, "set": .keyword, "constructor": .keyword, "init": .keyword, "companion": .keyword, "data": .keyword, "sealed": .keyword, "enum": .keyword, "annotation": .keyword, "open": .keyword, "abstract": .keyword, "override": .keyword, "private": .keyword, "protected": .keyword, "public": .keyword, "internal": .keyword, "lateinit": .keyword, "inline": .keyword, "noinline": .keyword, "crossinline": .keyword, "reified": .keyword, "suspend": .keyword, "operator": .keyword, "infix": .keyword, "tailrec": .keyword, "external": .keyword, "const": .keyword, "vararg": .keyword, "where": .keyword, "out": .keyword, "actual": .keyword, "expect": .keyword, "value": .keyword, "this": .keyword, "super": .keyword, "it": .keyword, "true": .constant, "false": .constant, "null": .constant],

    "java": ["abstract": .keyword, "assert": .keyword, "break": .keyword, "case": .keyword, "catch": .keyword, "class": .keyword, "continue": .keyword, "default": .keyword, "do": .keyword, "else": .keyword, "enum": .keyword, "extends": .keyword, "final": .keyword, "finally": .keyword, "for": .keyword, "if": .keyword, "implements": .keyword, "import": .keyword, "instanceof": .keyword, "interface": .keyword, "native": .keyword, "new": .keyword, "package": .keyword, "private": .keyword, "protected": .keyword, "public": .keyword, "return": .keyword, "static": .keyword, "strictfp": .keyword, "super": .keyword, "switch": .keyword, "synchronized": .keyword, "this": .keyword, "throw": .keyword, "throws": .keyword, "transient": .keyword, "try": .keyword, "volatile": .keyword, "while": .keyword, "var": .keyword, "record": .keyword, "yield": .keyword, "sealed": .keyword, "permits": .keyword, "void": .type, "boolean": .type, "byte": .type, "char": .type, "double": .type, "float": .type, "int": .type, "long": .type, "short": .type, "true": .constant, "false": .constant, "null": .constant],

    "javascript": ["true": .constant, "false": .constant, "null": .constant, "undefined": .constant, "NaN": .constant, "Infinity": .constant],
    "typescript": ["break": .keyword, "case": .keyword, "catch": .keyword, "class": .keyword, "const": .keyword, "continue": .keyword, "debugger": .keyword, "default": .keyword, "delete": .keyword, "do": .keyword, "else": .keyword, "export": .keyword, "extends": .keyword, "finally": .keyword, "for": .keyword, "from": .keyword, "function": .keyword, "if": .keyword, "import": .keyword, "in": .keyword, "instanceof": .keyword, "let": .keyword, "new": .keyword, "of": .keyword, "return": .keyword, "static": .keyword, "super": .keyword, "switch": .keyword, "this": .keyword, "throw": .keyword, "try": .keyword, "typeof": .keyword, "var": .keyword, "void": .keyword, "while": .keyword, "with": .keyword, "yield": .keyword, "async": .keyword, "await": .keyword, "get": .keyword, "set": .keyword, "as": .keyword, "interface": .keyword, "type": .keyword, "enum": .keyword, "implements": .keyword, "namespace": .keyword, "declare": .keyword, "abstract": .keyword, "private": .keyword, "protected": .keyword, "public": .keyword, "readonly": .keyword, "keyof": .keyword, "infer": .keyword, "is": .keyword, "satisfies": .keyword, "module": .keyword, "string": .type, "number": .type, "boolean": .type, "any": .type, "unknown": .type, "never": .type, "object": .type, "symbol": .type, "bigint": .type, "true": .constant, "false": .constant, "null": .constant, "undefined": .constant, "NaN": .constant, "Infinity": .constant],

    "python": ["and": .keyword, "as": .keyword, "assert": .keyword, "async": .keyword, "await": .keyword, "break": .keyword, "class": .keyword, "continue": .keyword, "def": .keyword, "del": .keyword, "elif": .keyword, "else": .keyword, "except": .keyword, "finally": .keyword, "for": .keyword, "from": .keyword, "global": .keyword, "if": .keyword, "import": .keyword, "in": .keyword, "is": .keyword, "lambda": .keyword, "nonlocal": .keyword, "not": .keyword, "or": .keyword, "pass": .keyword, "raise": .keyword, "return": .keyword, "try": .keyword, "while": .keyword, "with": .keyword, "yield": .keyword, "match": .keyword, "case": .keyword, "int": .type, "float": .type, "str": .type, "bool": .type, "list": .type, "dict": .type, "set": .type, "tuple": .type, "bytes": .type, "object": .type, "type": .type, "True": .constant, "False": .constant, "None": .constant, "self": .constant, "cls": .constant],

    "go": ["break": .keyword, "case": .keyword, "chan": .keyword, "const": .keyword, "continue": .keyword, "default": .keyword, "defer": .keyword, "else": .keyword, "fallthrough": .keyword, "for": .keyword, "func": .keyword, "go": .keyword, "goto": .keyword, "if": .keyword, "import": .keyword, "interface": .keyword, "map": .keyword, "package": .keyword, "range": .keyword, "return": .keyword, "select": .keyword, "struct": .keyword, "switch": .keyword, "type": .keyword, "var": .keyword, "bool": .type, "byte": .type, "complex64": .type, "complex128": .type, "error": .type, "float32": .type, "float64": .type, "int": .type, "int8": .type, "int16": .type, "int32": .type, "int64": .type, "rune": .type, "string": .type, "uint": .type, "uint8": .type, "uint16": .type, "uint32": .type, "uint64": .type, "uintptr": .type, "any": .type, "true": .constant, "false": .constant, "nil": .constant, "iota": .constant],

    "rust": ["as": .keyword, "async": .keyword, "await": .keyword, "break": .keyword, "const": .keyword, "continue": .keyword, "crate": .keyword, "dyn": .keyword, "else": .keyword, "enum": .keyword, "extern": .keyword, "fn": .keyword, "for": .keyword, "if": .keyword, "impl": .keyword, "in": .keyword, "let": .keyword, "loop": .keyword, "match": .keyword, "mod": .keyword, "move": .keyword, "mut": .keyword, "pub": .keyword, "ref": .keyword, "return": .keyword, "self": .keyword, "static": .keyword, "struct": .keyword, "super": .keyword, "trait": .keyword, "type": .keyword, "unsafe": .keyword, "use": .keyword, "where": .keyword, "while": .keyword, "i8": .type, "i16": .type, "i32": .type, "i64": .type, "i128": .type, "isize": .type, "u8": .type, "u16": .type, "u32": .type, "u64": .type, "u128": .type, "usize": .type, "f32": .type, "f64": .type, "bool": .type, "char": .type, "str": .type, "Self": .type, "true": .constant, "false": .constant, "None": .constant, "Some": .constant, "Ok": .constant, "Err": .constant],

    "c": ["true": .constant, "false": .constant, "NULL": .constant],
    "cpp": ["auto": .keyword, "break": .keyword, "case": .keyword, "const": .keyword, "continue": .keyword, "default": .keyword, "do": .keyword, "else": .keyword, "enum": .keyword, "extern": .keyword, "for": .keyword, "goto": .keyword, "if": .keyword, "inline": .keyword, "register": .keyword, "restrict": .keyword, "return": .keyword, "signed": .keyword, "sizeof": .keyword, "static": .keyword, "struct": .keyword, "switch": .keyword, "typedef": .keyword, "union": .keyword, "unsigned": .keyword, "volatile": .keyword, "while": .keyword, "alignas": .keyword, "alignof": .keyword, "and": .keyword, "asm": .keyword, "catch": .keyword, "class": .keyword, "constexpr": .keyword, "const_cast": .keyword, "decltype": .keyword, "delete": .keyword, "dynamic_cast": .keyword, "explicit": .keyword, "export": .keyword, "friend": .keyword, "mutable": .keyword, "namespace": .keyword, "new": .keyword, "noexcept": .keyword, "operator": .keyword, "or": .keyword, "private": .keyword, "protected": .keyword, "public": .keyword, "reinterpret_cast": .keyword, "static_assert": .keyword, "static_cast": .keyword, "template": .keyword, "this": .keyword, "thread_local": .keyword, "throw": .keyword, "try": .keyword, "typeid": .keyword, "typename": .keyword, "using": .keyword, "virtual": .keyword, "override": .keyword, "final": .keyword, "concept": .keyword, "requires": .keyword, "co_await": .keyword, "co_return": .keyword, "co_yield": .keyword, "char": .type, "double": .type, "float": .type, "int": .type, "long": .type, "short": .type, "void": .type, "bool": .type, "size_t": .type, "ssize_t": .type, "int8_t": .type, "int16_t": .type, "int32_t": .type, "int64_t": .type, "uint8_t": .type, "uint16_t": .type, "uint32_t": .type, "uint64_t": .type, "FILE": .type, "string": .type, "vector": .type, "map": .type, "std": .type, "true": .constant, "false": .constant, "NULL": .constant, "nullptr": .constant],

    "csharp": ["abstract": .keyword, "as": .keyword, "base": .keyword, "break": .keyword, "case": .keyword, "catch": .keyword, "checked": .keyword, "class": .keyword, "const": .keyword, "continue": .keyword, "default": .keyword, "delegate": .keyword, "do": .keyword, "else": .keyword, "enum": .keyword, "event": .keyword, "explicit": .keyword, "extern": .keyword, "finally": .keyword, "fixed": .keyword, "for": .keyword, "foreach": .keyword, "goto": .keyword, "if": .keyword, "implicit": .keyword, "in": .keyword, "interface": .keyword, "internal": .keyword, "is": .keyword, "lock": .keyword, "namespace": .keyword, "new": .keyword, "operator": .keyword, "out": .keyword, "override": .keyword, "params": .keyword, "private": .keyword, "protected": .keyword, "public": .keyword, "readonly": .keyword, "ref": .keyword, "return": .keyword, "sealed": .keyword, "sizeof": .keyword, "stackalloc": .keyword, "static": .keyword, "struct": .keyword, "switch": .keyword, "this": .keyword, "throw": .keyword, "try": .keyword, "typeof": .keyword, "unchecked": .keyword, "unsafe": .keyword, "using": .keyword, "virtual": .keyword, "volatile": .keyword, "while": .keyword, "async": .keyword, "await": .keyword, "var": .keyword, "get": .keyword, "set": .keyword, "init": .keyword, "record": .keyword, "yield": .keyword, "when": .keyword, "where": .keyword, "bool": .type, "byte": .type, "char": .type, "decimal": .type, "double": .type, "float": .type, "int": .type, "long": .type, "object": .type, "sbyte": .type, "short": .type, "string": .type, "uint": .type, "ulong": .type, "ushort": .type, "void": .type, "dynamic": .type, "true": .constant, "false": .constant, "null": .constant],

    "swift": ["associatedtype": .keyword, "class": .keyword, "deinit": .keyword, "enum": .keyword, "extension": .keyword, "fileprivate": .keyword, "func": .keyword, "import": .keyword, "init": .keyword, "inout": .keyword, "internal": .keyword, "let": .keyword, "open": .keyword, "operator": .keyword, "private": .keyword, "protocol": .keyword, "public": .keyword, "rethrows": .keyword, "static": .keyword, "struct": .keyword, "subscript": .keyword, "typealias": .keyword, "var": .keyword, "break": .keyword, "case": .keyword, "continue": .keyword, "default": .keyword, "defer": .keyword, "do": .keyword, "else": .keyword, "fallthrough": .keyword, "for": .keyword, "guard": .keyword, "if": .keyword, "in": .keyword, "repeat": .keyword, "return": .keyword, "switch": .keyword, "where": .keyword, "while": .keyword, "as": .keyword, "catch": .keyword, "is": .keyword, "super": .keyword, "self": .keyword, "Self": .keyword, "throw": .keyword, "throws": .keyword, "try": .keyword, "async": .keyword, "await": .keyword, "some": .keyword, "any": .keyword, "true": .constant, "false": .constant, "nil": .constant],

    "dart": ["abstract": .keyword, "as": .keyword, "assert": .keyword, "async": .keyword, "await": .keyword, "break": .keyword, "case": .keyword, "catch": .keyword, "class": .keyword, "const": .keyword, "continue": .keyword, "covariant": .keyword, "default": .keyword, "deferred": .keyword, "do": .keyword, "dynamic": .keyword, "else": .keyword, "enum": .keyword, "export": .keyword, "extends": .keyword, "extension": .keyword, "external": .keyword, "factory": .keyword, "final": .keyword, "finally": .keyword, "for": .keyword, "get": .keyword, "if": .keyword, "implements": .keyword, "import": .keyword, "in": .keyword, "interface": .keyword, "is": .keyword, "late": .keyword, "library": .keyword, "mixin": .keyword, "new": .keyword, "on": .keyword, "operator": .keyword, "part": .keyword, "required": .keyword, "rethrow": .keyword, "return": .keyword, "set": .keyword, "show": .keyword, "static": .keyword, "super": .keyword, "switch": .keyword, "sync": .keyword, "this": .keyword, "throw": .keyword, "try": .keyword, "typedef": .keyword, "var": .keyword, "void": .keyword, "while": .keyword, "with": .keyword, "yield": .keyword, "int": .type, "double": .type, "num": .type, "bool": .type, "true": .constant, "false": .constant, "null": .constant],

    "php": ["abstract": .keyword, "and": .keyword, "array": .keyword, "as": .keyword, "break": .keyword, "callable": .keyword, "case": .keyword, "catch": .keyword, "class": .keyword, "clone": .keyword, "const": .keyword, "continue": .keyword, "declare": .keyword, "default": .keyword, "do": .keyword, "echo": .keyword, "else": .keyword, "elseif": .keyword, "empty": .keyword, "extends": .keyword, "final": .keyword, "finally": .keyword, "fn": .keyword, "for": .keyword, "foreach": .keyword, "function": .keyword, "global": .keyword, "goto": .keyword, "if": .keyword, "implements": .keyword, "include": .keyword, "include_once": .keyword, "instanceof": .keyword, "insteadof": .keyword, "interface": .keyword, "isset": .keyword, "list": .keyword, "match": .keyword, "namespace": .keyword, "new": .keyword, "or": .keyword, "print": .keyword, "private": .keyword, "protected": .keyword, "public": .keyword, "readonly": .keyword, "require": .keyword, "require_once": .keyword, "return": .keyword, "static": .keyword, "switch": .keyword, "throw": .keyword, "trait": .keyword, "try": .keyword, "unset": .keyword, "use": .keyword, "var": .keyword, "while": .keyword, "xor": .keyword, "yield": .keyword, "true": .constant, "false": .constant, "null": .constant],

    "ruby": ["alias": .keyword, "and": .keyword, "begin": .keyword, "break": .keyword, "case": .keyword, "class": .keyword, "def": .keyword, "do": .keyword, "else": .keyword, "elsif": .keyword, "end": .keyword, "ensure": .keyword, "for": .keyword, "if": .keyword, "in": .keyword, "module": .keyword, "next": .keyword, "not": .keyword, "or": .keyword, "redo": .keyword, "rescue": .keyword, "retry": .keyword, "return": .keyword, "self": .keyword, "super": .keyword, "then": .keyword, "undef": .keyword, "unless": .keyword, "until": .keyword, "when": .keyword, "while": .keyword, "yield": .keyword, "require": .keyword, "require_relative": .keyword, "attr_accessor": .keyword, "attr_reader": .keyword, "attr_writer": .keyword, "true": .constant, "false": .constant, "nil": .constant],

    "lua": ["and": .keyword, "break": .keyword, "do": .keyword, "else": .keyword, "elseif": .keyword, "end": .keyword, "for": .keyword, "function": .keyword, "goto": .keyword, "if": .keyword, "in": .keyword, "local": .keyword, "not": .keyword, "or": .keyword, "repeat": .keyword, "return": .keyword, "then": .keyword, "until": .keyword, "while": .keyword, "true": .constant, "false": .constant, "nil": .constant],

    "sql": ["select": .keyword, "from": .keyword, "where": .keyword, "and": .keyword, "or": .keyword, "not": .keyword, "insert": .keyword, "into": .keyword, "values": .keyword, "update": .keyword, "set": .keyword, "delete": .keyword, "create": .keyword, "table": .keyword, "drop": .keyword, "alter": .keyword, "add": .keyword, "column": .keyword, "index": .keyword, "view": .keyword, "join": .keyword, "inner": .keyword, "left": .keyword, "right": .keyword, "outer": .keyword, "full": .keyword, "cross": .keyword, "on": .keyword, "as": .keyword, "group": .keyword, "by": .keyword, "order": .keyword, "having": .keyword, "limit": .keyword, "offset": .keyword, "distinct": .keyword, "union": .keyword, "all": .keyword, "case": .keyword, "when": .keyword, "then": .keyword, "else": .keyword, "end": .keyword, "is": .keyword, "like": .keyword, "in": .keyword, "between": .keyword, "exists": .keyword, "primary": .keyword, "key": .keyword, "foreign": .keyword, "references": .keyword, "default": .keyword, "constraint": .keyword, "unique": .keyword, "if": .keyword, "begin": .keyword, "commit": .keyword, "rollback": .keyword, "transaction": .keyword, "grant": .keyword, "revoke": .keyword, "with": .keyword, "returning": .keyword, "database": .keyword, "schema": .keyword, "use": .keyword, "show": .keyword, "describe": .keyword, "explain": .keyword, "asc": .keyword, "desc": .keyword, "cascade": .keyword, "trigger": .keyword, "procedure": .keyword, "function": .keyword, "returns": .keyword, "declare": .keyword, "replace": .keyword, "temporary": .keyword, "int": .type, "integer": .type, "bigint": .type, "smallint": .type, "tinyint": .type, "varchar": .type, "char": .type, "text": .type, "boolean": .type, "bool": .type, "date": .type, "datetime": .type, "timestamp": .type, "float": .type, "double": .type, "decimal": .type, "numeric": .type, "serial": .type, "json": .type, "jsonb": .type, "uuid": .type, "blob": .type, "real": .type, "true": .constant, "false": .constant, "null": .constant],

    "shell": ["if": .keyword, "then": .keyword, "else": .keyword, "elif": .keyword, "fi": .keyword, "case": .keyword, "esac": .keyword, "for": .keyword, "select": .keyword, "while": .keyword, "until": .keyword, "do": .keyword, "done": .keyword, "in": .keyword, "function": .keyword, "time": .keyword, "return": .keyword, "exit": .keyword, "break": .keyword, "continue": .keyword, "local": .keyword, "export": .keyword, "readonly": .keyword, "declare": .keyword, "typeset": .keyword, "unset": .keyword, "shift": .keyword, "source": .keyword, "alias": .keyword, "eval": .keyword, "exec": .keyword, "trap": .keyword, "set": .keyword, "echo": .function, "printf": .function, "cd": .function, "pwd": .function, "read": .function, "test": .function, "sudo": .function, "grep": .function, "sed": .function, "awk": .function, "cat": .function, "ls": .function, "rm": .function, "mkdir": .function, "cp": .function, "mv": .function, "chmod": .function, "chown": .function, "curl": .function, "wget": .function, "git": .function, "docker": .function, "kubectl": .function, "apt": .function, "apt-get": .function, "yum": .function, "dnf": .function, "brew": .function, "ssh": .function, "scp": .function, "tar": .function, "make": .function, "npm": .function, "pip": .function, "python3": .function, "systemctl": .function, "true": .constant, "false": .constant],

    "powershell": ["begin": .keyword, "break": .keyword, "catch": .keyword, "class": .keyword, "continue": .keyword, "data": .keyword, "define": .keyword, "do": .keyword, "dynamicparam": .keyword, "else": .keyword, "elseif": .keyword, "end": .keyword, "exit": .keyword, "filter": .keyword, "finally": .keyword, "for": .keyword, "foreach": .keyword, "from": .keyword, "function": .keyword, "if": .keyword, "in": .keyword, "param": .keyword, "process": .keyword, "return": .keyword, "switch": .keyword, "throw": .keyword, "trap": .keyword, "try": .keyword, "until": .keyword, "using": .keyword, "var": .keyword, "while": .keyword],

    "bat": ["echo": .keyword, "set": .keyword, "if": .keyword, "else": .keyword, "goto": .keyword, "call": .keyword, "exit": .keyword, "for": .keyword, "in": .keyword, "do": .keyword, "not": .keyword, "exist": .keyword, "defined": .keyword, "errorlevel": .keyword, "setlocal": .keyword, "endlocal": .keyword, "pause": .keyword, "shift": .keyword, "off": .keyword, "on": .keyword],

    "dockerfile": ["FROM": .keyword, "RUN": .keyword, "CMD": .keyword, "LABEL": .keyword, "MAINTAINER": .keyword, "EXPOSE": .keyword, "ENV": .keyword, "ADD": .keyword, "COPY": .keyword, "ENTRYPOINT": .keyword, "VOLUME": .keyword, "USER": .keyword, "WORKDIR": .keyword, "ARG": .keyword, "ONBUILD": .keyword, "STOPSIGNAL": .keyword, "HEALTHCHECK": .keyword, "SHELL": .keyword, "AS": .keyword, "from": .keyword, "run": .keyword, "cmd": .keyword, "label": .keyword, "expose": .keyword, "env": .keyword, "add": .keyword, "copy": .keyword, "entrypoint": .keyword, "volume": .keyword, "user": .keyword, "workdir": .keyword, "arg": .keyword, "as": .keyword],

    "makefile": ["ifeq": .keyword, "ifneq": .keyword, "ifdef": .keyword, "ifndef": .keyword, "else": .keyword, "endif": .keyword, "include": .keyword, "define": .keyword, "endef": .keyword, "export": .keyword, "override": .keyword, "unexport": .keyword, "vpath": .keyword],

    "json": ["true": .constant, "false": .constant, "null": .constant],
    "yaml": ["true": .constant, "false": .constant, "null": .constant, "yes": .constant, "no": .constant, "on": .constant, "off": .constant, "True": .constant, "False": .constant, "TRUE": .constant, "FALSE": .constant, "Null": .constant, "NULL": .constant, "Yes": .constant, "No": .constant],

    "toml": ["true": .constant, "false": .constant],
    "ini": ["true": .constant, "false": .constant, "yes": .constant, "no": .constant, "on": .constant, "off": .constant, "True": .constant, "False": .constant],
    "css": ["inherit": .constant, "initial": .constant, "unset": .constant, "none": .constant, "auto": .constant, "transparent": .constant, "currentColor": .constant, "important": .constant],
    "log": ["ERROR": .error, "ERR": .error, "FATAL": .error, "CRITICAL": .error, "CRIT": .error, "PANIC": .error, "SEVERE": .error, "EMERG": .error,
        "ALERT": .error, "Error": .error, "Fatal": .error, "Panic": .error, "error": .error, "fatal": .error, "panic": .error, "failed": .error,
        "Failed": .error, "FAILED": .error, "FAILURE": .error, "Exception": .error, "WARN": .warning, "WARNING": .warning, "Warning": .warning,
        "Warn": .warning, "warning": .warning, "warn": .warning, "INFO": .info, "NOTICE": .info, "Info": .info, "Notice": .info, "info": .info,
        "notice": .info, "DEBUG": .comment, "TRACE": .comment, "VERBOSE": .comment, "Debug": .comment, "Trace": .comment, "debug": .comment,
        "trace": .comment]
]
// swiftlint:enable line_length
