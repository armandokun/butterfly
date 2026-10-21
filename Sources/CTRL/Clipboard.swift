import AppKit

/// Clipboard history (text only, in memory, last 30). Skips password managers' concealed items.
/// "Paste the link I copied before" → Jev picks the item → it goes on the clipboard and ⌘V.
@MainActor
final class Clipboard {
    static let shared = Clipboard()
    struct Item { let text: String; let at: Date }
    private(set) var items: [Item] = []   // newest first
    private var count = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var ignoreNext = false

    func seed(_ texts: [String]) { items = texts.map { Item(text: $0, at: Date()) } }   // CLI tests

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Task { @MainActor in Clipboard.shared.poll() } }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != count else { return }
        count = pb.changeCount
        if ignoreNext { ignoreNext = false; return }
        let types = pb.types ?? []
        let secret = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]
        guard !types.contains(where: { secret.contains($0.rawValue) }),
              let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        items.removeAll { $0.text == text }
        items.insert(Item(text: text, at: Date()), at: 0)
        if items.count > 30 { items.removeLast(items.count - 30) }
    }

    /// Options for Jev: c0 = newest.
    var options: [String: String] {
        var o: [String: String] = [:]
        for (i, it) in items.prefix(30).enumerated() {
            let ago = Int(Date().timeIntervalSince(it.at) / 60)
            let when = i == 0 ? "the current clipboard (copied most recently)" : i == 1 ? "copied just before the current one" : "copied \(i + 1)th most recently"
            let preview = it.text.prefix(160).replacingOccurrences(of: "\n", with: " ")
            o["c\(i)"] = "“\(preview)” — \(when), \(ago == 0 ? "under a minute" : "\(ago) min") ago"
        }
        return o
    }

    func item(_ key: String) -> Item? {
        guard let i = Int(key.dropFirst()), items.indices.contains(i) else { return nil }
        return items[i]
    }

    /// Puts it on the clipboard (as newest) and pastes into the app in front.
    func paste(_ item: Item, into app: NSRunningApplication?) async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        app?.activate()
        try? await Task.sleep(for: .milliseconds(120))
        Keys.press(9, flags: .maskCommand)   // ⌘V
    }
}
