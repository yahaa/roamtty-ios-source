import SwiftUI
import UIKit
import ImageIO
import RoamttyCore
import RoamttyTransport

struct FilePreviewScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let host: Host
    let entry: RemoteEntry
    let connectionTarget: RemoteConnectionTarget
    /// A line to show and mark (1-based), as a tapped `path:line` in the terminal names it; 0 for none.
    var line: Int = 0
    @State private var content: RemoteFileContent?
    @State private var document: CodeDocument?
    @State private var blocks: [MdBlock] = []
    @State private var image: UIImage?
    @State private var imageDimensions: String?
    @State private var failure: String?
    @State private var rendered = true
    @State private var query = ""
    @State private var searchVisible = false
    @State private var match = 0
    @State private var matches: [CodeMatch] = []
    @State private var fullImage = false
    @State private var transfers = false
    @State private var reloadID = 0
    @State private var previewLimit = textPreviewBytes
    private var previewFontSize: Double { model.settings.codeFontSize }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if compact { landscapeBar }
                if searchVisible { searchBar }
                if let image {
                    ZoomableImage(image: image).accessibilityIdentifier("file-image-preview").onTapGesture(count: 2) { fullImage = true }
                } else if document != nil {
                    documentView(fullscreen: false)
                } else if let failure {
                    EmptyMessage(icon: "exclamationmark.triangle", title: model.text("无法预览", "Unable to preview"), message: failure)
                    Button(model.text("重试", "Retry")) { reloadID += 1 }.accessibilityIdentifier("preview-retry")
                    Spacer()
                } else if content != nil {
                    EmptyMessage(icon: "doc", title: model.text("二进制文件", "Binary file"), message: model.text("下载文件后使用其他应用打开。", "Download this file to open it in another app."))
                    Spacer()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let content, !compact {
                    HStack {
                        Text(formattedBytes(content.size))
                        if content.truncated {
                            Text(previewLimit == imagePreviewBytes ? model.text("图片上限 8 MiB", "Image limit: 8 MiB") : model.text("仅预览前 256 KiB",
                                "Preview limited to 256 KiB")).foregroundStyle(Palette.warning)
                        }
                        Spacer()
                        if let imageDimensions { Text(imageDimensions).accessibilityIdentifier("preview-image-dimensions") }
                        if let document {
                            Text("\(document.lineCount) " + model.text("行", "lines"))
                            Text(document.language.displayName)
                            Text("\(Int(previewFontSize)) pt").accessibilityIdentifier("preview-font-size")
                            Text(model.settings.codeWrap ? model.text("换行", "Wrapped") : model.text("不换行", "No wrap")).accessibilityIdentifier("preview-wrap-status")
                        }
                    }.font(.caption).foregroundStyle(Palette.secondary).padding(12).background(Palette.panel)
                }
            }.pageBackground().navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                .toolbar(compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { doneButton }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { download() } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel(model.text("下载", "Download")).accessibilityIdentifier("preview-download")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) { Menu { optionsMenu } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("preview-options") }
                }
        }.onChange(of: query) { _ in updateMatches() }
        .task(id: reloadID) {
            content = nil; document = nil; blocks = []; image = nil; imageDimensions = nil; failure = nil; matches = []; match = 0
            // A line to show is a line of the source, so Markdown opens as source there.
            if line > 0 && reloadID == 0 { rendered = false }
            let cancellation = TransferCancellation()
            await withTaskCancellationHandler(operation: {
                do {
                    let ssh = try await model.connection(for: connectionTarget)
                    try Task.checkCancellation()
                    let isImage = entry.kind == .image
                    previewLimit = isImage ? imagePreviewBytes : textPreviewBytes
                    let result = try await performInBackground { try ssh.readFile(entry.path, maxBytes: isImage ? imagePreviewBytes : textPreviewBytes, cancellation: cancellation) }
                    try Task.checkCancellation()
                    try model.validate(connectionTarget)
                    content = result
                    if isImage && !result.truncated {
                        let decoded = try await performInBackground { decodePreviewImage(result.data) }
                        try Task.checkCancellation()
                        image = decoded?.image; imageDimensions = decoded?.dimensions
                        if decoded != nil { return }
                    }
                    // SVG and other text-backed image formats retain a bounded source preview.
                    let textResult = result.data.count <= textPreviewBytes ? result : RemoteFileContent(data: Data(result.data.prefix(textPreviewBytes)), size: result.size, truncated: true)
                    if let text = textResult.text {
                        content = textResult; previewLimit = textPreviewBytes
                        let language = Languages.detect(fileName: entry.name, firstLine: String(text.prefix { !$0.isNewline }))
                        let highlighted = try await performInBackground { SyntaxHighlighter.highlight(text, language) }
                        let parsed = language.mode == .markdown ? try await performInBackground { MarkdownParser.parse(text) } : []
                        try Task.checkCancellation()
                        document = highlighted; blocks = parsed; updateMatches()
                    } else if isImage {
                        failure = result.truncated ? model.text("图片超过 8 MiB，请下载后查看。",
                            "This image exceeds 8 MiB. Download it to view the complete file.") : model.text("此图片格式无法预览，请下载后查看。",
                            "This image format cannot be previewed. Download it to open in another app.")
                    }
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
            }, onCancel: { cancellation.cancel() })
        }
        .modifier(ChildModalPresence())
        .overlay { AuthenticationOverlay() }
        .fullScreenCover(isPresented: $fullImage) {
            if let image {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    ZoomableImage(image: image).ignoresSafeArea().accessibilityIdentifier("file-image-fullscreen")
                    Button { fullImage = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white).padding(24)
                    }.accessibilityLabel(model.text("退出全屏", "Exit fullscreen")).accessibilityIdentifier("preview-image-close")
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    documentView(fullscreen: true).pageBackground()
                    Button { fullImage = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).padding(12).background(.ultraThinMaterial, in: Circle())
                    }.padding(12).accessibilityLabel(model.text("退出全屏", "Exit fullscreen")).accessibilityIdentifier("preview-fullscreen-close")
                }
            }
        }
        .sheet(isPresented: $transfers) { TransferScreen(transfers: model.files).environmentObject(model) }
    }
    private var compact: Bool { verticalSizeClass == .compact }
    private var doneButton: some View { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("preview-done") }
    private func download() { model.files.download(entry, host: host, model: model, connectionTarget: connectionTarget); transfers = true }
    @ViewBuilder private var optionsMenu: some View {
            Button(model.text("查找", "Find"), systemImage: "magnifyingglass") { rendered = false; searchVisible = true }.disabled(document == nil).accessibilityIdentifier("preview-find")
            Toggle(model.text("自动换行", "Wrap lines"), isOn: $model.settings.codeWrap).onChange(of: model.settings.codeWrap) { _ in model.saveSettings() }.accessibilityIdentifier("preview-wrap")
            if document?.language.mode == .markdown { Toggle(model.text("渲染 Markdown", "Render Markdown"), isOn: $rendered).accessibilityIdentifier("preview-render-markdown") }
            if document != nil {
                Button("A− · " + model.text("缩小字体", "Smaller text")) {
                    model.settings.codeFontSize = max(9, previewFontSize - 1)
                    model.saveSettings()
                }.disabled(previewFontSize <= 9).accessibilityIdentifier("preview-font-smaller")
                Button("A+ · " + model.text("放大字体", "Larger text")) {
                    model.settings.codeFontSize = min(22, previewFontSize + 1)
                    model.saveSettings()
                }.disabled(previewFontSize >= 22).accessibilityIdentifier("preview-font-larger")
            }
            if document != nil || image != nil {
                Button(model.text("全屏", "Fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right") { fullImage = true }.accessibilityIdentifier("preview-fullscreen")
            }
            Button(model.text("复制路径", "Copy path"), systemImage: "link") { UIPasteboard.general.string = entry.path }.accessibilityIdentifier("preview-copy-path")
            if let text = content?.text { Button(model.text("复制全部", "Copy all"), systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
            Button(model.text("重新加载", "Reload"), systemImage: "arrow.clockwise") { reloadID += 1 }
    }
    /// Landscape: one flat bar in place of the navigation bar and the status line under the file: done, the name with
    /// its size, lines and language after it, then download and the menu. The file keeps the rest of the height.
    private var landscapeBar: some View {
        LandscapeBar(title: entry.name, detail: content.map(details)) { doneButton.buttonStyle(TextActionStyle()) } trailing: {
            if let content, content.truncated {
                Text(previewLimit == imagePreviewBytes ? model.text("图片上限 8 MiB", "Image limit: 8 MiB") : model.text("仅预览前 256 KiB", "Preview limited to 256 KiB"))
                    .font(.footnote).foregroundStyle(Palette.warning).lineLimit(1)
            }
            BarIconButton(icon: "ic_download", label: model.text("下载", "Download"), id: "preview-download") { download() }
            Menu { optionsMenu } label: { AppIcon("ic_more", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("preview-options")
        }
    }
    /// The status line's words, joined for the landscape bar.
    private func details(_ content: RemoteFileContent) -> String {
        var parts = [formattedBytes(content.size)]
        if let imageDimensions { parts.append(imageDimensions) }
        if let document {
            parts += ["\(document.lineCount) " + model.text("行", "lines"), document.language.displayName, "\(Int(previewFontSize)) pt",
                      model.settings.codeWrap ? model.text("换行", "Wrapped") : model.text("不换行", "No wrap")]
        }
        return parts.joined(separator: " · ")
    }
    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField(model.text("在文件中查找", "Find in file"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("preview-search")
            Text(query.isEmpty ? "" : matches.isEmpty ? model.text("无结果", "No results") : "\(match + 1)/\(matches.count)").font(.caption).fixedSize().accessibilityIdentifier("preview-search-count")
            Button {
                match = codeMatchIndex(current: match, delta: -1, count: matches.count)
            } label: {
                Image(systemName: "chevron.up")
            }.disabled(matches.isEmpty).accessibilityLabel(model.text("上一个", "Previous match")).accessibilityIdentifier("preview-search-previous")
            Button {
                match = codeMatchIndex(current: match, delta: 1, count: matches.count)
            } label: {
                Image(systemName: "chevron.down")
            }.disabled(matches.isEmpty).accessibilityLabel(model.text("下一个", "Next match")).accessibilityIdentifier("preview-search-next")
            Button { searchVisible = false; query = "" } label: { Image(systemName: "xmark") }.accessibilityLabel(model.text("关闭查找", "Close search")).accessibilityIdentifier("preview-search-close")
        }.padding(12).background(Palette.panel)
    }
    @ViewBuilder private func documentView(fullscreen: Bool) -> some View {
        if let document {
            if document.language.mode == .markdown && rendered {
                GeometryReader { viewport in
                    ScrollView {
                        MarkdownContent(blocks: blocks, connectionTarget: connectionTarget,
                                        directory: parentRemotePath(entry.path), fontSize: previewFontSize,
                                        viewport: viewport.size, coordinateSpace: fullscreen ? "markdown-fullscreen" : "markdown-normal",
                                        imagesEnabled: fullscreen || !fullImage)
                            .padding(16).frame(maxWidth: 840)
                    }.coordinateSpace(name: fullscreen ? "markdown-fullscreen" : "markdown-normal")
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(fullscreen ? "file-markdown-fullscreen" : "file-markdown-preview")
                }
            } else {
                CodeTextView(document: document, fontName: model.settings.font, fontSize: previewFontSize, wrap: model.settings.codeWrap,
                    query: query, match: match, matches: matches, identifier: fullscreen ? "file-code-fullscreen" : "file-code-preview", markedLine: line).id(reloadID)
            }
        }
    }
    private func updateMatches() {
        matches = document.map { findCodeMatches($0, query: query) } ?? []
        match = 0
    }
}
private struct DecodedPreviewImage {
    let image: UIImage
    let dimensions: String
}
private func decodePreviewImage(_ data: Data) -> DecodedPreviewImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { return nil }
    return DecodedPreviewImage(image: UIImage(cgImage: thumbnail), dimensions: "\(width.intValue) × \(height.intValue)")
}
struct CodeTextView: UIViewRepresentable {
    let document: CodeDocument
    let fontName: String
    let fontSize: Double
    let wrap: Bool
    let query: String
    let match: Int
    let matches: [CodeMatch]
    let identifier: String
    /// A source line to scroll to and mark, or 0.
    var markedLine: Int = 0
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.accessibilityIdentifier = identifier
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        // The highlighted text is built once per document and look; a search only repaints its matches.
        let key = "\(document.lineCount)-\(document.maxColumns)-\(fontName)-\(fontSize)-\(wrap)-\(scheme)"
        if coordinator.key != key || coordinator.document != document.lines {
            coordinator.key = key
            coordinator.document = document.lines
            coordinator.sourceMatches = []; coordinator.matches = []
            let font = FontCatalog.shared.font(selection: fontName, size: fontSize)
            let output = NSMutableAttributedString()
            let digits = String(document.lineCount).count
            var rowOffsets: [Int] = []
            var marked: NSRange?
            for line in document.lines {
                let number = String(repeating: " ", count: max(0, digits - String(line.number).count)) + "\(line.number)  "
                let lineStart = output.length
                output.append(NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
                let offset = output.length
                rowOffsets.append(offset)
                output.append(NSAttributedString(string: line.text + "\n", attributes: [.font: font, .foregroundColor: UIColor.label]))
                if markedLine > 0 && line.number == markedLine && marked == nil { marked = NSRange(location: lineStart, length: output.length - lineStart) }
                for index in stride(from: 0, to: line.spans.count - 2, by: 3) {
                    let start = line.spans[index], end = line.spans[index + 1]
                    guard start >= 0, end <= line.text.utf16.count, end > start else { continue }
                    output.addAttribute(.foregroundColor, value: tokenColor(TokenType(rawValue: line.spans[index + 2])), range: NSRange(location: offset + start, length: end - start))
                }
            }
            coordinator.rowOffsets = rowOffsets
            coordinator.marked = marked
            if let marked { output.addAttribute(.backgroundColor, value: Self.markColor, range: marked) }
            view.attributedText = output
            if let marked { Self.scroll(view, toMark: marked, lineHeight: font.lineHeight, attempts: 10) }
            view.textContainer.widthTracksTextView = wrap
            view.textContainer.size = CGSize(width: wrap ? max(1, view.bounds.width - 20) : max(1000, CGFloat(document.maxColumns + digits + 4) * font.pointSize * 0.65),
                height: .greatestFiniteMagnitude)
        }
        if coordinator.sourceMatches != matches {
            coordinator.sourceMatches = matches
            let storage = view.textStorage
            storage.beginEditing()
            for range in coordinator.matches where NSMaxRange(range) <= storage.length { storage.removeAttribute(.backgroundColor, range: range) }
            if let marked = coordinator.marked, NSMaxRange(marked) <= storage.length { storage.addAttribute(.backgroundColor, value: Self.markColor, range: marked) }
            coordinator.matches = []
            for found in matches where coordinator.rowOffsets.indices.contains(found.row) {
                let range = NSRange(location: coordinator.rowOffsets[found.row] + found.start, length: found.end - found.start)
                guard NSMaxRange(range) <= storage.length else { continue }
                coordinator.matches.append(range)
                storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.25), range: range)
            }
            storage.endEditing()
        }
        if coordinator.lastMatch != match || coordinator.lastQuery != query {
            coordinator.lastMatch = match; coordinator.lastQuery = query
            if !coordinator.matches.isEmpty { let range = coordinator.matches[match % coordinator.matches.count]; view.selectedRange = range; view.scrollRangeToVisible(range) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    private static let markColor = UIColor.tintColor.withAlphaComponent(0.16)
    /// Puts the marked line a few lines below the top, once the view has its size.
    private static func scroll(_ view: UITextView, toMark range: NSRange, lineHeight: CGFloat, attempts: Int) {
        DispatchQueue.main.async {
            guard view.bounds.height > 0 else {
                if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { scroll(view, toMark: range, lineHeight: lineHeight, attempts: attempts - 1) } }
                return
            }
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: max(1, range.length - 1)),
                  let text = view.textRange(from: start, to: end) else { return }
            let rect = view.firstRect(for: text)
            guard rect.minY.isFinite else { return }
            let bottom = max(0, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
            let y = min(bottom, max(-view.adjustedContentInset.top, rect.minY - 3 * lineHeight))
            view.setContentOffset(CGPoint(x: -view.adjustedContentInset.left, y: y), animated: false)
        }
    }
    final class Coordinator {
        var marked: NSRange?
        var key = ""; var document: [CodeLine] = []; var rowOffsets: [Int] = []
        var sourceMatches: [CodeMatch] = []; var matches: [NSRange] = []; var lastMatch = -1; var lastQuery = ""
    }
    private func tokenColor(_ token: TokenType?) -> UIColor {
        switch token {
        case .keyword, .constant: return UIColor.systemPurple
        case .string, .inserted: return UIColor.systemGreen
        case .comment: return UIColor.secondaryLabel
        case .number, .attribute: return UIColor.systemOrange
        case .function, .type, .heading: return UIColor.systemBlue
        case .error, .deleted: return UIColor.systemRed
        default: return UIColor.label
        }
    }
}
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        let view = UIImageView(image: image); view.contentMode = .scaleAspectFit; view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view); context.coordinator.image = view
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.image?.image = image }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate { weak var image: UIImageView?; func viewForZooming(in scrollView: UIScrollView) -> UIView? { image } }
}
struct MarkdownContent: View {
    let blocks: [MdBlock]
    let connectionTarget: RemoteConnectionTarget
    let directory: String
    var fontSize: Double = 13
    let viewport: CGSize
    let coordinateSpace: String
    let imagesEnabled: Bool
    // Flatten quotes into rows so one long quote cannot eagerly instantiate all images.
    private struct Row { let block: MdBlock; let quoteDepth: Int }
    private func rows(_ blocks: [MdBlock], depth: Int = 0) -> [Row] {
        blocks.flatMap { block in
            if case .quote(let children) = block { return rows(children, depth: depth + 1) }
            return [Row(block: block, quoteDepth: depth)]
        }
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows(blocks).enumerated()), id: \.offset) { _, row in
                blockView(row.block).padding(.leading, CGFloat(row.quoteDepth) * 23)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 20) {
                            ForEach(0..<row.quoteDepth, id: \.self) { _ in Rectangle().fill(Palette.accent).frame(width: 3) }
                        }.padding(.leading, 8)
                    }
            }
        }.font(.system(size: fontSize)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func blockView(_ block: MdBlock) -> AnyView {
        switch block {
        case .heading(let level, let text): return AnyView(inline(text).font(.system(size: fontSize * (level == 1 ? 1.7 : level == 2 ? 1.4 : 1.15), weight: .semibold)).padding(.top, 8))
        case .paragraph(let text): return AnyView(inline(text).textSelection(.enabled))
        case .code(_, let text): return AnyView(ScrollView(.horizontal) {
            Text(text).font(.system(size: fontSize, design: .monospaced)).textSelection(.enabled).padding(12)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)))
        case .quote: return AnyView(EmptyView()) // Flattened above.
        case .listItem(let depth, let marker, let checked, let text): return AnyView(HStack(alignment: .top, spacing: 8) {
            Text(checked.map { $0 ? "☑" : "☐" } ?? marker)
            inline(text)
        }.padding(.leading, CGFloat(depth) * 16))
        case .table(let header, _, let rows): return AnyView(ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, text in inline(text).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, text in inline(text) } } }
            }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        })
        case .image(let alt, let path):
            return AnyView(RemoteMarkdownImage(connectionTarget: connectionTarget, directory: directory, path: path, alt: alt,
                                               viewport: viewport, coordinateSpace: coordinateSpace, enabled: imagesEnabled))
        case .rule: return AnyView(Divider())
        }
    }
    private func inline(_ value: MdText) -> Text {
        let result = NSMutableAttributedString(string: value.text)
        for span in value.spans {
            guard span.start >= 0, span.end <= result.length, span.end > span.start else { continue }
            let range = NSRange(location: span.start, length: span.end - span.start)
            switch span.style {
            case .bold: result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize), range: range)
            case .italic: result.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: fontSize), range: range)
            case .strike: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code: result.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), range: range)
            case .link, .image:
                result.addAttribute(.foregroundColor, value: UIColor(Palette.accent), range: range)
                if let link = span.url, let url = markdownExternalURL(link) {
                    result.addAttribute(.link, value: url, range: range)
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
        }
        return Text(AttributedString(result))
    }
}
private struct MarkdownImageFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct RemoteMarkdownImage: View {
    @EnvironmentObject var model: AppModel
    let connectionTarget: RemoteConnectionTarget
    let directory: String
    let path: String
    let alt: String
    let viewport: CGSize
    let coordinateSpace: String
    let enabled: Bool
    @StateObject private var demand = MarkdownImageDemand()
    @State private var frame: CGRect = .zero
    @State private var appeared = false
    private struct DemandKey: Equatable {
        let path: String?
        let generation: UUID
        let visible: Bool
    }
    private var demandKey: DemandKey {
        let generation: UUID
        switch connectionTarget {
        case .host(let id): generation = model.generations.host(id)
        case .session(let id, _): generation = model.generations.owner(id)
        }
        return DemandKey(path: markdownRemoteImagePath(directory: directory, source: path), generation: generation,
                         visible: appeared && enabled && !frame.isEmpty && frame.intersects(CGRect(origin: .zero, size: viewport)))
    }
    private var imageHeight: CGFloat? {
        guard let size = demand.pixelSize, size.width > 0 else { return nil }
        return min(480, max(1, frame.width) * size.height / size.width)
    }
    var body: some View {
        Group {
            if let display = demand.display {
                MarkdownImageView(display: display, label: alt)
                    .accessibilityLabel(alt).accessibilityAddTraits(.isImage)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let destination = markdownExternalURL(path) {
                Link(destination: destination) { placeholder }
                    .buttonStyle(.plain).accessibilityAddTraits(.isLink)
            } else {
                placeholder
            }
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: imageHeight)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: MarkdownImageFrameKey.self, value: geometry.frame(in: .named(coordinateSpace)))
            })
            .onPreferenceChange(MarkdownImageFrameKey.self) { frame = $0 }
            .onAppear { appeared = true }
            .onChange(of: demandKey) { _ in updateDemand() }
            .onDisappear { appeared = false; demand.stop() }
    }
    private func updateDemand() {
        let key = demandKey
        if key.visible, let path = key.path { demand.start(model: model, target: connectionTarget, path: path) } else { demand.stop() }
    }
    private var placeholder: some View {
        Label(alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(path.split(separator: "/").last ?? "") : alt, systemImage: "photo")
            .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
