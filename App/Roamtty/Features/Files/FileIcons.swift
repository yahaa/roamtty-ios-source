import SwiftUI
import RoamttyCore

// Generated from Android's FileIconTheme.kt: editor-style badges for languages, tinted glyphs for media and documents.
enum FileIconSpec: Equatable {
    case badge(String, UInt32, label: UInt32 = 0xFFFFFF)
    case glyph(RemoteFileKind, UInt32)
    case folder(UInt32)
    /// The Android robot, for app packages.
    case android(UInt32 = 0x3DDC84)
}

enum FileIconTheme {
    private static let darkLabel: UInt32 = 0x1E1E1E
    private static let defaultFolder: UInt32 = 0x90A4AE
    private static let js: FileIconSpec = .badge("JS", 0xF1DD35, label: darkLabel)
    private static let ts: FileIconSpec = .badge("TS", 0x3178C6)
    private static let shell: FileIconSpec = .badge(">_", 0x4EAA25)
    private static let json: FileIconSpec = .badge("{}", 0xCBCB41, label: darkLabel)
    private static let yaml: FileIconSpec = .badge("YML", 0xCB171E)
    private static let markdown: FileIconSpec = .badge("M↓", 0x42A5F5)
    private static let config: FileIconSpec = .badge("CFG", 0x6D8086)
    private static let git: FileIconSpec = .badge("GIT", 0xF14E32)
    private static let docker: FileIconSpec = .badge("DKR", 0x2496ED)
    private static let key: FileIconSpec = .badge("KEY", 0xC49A00, label: darkLabel)
    private static let font: FileIconSpec = .badge("Aa", 0xE53935)
    private static let android: FileIconSpec = .android()
    private static let byName: [String: FileIconSpec] = [
        "dockerfile": docker,
        "containerfile": docker,
        ".dockerignore": docker,
        "docker-compose.yml": docker,
        "docker-compose.yaml": docker,
        "compose.yml": docker,
        "compose.yaml": docker,
        "makefile": .badge("MK", 0x6D8086),
        "gnumakefile": .badge("MK", 0x6D8086),
        "justfile": .badge("JST", 0x6D8086),
        "cmakelists.txt": .badge("CM", 0x064F8C),
        "gemfile": .badge("RB", 0xCC342D),
        "rakefile": .badge("RB", 0xCC342D),
        "package.json": .badge("NPM", 0xCB3837),
        "package-lock.json": .badge("NPM", 0xCB3837),
        "yarn.lock": .badge("YRN", 0x2C8EBB),
        "pnpm-lock.yaml": .badge("PN", 0xF69220, label: darkLabel),
        "cargo.toml": .badge("RS", 0xCE422B),
        "cargo.lock": .badge("RS", 0xCE422B),
        "go.mod": .badge("GO", 0x00ADD8),
        "go.sum": .badge("GO", 0x00ADD8),
        "tsconfig.json": ts,
        "jsconfig.json": js,
        ".gitignore": git,
        ".gitattributes": git,
        ".gitmodules": git,
        ".gitconfig": git,
        ".bashrc": shell,
        ".bash_profile": shell,
        ".zshrc": shell,
        ".profile": shell,
        ".bash_aliases": shell,
        ".bash_logout": shell,
        ".zprofile": shell,
        ".bash_history": shell,
        ".zsh_history": shell,
        ".editorconfig": config,
        ".npmrc": config,
        ".vimrc": .badge("VIM", 0x019733),
        ".tmux.conf": .badge("TMX", 0x1BB91F),
        "license": .badge("©", 0xD0BF41, label: darkLabel),
        "licence": .badge("©", 0xD0BF41, label: darkLabel),
        "license.md": .badge("©", 0xD0BF41, label: darkLabel),
        "license.txt": .badge("©", 0xD0BF41, label: darkLabel),
        "readme": .badge("i", 0x42A5F5),
        "readme.md": .badge("i", 0x42A5F5),
        "readme.txt": .badge("i", 0x42A5F5),
        "changelog": .badge("CHG", 0x8BC34A, label: darkLabel),
        "changelog.md": .badge("CHG", 0x8BC34A, label: darkLabel),
        "authorized_keys": key,
        "known_hosts": key,
        "id_rsa": key,
        "id_ed25519": key,
        "id_ecdsa": key,
        "build.gradle": .badge("G", 0x02303A),
        "build.gradle.kts": .badge("G", 0x02303A),
        "settings.gradle": .badge("G", 0x02303A),
        "settings.gradle.kts": .badge("G", 0x02303A),
        "gradlew": .badge("G", 0x02303A)
    ]
    private static let byExtension: [String: FileIconSpec] = [
        "js": js,
        "mjs": js,
        "cjs": js,
        "jsx": .badge("JSX", 0x61DAFB, label: darkLabel),
        "ts": ts,
        "mts": ts,
        "cts": ts,
        "tsx": .badge("TSX", 0x3178C6),
        "py": .badge("PY", 0x3776AB, label: 0xFFD43B),
        "pyi": .badge("PY", 0x3776AB, label: 0xFFD43B),
        "ipynb": .badge("NB", 0xF37626),
        "kt": .badge("KT", 0x7F52FF),
        "kts": .badge("KTS", 0x7F52FF),
        "java": .badge("J", 0xE76F00),
        "class": .badge("J", 0xB07219),
        "jar": .badge("JAR", 0xB07219),
        "go": .badge("GO", 0x00ADD8),
        "rs": .badge("RS", 0xCE422B),
        "c": .badge("C", 0x5C6BC0),
        "h": .badge("H", 0xA074C4),
        "cc": .badge("C++", 0x00599C),
        "cpp": .badge("C++", 0x00599C),
        "cxx": .badge("C++", 0x00599C),
        "hpp": .badge("H++", 0xA074C4),
        "hh": .badge("H++", 0xA074C4),
        "m": .badge("OC", 0x438EFF),
        "cs": .badge("C#", 0x68217A),
        "fs": .badge("F#", 0x378BBA),
        "swift": .badge("SW", 0xF05138),
        "dart": .badge("DT", 0x0175C2),
        "rb": .badge("RB", 0xCC342D),
        "php": .badge("PHP", 0x777BB4),
        "pl": .badge("PL", 0x39457E),
        "lua": .badge("LUA", 0x000080),
        "r": .badge("R", 0x276DC3),
        "scala": .badge("SC", 0xDC322F),
        "ex": .badge("EX", 0x6E4A7E),
        "exs": .badge("EX", 0x6E4A7E),
        "erl": .badge("ERL", 0xA90533),
        "hs": .badge("HS", 0x5E5086),
        "clj": .badge("CLJ", 0x5881D8),
        "zig": .badge("ZIG", 0xF7A41D, label: darkLabel),
        "nim": .badge("NIM", 0xFFC200, label: darkLabel),
        "jl": .badge("JL", 0x9558B2),
        "groovy": .badge("GR", 0x4298B8),
        "sh": shell,
        "bash": shell,
        "zsh": shell,
        "fish": shell,
        "ksh": shell,
        "ps1": .badge("PS", 0x012456),
        "psm1": .badge("PS", 0x012456),
        "bat": .badge("BAT", 0xC1F12E, label: darkLabel),
        "cmd": .badge("BAT", 0xC1F12E, label: darkLabel),
        "sql": .badge("SQL", 0xE38C00),
        "db": .badge("DB", 0x8D6E63),
        "sqlite": .badge("DB", 0x8D6E63),
        "sqlite3": .badge("DB", 0x8D6E63),
        "html": .badge("<>", 0xE34F26),
        "htm": .badge("<>", 0xE34F26),
        "xhtml": .badge("<>", 0xE34F26),
        "css": .badge("CSS", 0x1572B6),
        "scss": .badge("S", 0xCC6699),
        "sass": .badge("S", 0xCC6699),
        "less": .badge("LS", 0x1D365D),
        "vue": .badge("V", 0x41B883),
        "svelte": .badge("S", 0xFF3E00),
        "json": json,
        "jsonc": json,
        "json5": json,
        "geojson": json,
        "webmanifest": json,
        "yaml": yaml,
        "yml": yaml,
        "toml": .badge("T", 0x9C4221),
        "xml": .badge("XML", 0xF1662A),
        "plist": .badge("XML", 0xF1662A),
        "svg": .badge("SVG", 0xFFB13B, label: darkLabel),
        "ini": config,
        "conf": config,
        "cfg": config,
        "properties": config,
        "service": config,
        "env": .badge("ENV", 0xECD53F, label: darkLabel),
        "lock": .badge("LCK", 0x8D6E63),
        "md": markdown,
        "markdown": markdown,
        "mdx": markdown,
        "rst": .badge("RST", 0x6D8086),
        "tex": .badge("TEX", 0x3D6117),
        "csv": .badge("CSV", 0x217346),
        "tsv": .badge("TSV", 0x217346),
        "gradle": .badge("G", 0x02303A),
        "tf": .badge("TF", 0x7B42BC),
        "tfvars": .badge("TF", 0x7B42BC),
        "proto": .badge("PB", 0x4285F4),
        "graphql": .badge("GQL", 0xE10098),
        "gql": .badge("GQL", 0xE10098),
        "nix": .badge("NIX", 0x5277C3),
        "vim": .badge("VIM", 0x019733),
        "dockerfile": docker,
        "diff": .badge("±", 0x41B883),
        "patch": .badge("±", 0x41B883),
        "pem": key,
        "key": key,
        "crt": key,
        "cer": key,
        "pub": key,
        "p12": key,
        "gpg": key,
        "asc": key,
        "ttf": font,
        "otf": font,
        "woff": font,
        "woff2": font,
        "wasm": .badge("WA", 0x654FF0),
        "so": .badge("BIN", 0x607D8B),
        "o": .badge("BIN", 0x607D8B),
        "bin": .badge("BIN", 0x607D8B),
        "log": .glyph(.text, 0xAFB42B),
        "apk": android,
        "aab": android,
        "apks": android,
        "xapk": android,
        "apkm": android
    ]
    private static let folderColors: [String: UInt32] = [
        "src": 0x4CAF50,
        "source": 0x4CAF50,
        "lib": 0x8BC34A,
        "libs": 0x8BC34A,
        "app": 0x4CAF50,
        "test": 0x00BFA5,
        "tests": 0x00BFA5,
        "__tests__": 0x00BFA5,
        "spec": 0x00BFA5,
        "androidtest": 0x00BFA5,
        "node_modules": 0x8BC34A,
        "vendor": 0x8BC34A,
        ".venv": 0xFFCA28,
        "venv": 0xFFCA28,
        ".git": 0xF4511E,
        ".github": 0x546E7A,
        ".vscode": 0x2196F3,
        ".idea": 0x7E57C2,
        "docs": 0x2196F3,
        "doc": 0x2196F3,
        "dist": 0xE57373,
        "build": 0xE57373,
        "out": 0xE57373,
        "target": 0xE57373,
        "bin": 0xE57373,
        "scripts": 0x26A69A,
        "script": 0x26A69A,
        "assets": 0xFFCA28,
        "images": 0x26A69A,
        "img": 0x26A69A,
        "public": 0x03A9F4,
        "static": 0x03A9F4,
        "res": 0xFFCA28,
        "resources": 0xFFCA28,
        "config": 0x00ACC1,
        ".config": 0x00ACC1,
        "etc": 0x00ACC1,
        ".ssh": 0xC49A00,
        "downloads": 0x42A5F5,
        "desktop": 0x42A5F5,
        "documents": 0x42A5F5,
        "home": 0xFF8A65,
        "root": 0xFF8A65,
        "tmp": 0x78909C,
        "var": 0x78909C,
        "log": 0xAFB42B,
        "logs": 0xAFB42B,
        "data": 0x5C6BC0,
        "db": 0x5C6BC0,
        "migrations": 0x5C6BC0,
        "components": 0xC0CA33,
        "views": 0xFF7043,
        "pages": 0xFF7043,
        "api": 0xFFB300,
        "server": 0xFFB300,
        "kotlin": 0x7F52FF,
        "java": 0xE76F00,
        "python": 0x3776AB,
        "go": 0x00ADD8
    ]
    static func spec(name: String, directory: Bool, permissions: UInt32 = 0) -> FileIconSpec {
        let lower = name.lowercased()
        if directory { return .folder(folderColors[lower] ?? defaultFolder) }
        if let spec = byName[lower] { return spec }
        if lower.hasPrefix(".env"), let env = byExtension["env"] { return env }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return docker }
        if lower.hasSuffix(".d.ts") { return ts }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, let spec = byExtension[ext] { return spec }
        let kind = remoteFileKind(name: name, isDirectory: false, permissions: permissions)
        return .glyph(kind, glyphColor(kind))
    }
    private static func glyphColor(_ kind: RemoteFileKind) -> UInt32 {
        switch kind {
        case .image: return 0x26A69A
        case .audio: return 0xEC407A
        case .video: return 0xFF7043
        case .archive: return 0xAF8F5A
        case .pdf: return 0xE53935
        case .document: return 0x2B7CD3
        case .spreadsheet: return 0x21A366
        case .presentation: return 0xD24726
        case .executable: return 0x4CAF50
        case .code: return 0x7986CB
        case .config: return 0x6D8086
        case .text: return 0x90A4AE
        case .directory: return defaultFolder
        case .file: return 0x90A4AE
        }
    }
    static func glyphIcon(_ kind: RemoteFileKind) -> String {
        switch kind {
        case .directory: return "ic_folder"
        case .text: return "ic_file_text"
        case .code: return "ic_file_code"
        case .config: return "ic_file_config"
        case .image: return "ic_image"
        case .audio: return "ic_file_audio"
        case .video: return "ic_file_video"
        case .archive: return "ic_file_archive"
        case .pdf: return "ic_file_pdf"
        case .document: return "ic_file_document"
        case .spreadsheet: return "ic_file_spreadsheet"
        case .presentation: return "ic_file_presentation"
        case .executable: return "ic_file_executable"
        case .file: return "ic_file"
        }
    }
}

/// Android `RemoteFileIcon`: a drawn folder, a coloured label badge, or a tinted glyph; links get an arrow mark.
struct RemoteFileIcon: View {
    let name: String
    var directory = false
    var permissions: UInt32 = 0
    var link = false
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            switch FileIconTheme.spec(name: name, directory: directory, permissions: permissions) {
            case .folder(let color):
                Canvas { context, canvas in
                    let w = canvas.width, h = canvas.height, tint = Color(uiColor: UIColor(hex: color))
                    var tab = Path()
                    tab.move(to: CGPoint(x: w * 0.06, y: h * 0.27)); tab.addLine(to: CGPoint(x: w * 0.06, y: h * 0.24))
                    tab.addQuadCurve(to: CGPoint(x: w * 0.14, y: h * 0.16), control: CGPoint(x: w * 0.06, y: h * 0.16))
                    tab.addLine(to: CGPoint(x: w * 0.38, y: h * 0.16)); tab.addLine(to: CGPoint(x: w * 0.48, y: h * 0.27)); tab.closeSubpath()
                    context.fill(tab, with: .color(tint.opacity(0.75)))
                    context.fill(Path(roundedRect: CGRect(x: w * 0.06, y: h * 0.27, width: w * 0.88, height: h * 0.57), cornerRadius: w * 0.08), with: .color(tint))
                }
            case .badge(let label, let color, let labelColor):
                let inset = size * 0.08
                RoundedRectangle(cornerRadius: size * 0.18).fill(Color(uiColor: UIColor(hex: color))).padding(inset)
                Text(label).font(.system(size: size * (label.count == 1 ? 0.5 : label.count == 2 ? 0.4 : 0.31), weight: .bold))
                    .tracking(-size * 0.012).foregroundStyle(Color(uiColor: UIColor(hex: labelColor))).lineLimit(1).fixedSize()
            case .glyph(let kind, let color):
                AppIcon(FileIconTheme.glyphIcon(kind), size: size).foregroundStyle(Color(uiColor: UIColor(hex: color)))
            case .android(let color):
                AppIcon("ic_file_android", size: size).foregroundStyle(Color(uiColor: UIColor(hex: color)))
            }
            if link {
                let r = size * 0.21
                ZStack {
                    Circle().fill(Palette.surface).frame(width: 2 * (r + size * 0.05), height: 2 * (r + size * 0.05))
                    Circle().fill(Color(uiColor: UIColor(hex: 0x42A5F5))).frame(width: 2 * r, height: 2 * r)
                    Image(systemName: "arrow.up.right").font(.system(size: r * 1.1, weight: .bold)).foregroundStyle(.white)
                }.position(x: size - r, y: size - r)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
