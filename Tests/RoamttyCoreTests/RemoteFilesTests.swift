import Foundation
import XCTest
@testable import RoamttyCore

final class RemoteFilesTests: XCTestCase {
    /// Android's terminalPathsResolveFromTheShellDirectory.
    func testTerminalPathsResolveFromTheShellDirectory() {
        XCTAssertEqual(resolveTerminalPath(directory: "/home/v/blog", path: "src/Post.tsx"), "/home/v/blog/src/Post.tsx")
        XCTAssertEqual(resolveTerminalPath(directory: "/home/v/blog/", path: "./a.ts"), "/home/v/blog/a.ts")
        XCTAssertEqual(resolveTerminalPath(directory: "/", path: "a.ts"), "/a.ts")
        XCTAssertEqual(resolveTerminalPath(directory: nil, path: "/etc/hosts.conf"), "/etc/hosts.conf")
        XCTAssertEqual(resolveTerminalPath(directory: nil, path: "~/notes/a.md"), "notes/a.md")
        XCTAssertNil(resolveTerminalPath(directory: nil, path: "src/a.ts"))
        XCTAssertNil(resolveTerminalPath(directory: "relative", path: "src/a.ts"))
        XCTAssertNil(resolveTerminalPath(directory: "/home/v", path: "~bob/a.ts"))
    }
    func testPathsPreserveNamesAndRejectUnsafeDeleteTargets() {
        XCTAssertEqual(joinRemotePath(directory: "/work///", name: "a b"), "/work/a b")
        XCTAssertEqual(joinRemotePath(directory: "/", name: ""), "/")
        XCTAssertEqual(parentRemotePath("/work/project/"), "/work")
        XCTAssertEqual(parentRemotePath("relative"), "/")
        XCTAssertTrue(isValidRemoteDirectory("/work/project "))
        XCTAssertEqual(validWorkingDirectory("/work/project \r\n"), "/work/project ")
        for path in ["relative", "/tmp\n", "/tmp\r", "/tmp\0", String(repeating: "/", count: 4097)] {
            XCTAssertFalse(isValidRemoteDirectory(path), path)
        }
        for name in ["", ".", "..", "a/b", "a\\b", "a\n", "a\0"] { XCTAssertFalse(isSafeRemoteEntryName(name)) }
        for path in ["", "/", "///", "/a/../b", "a/./b", "/x\r"] { XCTAssertFalse(isSafeRemoteDeletePath(path)) }
        XCTAssertTrue(isSafeRemoteDeletePath("/work/a b/"))
    }

    func testTerminalPathTextQuotesNamesAndRefusesControlCharacters() {
        XCTAssertEqual(terminalPathText("/work/a b/中文 'x'.txt"), "'/work/a b/中文 '\\''x'\\''.txt'")
        // Ctrl-U would clear the typed line and CR submit what follows, however the path is quoted.
        for path in ["", "/tmp/\u{15}printf REVIEW_EXECUTED\r", "/tmp/a\u{1b}[201~b", "/tmp/a\u{7f}", "/tmp/a\u{9b}", "/tmp/a\tb"] {
            XCTAssertNil(terminalPathText(path), path)
        }
    }

    func testFuzzyNamesNormalizeWidthAndHandleWrappedCopies() {
        XCTAssertEqual(remoteNameMatchRank(name: "APP.APK", query: "app.apk"), 0)
        XCTAssertEqual(remoteNameMatchRank(name: "release-debug.apk", query: "rel"), 1)
        XCTAssertEqual(remoteNameMatchRank(name: "release-debug.apk", query: "debug"), 2)
        XCTAssertEqual(remoteNameMatchRank(name: "iTermux-debug.apk", query: "ITMDBGAPK"), 3)
        XCTAssertNotNil(remoteNameMatchRank(name: "release-candidate-arm64-signed.apk", query: "ＲＥＬＥＡＳＥ arm64 signed"))
        XCTAssertNotNil(remoteNameMatchRank(name: "release-candidate-arm64", query: "release-candi\ndate-arm64"))
        XCTAssertNil(remoteNameMatchRank(name: "release.apk", query: "release x86"))
        // An empty or blank query matches every name, whatever it holds.
        XCTAssertEqual(remoteNameMatchRank(name: "release.apk", query: ""), 0)
        XCTAssertEqual(remoteNameMatchRank(name: "\u{1}odd\u{3000}name", query: " \n "), 0)
        XCTAssertEqual(remotePathSearch(directory: "/work/project", query: "../assets/图"), RemotePathSearch(directory: "/work/assets", name: "图"))
        XCTAssertEqual(remotePathSearch(directory: "/work", query: "~/src/dist/"), RemotePathSearch(directory: "src/dist", name: ""))
        XCTAssertEqual(remotePathSearch(directory: "", query: "../dist/x"), RemotePathSearch(directory: "../dist", name: "x"))
    }

    func testSearchResolvesEveryFuzzyBranchWithReadBudgetAndPartialErrors() async throws {
        let tree = ["/work": ["dist", "dist-backup", ".dist"], "/work/dist": ["build-output"], "/work/dist-backup": ["build-output"]]
        func list(_ path: String) throws -> RemoteDirectory {
            let resolved = path.isEmpty ? "/work" : path
            return RemoteDirectory(path: resolved, entries: (tree[resolved] ?? []).map { RemoteEntry(name: $0, path: joinRemotePath(directory: resolved, name: $0), isDirectory: true) })
        }
        let result = try await resolveRemoteSearchDirectories(directory: "/work", prefix: "DST/bld/", showHidden: false, listDirectory: list)
        XCTAssertEqual(result.directories.map(\.path), ["/work/dist/build-output", "/work/dist-backup/build-output"])
        let limited = try await resolveRemoteSearchDirectories(directory: "/work", prefix: "dst/", showHidden: false, maxDirectories: 2, listDirectory: list)
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(limited.directories.map(\.path), ["/work/dist"])
        let partial = try await resolveRemoteSearchDirectories(directory: "/work", prefix: "dst/", showHidden: false) { path in
            if path == "/work/dist" { throw RoamError.rejected }
            return try list(path)
        }
        XCTAssertTrue(partial.unreadable)
        XCTAssertEqual(partial.directories.map(\.path), ["/work/dist-backup"])
        do {
            _ = try await resolveRemoteSearchDirectories(directory: "/work", prefix: "dst/", showHidden: false) { path in
                if path == "/work/dist" { throw CancellationError() }
                return try list(path)
            }
            XCTFail("Search cancellation must propagate")
        } catch is CancellationError { }
    }

    func testDownloadsReserveOriginalNamesBeforeGeneratedSuffixes() {
        let paths = ["/a/report.txt", "/b/REPORT.TXT", "/c/report (2).txt", "/d/report.txt", "/a/.env", "/b/.env"]
        let names = downloadNames(paths: paths)
        XCTAssertEqual(paths.compactMap { names[$0] }, ["report.txt", "REPORT (3).TXT", "report (2).txt", "report (4).txt", ".env", ".env (2)"])
    }

    func testKindsAndMetadataRemainUsefulWithoutSize() throws {
        XCTAssertEqual(remoteFileKind(name: "Dockerfile"), .code)
        XCTAssertEqual(remoteFileKind(name: ".env.local"), .config)
        XCTAssertEqual(remoteFileKind(name: "photo.JPEG"), .image)
        XCTAssertEqual(remoteFileKind(name: "server", permissions: 0o100755), .executable)
        XCTAssertEqual(remoteFileKind(name: "notes.md", isDirectory: true), .directory)
        let entry = RemoteEntry(name: "link", path: "/link", isDirectory: false, isSymlink: true, size: nil, mtime: 123, permissions: 0o120777)
        XCTAssertEqual(try JSONDecoder().decode(RemoteEntry.self, from: JSONEncoder().encode(entry)), entry)
        XCTAssertEqual(entry.id, "/link")
    }

    func testStrictTextDecodingSupportsBOMAndTruncatedUnicode() {
        let text = "  中文\t😀\nnext\r\n"
        for data in [Data(text.utf8), Data([0xef, 0xbb, 0xbf]) + Data(text.utf8), Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)!, Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)!] {
            XCTAssertEqual(RemoteFileContent(data: data, size: Int64(data.count), truncated: false).text, text)
        }
        XCTAssertEqual(RemoteFileContent(data: Data(), size: 0, truncated: false).text, "")
        let cutUTF8 = Data("hello中".utf8.dropLast())
        XCTAssertEqual(RemoteFileContent(data: cutUTF8, size: 8, truncated: true).text, "hello")
        XCTAssertNil(RemoteFileContent(data: cutUTF8, size: 7, truncated: false).text)
        let cutUTF16 = Data([0xff, 0xfe]) + Data("hello😀".data(using: .utf16LittleEndian)!.dropLast(2))
        XCTAssertEqual(RemoteFileContent(data: cutUTF16, size: nil, truncated: true).text, "hello")
        for data in [Data([1, 2, 3]), Data("PNG\0binary".utf8), Data([0xff, 0x12]), Data([0xe2, 0x28]), Data([0xf5]), Data([0xff, 0xfe, 0x00, 0xdc])] {
            XCTAssertNil(RemoteFileContent(data: data, size: nil, truncated: true).text)
        }
    }
}

final class SyntaxPreviewTests: XCTestCase {
    private func tokens(_ source: String, _ language: CodeLanguage) -> [(String, TokenType)] {
        SyntaxHighlighter.highlight(source, language).lines.flatMap { line in
            stride(from: 0, to: line.spans.count, by: 3).map { index in
                ((line.text as NSString).substring(with: NSRange(location: line.spans[index], length: line.spans[index + 1] - line.spans[index])), TokenType(rawValue: line.spans[index + 2])!)
            }
        }
    }
    private func type(_ word: String, in tokens: [(String, TokenType)]) -> TokenType? { tokens.first { $0.0 == word }?.1 }

    func testKotlinCommentsStringsDeclarationsAndImportPaths() {
        let result = tokens("@Composable\nfun greet(name: String): Int {\nval count = 42 // answer\nprintln(\"hi $name\")\nreturn count.size\n}\nimport kotlinx.coroutines.* // all", Languages.kotlin)
        for (word, expected) in [("@Composable", TokenType.meta), ("fun", .keyword), ("greet", .function), ("String", .type), ("42", .number),
            ("// answer", .comment), ("println", .function), ("\"hi $name\"", .string), ("size", .property)] {
            XCTAssertEqual(type(word, in: result), expected, word)
        }
        XCTAssertNil(type("coroutines", in: result))
        XCTAssertEqual(type("// all", in: result), .comment)
        let multiline = SyntaxHighlighter.highlight("a /* one\ntwo */ b\n\"\"\"x\ny\"\"\"", Languages.kotlin)
        XCTAssertEqual(multiline.lineCount, 4)
        XCTAssertEqual(multiline.lines[1].spans, [0, 6, TokenType.comment.rawValue])
        XCTAssertEqual(multiline.lines[3].spans, [0, 4, TokenType.string.rawValue])
    }

    func testPythonShellYAMLJSONAndRustTokens() {
        let python = tokens("@cache\ndef run(self):\nreturn f'{x}' if True else None\n'''doc'''", Languages.python)
        XCTAssertEqual(type("@cache", in: python), .meta)
        XCTAssertEqual(type("f'{x}'", in: python), .string)
        XCTAssertEqual(type("'''doc'''", in: python), .string)
        let shell = tokens("echo $HOME ${PATH} a#b # note", Languages.shell)
        XCTAssertEqual(type("${PATH}", in: shell), .variable)
        XCTAssertEqual(type("# note", in: shell), .comment)
        XCTAssertNil(type("#b # note", in: shell))
        let yaml = tokens("services:\n  - name: web # main\nports: [80]\nenabled: yes", Languages.yaml)
        XCTAssertEqual(type("services", in: yaml), .property)
        XCTAssertEqual(type("name", in: yaml), .property)
        XCTAssertEqual(type("yes", in: yaml), .constant)
        let json = tokens("{\"name\": \"😀\", \"n\": -1.5e3}", Languages.json)
        XCTAssertEqual(type("\"name\"", in: json), .property)
        XCTAssertEqual(type("\"😀\"", in: json), .string)
        XCTAssertEqual(type("1.5e3", in: json), .number)
        let rust = tokens("fn f<'a>(x: &'a str) -> Vec<u8> { println!(\"{}\", 'c'); }", Languages.rust)
        XCTAssertEqual(type("println!", in: rust), .function)
        XCTAssertEqual(type("'c'", in: rust), .string)
        XCTAssertEqual(type("str", in: rust), .type)
    }

    func testMarkupMarkdownDiffAndLogTokens() {
        let markup = tokens("<!-- c --><div class=\"x\">&amp;<script>let a = 1</script></div>", Languages.html)
        for (word, expected) in [("<!-- c -->", TokenType.comment), ("div", .tag), ("class", .attribute), ("\"x\"", .string), ("&amp;", .constant), ("let", .keyword)] {
            XCTAssertEqual(type(word, in: markup), expected, word)
        }
        let markdown = tokens("# Title\n- item with `code` and **bold** [link](http://x)\n```kotlin\nval x = 1\n```", Languages.markdown)
        for (word, expected) in [("# Title", TokenType.heading), ("- ", .keyword), ("`code`", .string), ("**bold**", .strong), ("[link]", .link), ("val", .keyword), ("```kotlin", .meta)] {
            XCTAssertEqual(type(word, in: markdown), expected, word)
        }
        let diff = tokens("@@ -1 +1 @@\n-old\n+new", Languages.diff)
        XCTAssertEqual(type("-old", in: diff), .deleted)
        XCTAssertEqual(type("+new", in: diff), .inserted)
        let log = tokens("2026-10-03 12:00:01 ERROR db failed, WARN retry https://example.com/x", Languages.log)
        XCTAssertEqual(type("2026-10-03 12:00:01", in: log), .constant)
        XCTAssertEqual(type("https://example.com/x", in: log), .link)
    }

    func testDisplayRowsExpandTabsCountWideTextAndPreserveUTF16Offsets() {
        let source = "a\tb\n" + String(repeating: "x", count: 4005) + "\r\nend"
        let document = SyntaxHighlighter.highlight(source, Languages.plain)
        XCTAssertEqual(document.lines.map(\.number), [1, 2, 0, 0, 3])
        XCTAssertEqual(document.lines[0].text, "a   b")
        XCTAssertEqual(document.maxColumns, 2000)
        XCTAssertEqual(SyntaxHighlighter.highlight("中文ab", Languages.plain).maxColumns, 6)
        let samples = [(Languages.kotlin, "class A { fun b() = \"\"\"\nx\n\"\"\" /* c\n */ }"),
            (Languages.markdown, "# h\n```py\ndef f():\n pass\n```\ntext *em* `c`"), (Languages.html, "<style>a { color: red }</style><p a=b>t</p>"),
            (Languages.swift, "let emoji = \"😀\"; let x = 4")]
        for (language, text) in samples {
            for row in SyntaxHighlighter.highlight(text, language).lines {
                var previous = 0
                for index in stride(from: 0, to: row.spans.count, by: 3) {
                    XCTAssertGreaterThanOrEqual(row.spans[index], previous)
                    XCTAssertGreaterThan(row.spans[index + 1], row.spans[index])
                    XCTAssertLessThanOrEqual(row.spans[index + 1], row.text.utf16.count)
                    previous = row.spans[index + 1]
                }
            }
        }
        XCTAssertEqual(Languages.detect(fileName: "Dockerfile.prod").id, "dockerfile")
        XCTAssertEqual(Languages.detect(fileName: "deploy", firstLine: "#!/usr/bin/env python3").id, "python")
    }

    func testQuarterMegabytePreviewCompletesWithAllLines() {
        let line = "fun f(x: Int) = \"value $x\" // comment 123\n"
        let document = SyntaxHighlighter.highlight(String(repeating: line, count: 6600), Languages.kotlin)
        XCTAssertEqual(document.lineCount, 6601)
        XCTAssertEqual(document.lines[6500].spans.count / 3, 5)
    }

    func testLanguageAliasesAndShebangsFollowAndroidDetection() {
        for (name, expected) in [("CMakeLists.txt", "makefile"), ("Cargo.lock", "toml"), ("view.svelte", "html"), ("analysis.ipynb", "json"),
            ("styles.scss", "scss"), (".zsh_history", "shell"), ("config", "ini")] {
            XCTAssertEqual(Languages.detect(fileName: name).id, expected)
        }
        XCTAssertEqual(Languages.forFence("typescript{.numberLines}")?.id, "typescript")
        XCTAssertEqual(Languages.detect(fileName: "run", firstLine: "#!/usr/bin/env ruby").id, "ruby")
        XCTAssertEqual(Languages.detect(fileName: "page", firstLine: "<!DOCTYPE html>").id, "html")
    }
}

final class MarkdownPreviewTests: XCTestCase {
    func testRelativeImagePathsNormalizeWithoutEscapingRemoteRoot() {
        let cases: [(String, String, String)] = [
            ("/repo/docs", "image.png", "/repo/docs/image.png"),
            ("/repo/docs", "./nested/../image.png?raw=1#preview", "/repo/docs/image.png"),
            ("/repo/docs", "../images/./logo.png", "/repo/images/logo.png"),
            ("/repo/docs", "/shared/../image.png?download", "/image.png"),
            ("/repo/docs", "../../../../image.png", "/image.png"),
            ("/", "../../", "/"),
            ("docs/guide", "../../images/logo.png", "images/logo.png"),
            ("docs", "../../../image.png", "image.png"),
            ("docs", "/image.png", "/image.png"),
            ("/repo//docs/.", "", "/repo/docs"),
            ("/repo/docs", "?raw=1#preview", "/repo/docs"),
            ("/repo/docs", "image.png#preview?ignored", "/repo/docs/image.png"),
            ("/repo/docs", "图片%23literal.png", "/repo/docs/图片%23literal.png")
        ]
        for (directory, source, expected) in cases {
            XCTAssertEqual(resolveRelativeRemotePath(directory: directory, source: source), expected,
                           "directory=\(directory), source=\(source)")
        }
    }

    func testMarkdownImagePrefixesSeparateExplicitLinksFromSFTPOnlyPaths() {
        for source in ["https://example.invalid/image.png", "http://127.0.0.1:1/image.png", "mailto:docs@example.invalid"] {
            XCTAssertEqual(markdownExternalURL(source)?.absoluteString, source)
            XCTAssertNil(markdownRemoteImagePath(directory: "/repo", source: source))
        }
        for source in ["http://[", "https://[", "mailto:\u{0}", "data:image/png;base64,AAAA"] {
            XCTAssertNil(markdownRemoteImagePath(directory: "/repo", source: source), "Raw web/mail/data prefixes never load automatically, even when the URL is malformed")
        }
        let remoteOnly: [(String, String)] = [
            ("plot:final.png", "/repo/plot:final.png"),
            ("file:///etc/passwd", "/repo/file:/etc/passwd"),
            ("ftp://host/image.png", "/repo/ftp:/host/image.png"),
            ("javascript:alert(1)", "/repo/javascript:alert(1)"),
            ("ssh://host/path", "/repo/ssh:/host/path"),
            ("unknown://host/image.png", "/repo/unknown:/host/image.png"),
            ("HTTPS://example.invalid/image.png", "/repo/HTTPS:/example.invalid/image.png"),
            ("http:image.png", "/repo/http:image.png"),
            ("https:image.png", "/repo/https:image.png")
        ]
        for (source, expected) in remoteOnly {
            XCTAssertNil(markdownExternalURL(source), "Only Android's explicit web/mail prefixes may open")
            XCTAssertEqual(markdownRemoteImagePath(directory: "/repo", source: source), expected,
                           "URI-like filename text resolves only inside the existing SSH connection")
        }
        XCTAssertNil(markdownExternalURL("data:image/png;base64,AAAA"))
        XCTAssertNil(markdownExternalURL("./docs/guide.md"))
        XCTAssertNil(markdownExternalURL("#section"))
        XCTAssertEqual(markdownRemoteImagePath(directory: "/repo/docs", source: "./nested/../image.png?raw=1#preview"), "/repo/docs/image.png")
        XCTAssertEqual(markdownRemoteImagePath(directory: "/repo", source: "images/file:name.png"), "/repo/images/file:name.png")
        XCTAssertEqual(markdownRemoteImagePath(directory: "/repo", source: "//shared/image.png"), "/shared/image.png")
    }

    func testMarkdownImageParserPreservesSourceForRemoteResolution() {
        XCTAssertEqual(MarkdownParser.parse("![Preview](./nested/../image.png?raw=1#preview)"),
                       [.image("Preview", "./nested/../image.png?raw=1#preview")])
    }

    func testHeadingsBreaksAndNestedInlineStyles() {
        let blocks = MarkdownParser.parse("# Title #\n\none  \ntwo\\\nthree\n\nSub\n---\n\n[**docs** page](./docs/README.md)")
        XCTAssertEqual(blocks[0], .heading(1, MdText(text: "Title", spans: [])))
        XCTAssertEqual(blocks[1], .paragraph(MdText(text: "one\ntwo\nthree", spans: [])))
        XCTAssertEqual(blocks[2], .heading(2, MdText(text: "Sub", spans: [])))
        guard case .paragraph(let text) = blocks[3] else { return XCTFail("Expected link paragraph") }
        XCTAssertEqual(text.text, "docs page")
        XCTAssertEqual(text.spans.first(where: { $0.style == .bold })?.end, 4)
        XCTAssertEqual(text.spans.first(where: { $0.style == .link })?.url, "./docs/README.md")
    }

    func testNestedTaskListsTablesAndReferenceLinks() {
        let blocks = MarkdownParser.parse("- a\n  continued\n  - b\n    - [x] done\n- [ ] todo\n\n3. third\n4) fourth")
        let depths = blocks.compactMap { block -> Int? in if case .listItem(let depth, _, _, _) = block { return depth }; return nil }
        XCTAssertEqual(depths, [0, 1, 2, 0, 0, 0])
        guard case .listItem(_, _, let checked, let text) = blocks[2] else { return XCTFail("Expected task") }
        XCTAssertEqual(checked, true); XCTAssertEqual(text.text, "done")
        let table = MarkdownParser.parse("| Name | Size | Note |\n|:--|--:|:-:|\n| `a|b` | 1 | x \\| y |\n| c |")
        guard case .table(let header, let alignments, let rows) = table[0] else { return XCTFail("Expected table") }
        XCTAssertEqual(header.map(\.text), ["Name", "Size", "Note"])
        XCTAssertEqual(alignments, [.start, .end, .center])
        XCTAssertEqual(rows.map { $0.map(\.text) }, [["a|b", "1", "x | y"], ["c", "", ""]])
        let refs = MarkdownParser.parse("Read [the guide][g] or [g].\n\n[g]: https://guide.dev \"Guide\"")
        guard case .paragraph(let reference) = refs[0] else { return XCTFail("Expected reference paragraph") }
        XCTAssertEqual(refs.count, 1); XCTAssertEqual(reference.text, "Read the guide or g.")
    }

    func testFencesKeepLeadingBlankLinesAndUnicodeSpansUseUTF16() {
        let blocks = MarkdownParser.parse("```swift\n\nlet x = 1\n```\n\n😀 **bold**")
        XCTAssertEqual(blocks[0], .code("swift", "\nlet x = 1"))
        guard case .paragraph(let text) = blocks[1], let span = text.spans.first else { return XCTFail("Expected styled paragraph") }
        XCTAssertEqual((text.text as NSString).substring(with: NSRange(location: span.start, length: span.end - span.start)), "bold")
    }

    func testReadmeHTMLImagesAndCommentsBecomeSafeNativeBlocks() {
        // swiftlint:disable:next line_length - one Markdown document
        let blocks = MarkdownParser.parse("![logo](img/logo.png \"Logo\")\n\n---\n\n<p align=\"center\">\n<img src=\"docs/shot.png\" alt=\"Shot\">\n<br>Mobile <b>SSH</b>\n</p>\n\n<!-- hidden\ncomment -->")
        XCTAssertEqual(blocks, [.image("logo", "img/logo.png"), .rule, .image("Shot", "docs/shot.png"), .paragraph(MdText(text: "Mobile SSH", spans: []))])
    }
}
