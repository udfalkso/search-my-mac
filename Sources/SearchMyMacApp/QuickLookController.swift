import AppKit
@preconcurrency import QuickLookUI

final class QuickLookController: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookController()
    private var previewURL: URL?

    @MainActor var isVisible: Bool {
        QLPreviewPanel.shared()?.isVisible == true
    }

    @MainActor func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(url)
        }
    }

    @MainActor func updateIfVisible(_ url: URL) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
