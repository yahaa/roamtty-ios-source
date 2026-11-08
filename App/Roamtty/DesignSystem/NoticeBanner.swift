import SwiftUI

/// The short message at the top of the app; a tap or four seconds take it away.
struct NoticeBanner: View {
    @EnvironmentObject var model: AppModel
    let notice: String
    var body: some View {
        Text(notice).font(.subheadline).padding(16).frame(maxWidth: 500).background(Palette.raised, in: RoundedRectangle(cornerRadius: 20)).shadow(radius: 6).padding(16)
            .onTapGesture { model.notice = nil }
            .task(id: notice) { try? await Task.sleep(for: .seconds(4)); if model.notice == notice { model.notice = nil } }
    }
}
