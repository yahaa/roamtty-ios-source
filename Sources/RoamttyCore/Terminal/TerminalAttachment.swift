import Foundation

/// Image attachments are uploaded separately, then pasted without submitting the command line.
public enum TerminalAttachment {
    public static func remotePNGPath(id: UUID = UUID()) -> String {
        "/tmp/roamtty-img-\(id.uuidString.lowercased()).png"
    }

    public static func imageInput(_ path: String, bracketed: Bool) throws -> String {
        let prefix = "/tmp/roamtty-img-", suffix = ".png"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix),
              let id = UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(suffix.count))),
              path == remotePNGPath(id: id) else { throw RoamError.invalid("Invalid image attachment path") }
        let text = " \(path) "
        return bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
    }
}

/// Validate the canonical SFTP destination and all names together before starting a batch.
public func uploadTargets(directory: RemoteDirectory, names: [String]) throws -> [String] {
    guard isValidRemoteDirectory(directory.path), !names.isEmpty,
          names.allSatisfy(isSafeRemoteEntryName), Set(names).count == names.count else {
        throw RoamError.invalid("Enter a valid destination and a different file name for each upload")
    }
    let existing = Set(directory.entries.map(\.name))
    guard !names.contains(where: { existing.contains($0) }) else {
        throw RoamError.invalid("A file with that name already exists. Choose another name or folder.")
    }
    let paths = names.map { joinRemotePath(directory: directory.path, name: $0) }
    guard paths.allSatisfy({ $0.utf16.count <= 4096 }) else { throw RoamError.invalid("Upload path is too long") }
    return paths
}
