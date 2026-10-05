import AppKit
import MKBCore

/// Shares the general pasteboard with the space (a Universal Clipboard look-alike).
final class ClipboardSync {
    static let maxBytes = 16 << 20
    static let types: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .html, .png, .tiff, .URL, .pdf,
    ]

    var onLocalChange: (([ClipboardItem]) -> Void)?
    var isEnabled = true

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ items: [ClipboardItem]) {
        guard isEnabled, !items.isEmpty else { return }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for i in items {
            item.setData(i.data, forType: NSPasteboard.PasteboardType(i.type))
        }
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard isEnabled, let first = pasteboard.pasteboardItems?.first else { return }
        // Respect apps that mark content as transient or concealed (password managers).
        let skip = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "com.agilebits.onepassword"]
        if first.types.contains(where: { skip.contains($0.rawValue) }) { return }

        var items: [ClipboardItem] = []
        var total = 0
        for type in Self.types where first.types.contains(type) {
            guard let data = first.data(forType: type) else { continue }
            total += data.count
            if total > Self.maxBytes { return }
            items.append(ClipboardItem(type: type.rawValue, data: data))
        }
        if !items.isEmpty { onLocalChange?(items) }
    }
}
