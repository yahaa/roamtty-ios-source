import UIKit
import SwiftTerm
import RoamttyCore

/// SwiftTerm's callbacks: size, title and folder changes, the bytes the view wants sent, links and the bell.
extension SessionRuntime: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        columns = max(2, newCols); rows = max(2, newRows)
        if let mosh { mosh.resize(columns: columns, rows: rows) } else { ssh?.resize(columns: columns, rows: rows) }
        queueCursorRefresh()
    }
    func setTerminalTitle(source: TerminalView, title: String) { terminalTitle = String(title.prefix(200)) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.scheme == "file" { currentDirectory = url.path } else if directory.hasPrefix("/") { currentDirectory = directory }
    }
    /// Typed keys, a native paste being gathered, and the wheel events of a remote scroll.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let view = source as? AccessibleTerminalView
        if view?.placingKeyboardPlaceholder == true { return }
        if capturedPaste != nil { capturedPaste?.append(data); return }
        if scrollEventBytes != nil { scrollEventBytes?.append(contentsOf: data); return }
        view?.queueKeepKeyboardDeleteRepeating()
        var bytes = Data(data)
        // Deleting uncommitted composition belongs to the keyboard, and must not count towards clearing the line.
        if TerminalDeleteHold.isDelete(bytes), source.markedTextRange == nil { sendKeyboardDelete(bytes); return }
        if shiftArmed, let string = String(data: bytes, encoding: .utf8) { bytes = Data(string.uppercased().utf8); shiftArmed = false }
        if send(bytes) { userTyped(bytes) }
        if controlArmed { controlArmed = false; terminalView.controlModifier = false }
    }
    func scrolled(source: TerminalView, position: Double) { queueCursorRefresh(); linkPress.contentChanged() }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func clipboardCopy(source: TerminalView, content: Data) { /* OSC 52 is intentionally ignored. Native selection copying remains available. */ }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { queueCursorRefresh(); linkPress.contentChanged() }
}
