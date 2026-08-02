import AppKit
@preconcurrency import QuickLookUI

final class QuickLookController: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookController()
    private var previewURL: URL?

    @MainActor func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
