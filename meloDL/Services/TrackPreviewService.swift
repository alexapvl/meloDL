import AppKit
import Foundation
import Quartz

@MainActor
final class TrackPreviewService: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = TrackPreviewService()

    private var previewItems: [PreviewItem] = []

    func previewTrack(atPath path: String, title: String?) {
        let fileURL = URL(fileURLWithPath: path)
        let item = PreviewItem(url: fileURL, title: title)
        previewItems = [item]

        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(fileURL)
            return
        }

        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index]
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String?) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}
