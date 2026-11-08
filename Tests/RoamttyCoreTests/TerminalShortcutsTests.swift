import Foundation
import XCTest
@testable import RoamttyCore

final class TerminalShortcutsTests: XCTestCase {
    private let rule = String(repeating: "─", count: 80)

    private func detect(_ screen: String) -> ScreenApp {
        let rows = screen.components(separatedBy: "\n")
        return ScreenApp.detect(rows: rows, cursorRow: rows.firstIndex { $0.contains("<cursor>") } ?? 0)
    }

    // These screens are the real fixtures in Android's ScreenAppTest.kt.
    func testAndroidClaudePromptFixturesWithAndWithoutFooter() {
        XCTAssertEqual(detect("""
             ▐▛███▛█   Claude Code v2.1.292
            \(rule)
            ❯ <cursor>
            \(rule)
              ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
            """), .claude)
        XCTAssertEqual(detect("""
            ⏺ Done.
            \(rule)
            ❯ fix the build <cursor>
            \(rule)
            """), .claude)
    }

    func testAndroidCodexFooterTakesPrecedenceOverSharedClaudeHelpText() {
        XCTAssertEqual(detect("""
              /review - review any changes and find issues

            › Ask Codex to do anything <cursor>

              GPT-6-Astra xhigh · Context 100% left · weekly 65% left
              ← for agents · ? for shortcuts                      ⚠ 2 warnings · f2 to view
            """), .codex)
    }

    func testAndroidCodexPromptOnPhoneWideScreen() {
        // A phone-wide screen cuts the footer before "Context", while Codex's own working row and question say
        // "esc to interrupt" and "? for shortcuts" as Claude Code does: the "› " prompt still tells.
        XCTAssertEqual(detect("""
            • Working (1m 48s • esc to interrupt)

            • Queued follow-up inputs
              ? 1 question
                ⇧← to answer

            › <cursor>Ask Codex to do anything                Esc

              GPT-6-Astra xhigh · ~/work/roamtty · Conte…
              ? for shortcuts
            """), .codex)
    }

    func testAndroidGrokBoxFixture() {
        XCTAssertEqual(detect("""
              ╭──────────────────────────────────────────────────────────────────────────╮
              │ ❯ <cursor>                                                               │
              ╰────────────────────────────────────── Grok 4.7 (xhigh) · always-approve ─╯
                                                                        Grok Build  1.0.46
            """), .grok)
    }

    func testAndroidGeminiFooterTakesPrecedenceOverCodexContextPattern() {
        XCTAssertEqual(detect("""
            ╭──────────────────────────────────────────────────────────────╮
            │ >   Type your message or @path/to/file <cursor>              │
            ╰──────────────────────────────────────────────────────────────╯
            ~/proj            no sandbox            gemini-2.5-pro (100% context left)
            """), .gemini)
    }

    func testAndroidShellAfterAgentExitRejectsStaleBannerAndPrompt() {
        XCTAssertEqual(detect("""
             ▐▛███▛█   Claude Code v2.1.292
            \(rule)
            ❯ /exit
            \(rule)
              ⏵⏵ auto mode on (shift+tab to cycle)
            Resume this session with: claude --resume 1234
            (base)
            v@dev:~/work/roamtty$
            $ ls
            README.md  app  docs
            build.gradle.kts  settings.gradle.kts
            v@dev:~/work/roamtty$ <cursor>
            """), .shell)
        XCTAssertEqual(detect("v@dev:~$ <cursor>"), .shell)
        XCTAssertEqual(detect("Claude Code / Codex / Grok / Gemini\nv@dev:~$ <cursor>"), .shell)
    }

    func testCursorNeighborhoodBoundariesAndClamping() {
        var rows = Array(repeating: "", count: 24)
        rows[7] = "esc to interrupt"
        XCTAssertEqual(ScreenApp.detect(rows: rows, cursorRow: 10), .claude)
        rows[7] = ""
        rows[6] = "esc to interrupt"
        XCTAssertEqual(ScreenApp.detect(rows: rows, cursorRow: 10), .shell)
        rows[18] = "gemini-2.5-pro"
        XCTAssertEqual(ScreenApp.detect(rows: rows, cursorRow: 10), .gemini)
        rows[18] = ""
        rows[19] = "gemini-2.5-pro"
        XCTAssertEqual(ScreenApp.detect(rows: rows, cursorRow: 10), .shell)
        XCTAssertEqual(ScreenApp.detect(rows: [], cursorRow: Int.max), .shell)
        XCTAssertEqual(ScreenApp.detect(rows: ["› ask"], cursorRow: Int.min), .codex)
        XCTAssertEqual(ScreenApp.detect(rows: ["shell$"], cursorRow: Int.max), .shell)
    }

    func testPromptAndFooterVariantsMatchAndroid() {
        XCTAssertEqual(detect("  › Ask here <cursor>"), .codex)
        XCTAssertEqual(detect("› previous agent prompt\nshell$ <cursor>"), .shell)
        XCTAssertEqual(detect("<cursor>\n  Context 45% left"), .codex)
        XCTAssertEqual(detect("<cursor>\n  45% context left"), .codex)
        XCTAssertEqual(detect("<cursor>\n  GEMINI-3-pro"), .gemini)
        XCTAssertEqual(detect("<cursor>\n  notgemini-3-pro"), .shell)
        XCTAssertEqual(detect("<cursor>\nCtrl+x:shortcuts"), .grok)
        XCTAssertEqual(detect("<cursor>\n  ╰──── always-approve ─╯   "), .grok)
        XCTAssertEqual(detect("<cursor>\nGrok Build 1.0.46"), .shell)
        XCTAssertEqual(detect("<cursor>\n⏸ plan mode"), .claude)
        XCTAssertEqual(detect("\(String(repeating: "─", count: 19))\n❯ <cursor>\n\(rule)"), .shell)
        XCTAssertEqual(detect("\(rule)\n❯ <cursor>"), .shell)
        XCTAssertEqual(detect("\(rule)\n❯ long input\nwrapped input <cursor>\n\(rule)"), .claude)
    }

    func testSessionAgentPicksItsTable() {
        XCTAssertEqual(CodingAgent.allCases.map(ScreenApp.init), [.claude, .codex, .grok])
    }

    func testAgentTablesPreserveAndroidOrderHintsAndWireBytes() {
        // Wire bytes are deliberately numeric: confusing Ctrl+P with Alt+P or replacing
        // Shift arrows with plain arrows changes the remote application's action.
        // swiftlint:disable:next large_tuple - one row per app: keys, labels, titles and bytes
        let fixtures: [(ScreenApp, [String], [String], [String], [[UInt8]])] = [
            (.claude, ["^T", "^O", "Esc²", "⇧Tab", "^C", "^B", "⌥P"],
             ["任务", "详情", "回退", "模式", "取消", "后台", "模型"],
             ["Tasks", "Details", "Rewind", "Mode", "Cancel", "Background", "Model"],
             [[20], [15], [27], [27, 91, 90], [3], [2], [27, 112]]),
            (.codex, ["^T", "^O", "Esc²", "⇧Tab", "⇧←", "⇧→", "^C"],
             ["记录", "复制", "编辑", "计划", "回答", "返回", "取消"],
             ["Log", "Copy", "Edit", "Plan", "Answer", "Back", "Cancel"],
             [[20], [15], [27], [27, 91, 90], [27, 91, 49, 59, 50, 68], [27, 91, 49, 59, 50, 67], [3]]),
            (.grok, ["^T", "^O", "^P", "⇧Tab", "^C", "^X"],
             ["任务", "自动", "命令", "模式", "中断", "快捷"],
             ["Tasks", "Auto", "Palette", "Mode", "Stop", "Keys"],
             [[20], [15], [16], [27, 91, 90], [3], [24]]),
            (.gemini, ["^T", "^O", "^Y", "⇧Tab", "Esc²", "^L", "^C"],
             ["任务", "展开", "YOLO", "模式", "回退", "清屏", "取消"],
             ["Tasks", "More", "YOLO", "Mode", "Rewind", "Clear", "Cancel"],
             [[20], [15], [25], [27, 91, 90], [27], [12], [3]])
        ]
        for (app, labels, chinese, english, bytes) in fixtures {
            let items = app.shortcuts
            XCTAssertEqual(items.map(\.label), labels, app.rawValue)
            XCTAssertEqual(items.map { $0.hint(english: false) }, chinese, app.rawValue)
            XCTAssertEqual(items.map { $0.hint(english: true) }, english, app.rawValue)
            XCTAssertEqual(Set(items.map(\.tag)).count, items.count)
            for (item, expected) in zip(items, bytes) {
                guard case let .keys(keys, repeatAfter) = item.action else {
                    return XCTFail("Expected literal keys for \(app).\(item.tag)")
                }
                XCTAssertEqual(Array(keys.utf8), expected, "\(app).\(item.tag)")
                if item.tag == "pet-escape-twice" {
                    XCTAssertEqual(repeatAfter, 0.12, "Double Escape must be two separately timed sends")
                    XCTAssertEqual(keys.utf8.count, 1)
                } else {
                    XCTAssertNil(repeatAfter, "Only double Escape repeats")
                }
            }
        }
    }

    func testShellProvidesStickyModifiersFunctionSubmenuAndShellKeys() {
        let items = ScreenApp.shell.shortcuts
        XCTAssertEqual(items.map(\.label), ["Fn", "Ctrl", "Shift", "Tab", "^C", "^R", "^D", "^Z"])
        XCTAssertEqual(items.map(\.hintZh), ["F1–12", "下一键", "下一键", "补全", "中断", "历史", "退出", "挂起"])
        XCTAssertEqual(items.map(\.hintEn), ["F1–12", "Next key", "Next key", "Complete", "Stop", "History", "Exit", "Suspend"])
        XCTAssertEqual(items[1].action, .ctrl)
        XCTAssertEqual(items[2].action, .shift)
        XCTAssertEqual(Array(items.dropFirst(3)).map(\.action), [
            .keys("\t", repeatAfter: nil), .keys("\u{03}", repeatAfter: nil),
            .keys("\u{12}", repeatAfter: nil), .keys("\u{04}", repeatAfter: nil),
            .keys("\u{1a}", repeatAfter: nil)
        ])
        guard case let .menu(functions) = items[0].action else { return XCTFail("Fn must open its submenu") }
        XCTAssertEqual(functions.count, 12)
        for (index, function) in functions.enumerated() {
            let number = index + 1
            XCTAssertEqual(function.label, "F\(number)")
            XCTAssertEqual(function.tag, "pet-f\(number)")
            XCTAssertEqual(function.action, .functionKey(number))
            XCTAssertEqual(function.hintZh, "")
            XCTAssertEqual(function.hintEn, "")
            XCTAssertEqual(function.description(english: false), "发送 F\(number)")
            XCTAssertEqual(function.description(english: true), "Send F\(number)")
        }
    }

    func testSameChordExplainsTheDifferentAgentActionInBothLanguages() {
        let descriptions: [(ScreenApp, String, String)] = [
            (.claude, "Ctrl+O：展开完整对话记录", "Ctrl+O: expand the full transcript"),
            (.codex, "Ctrl+O：复制最后一条回复", "Ctrl+O: copy the last reply"),
            (.grok, "Ctrl+O：开关自动批准", "Ctrl+O: toggle auto-approve"),
            (.gemini, "Ctrl+O：显示更多内容", "Ctrl+O: show more lines")
        ]
        for (app, chinese, english) in descriptions {
            let item = app.shortcuts.first { $0.tag == "pet-ctrl-o" }!
            XCTAssertEqual(item.description(english: false), chinese)
            XCTAssertEqual(item.description(english: true), english)
        }
    }
}
