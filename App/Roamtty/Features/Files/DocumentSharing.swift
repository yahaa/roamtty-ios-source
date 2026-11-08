import SwiftUI
import UIKit

struct SharedArtifact: Identifiable { let id = UUID(); let url: URL }
struct ShareActivity: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct ExportDocuments: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: urls, asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
