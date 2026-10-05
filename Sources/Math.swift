import AppKit
import WebKit

/// Formulas on cards, drawn offline with KaTeX (Resources/katex) into a picture, the way the
/// Android version draws them with JLaTeXMath. One web view, off screen, lays out a card side
/// and photographs it; the card itself shows only the picture, so it flips, scales and sits
/// on glass like any other image.
final class MathRenderer: NSObject, WKNavigationDelegate {
    static let shared = MathRenderer()

    /// Text the parser in card.html would treat as math - the same signals as its autoWrapMath.
    static func hasMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
            || text.range(of: #"\\[a-zA-Z]"#, options: .regularExpression) != nil
            || text.range(of: #"[A-Za-z0-9]\^[{A-Za-z0-9+-]|[A-Za-z0-9]_[{0-9A-Za-z]"#, options: .regularExpression) != nil
    }

    struct Key: Hashable {
        let text: String
        let width: Int
        let size: Int
        let color: String
    }

    private let web: WKWebView
    private let window: NSWindow
    private var loaded = false
    private var waitingForLoad: [CheckedContinuation<Void, Never>] = []
    /// Renders go one at a time: they share the one web view.
    private var queue: Task<Void, Never>?
    private var cache: [Key: NSImage] = [:]

    private override init() {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        // Off screen but in a real window, so it lays out and draws at the screen's scale.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        super.init()
        web.navigationDelegate = self
        if let page = Bundle.main.url(forResource: "card", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded = true
            self.waitingForLoad.forEach { $0.resume() }
            self.waitingForLoad = []
        }
    }

    func cached(_ key: Key) -> NSImage? { cache[key] }

    /// The text laid out at most `width` points wide in `size`-point type; nil if it fails.
    func image(_ key: Key) async -> NSImage? {
        if let hit = cache[key] { return hit }
        let previous = queue
        let task = Task { () -> NSImage? in
            await previous?.value
            if let hit = cache[key] { return hit }
            let img = await draw(key)
            if let img {
                if cache.count > 200 { cache.removeAll() }
                cache[key] = img
            }
            return img
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func draw(_ key: Key) async -> NSImage? {
        if !loaded { await withCheckedContinuation { waitingForLoad.append($0) } }
        // Room for the text to lay out in; the photo then takes only what it covers.
        resize(NSSize(width: CGFloat(key.width) + 40, height: 3000))
        let args: [String: Any] = ["t": key.text, "w": key.width, "s": key.size, "c": key.color]
        guard let size = try? await web.callAsyncJavaScript(
            "return await render(t, w, s, c)", arguments: args, contentWorld: .page) as? [NSNumber],
              size.count == 2 else { return nil }
        let w = max(1, CGFloat(truncating: size[0])), h = max(1, CGFloat(truncating: size[1]))
        if w > web.frame.width || h > web.frame.height {
            resize(NSSize(width: max(w, web.frame.width), height: max(h, web.frame.height)))
        }
        // Let WebKit paint before the photo.
        try? await Task.sleep(for: .milliseconds(30))
        let shot = WKSnapshotConfiguration()
        shot.rect = NSRect(x: 0, y: 0, width: w, height: h)
        shot.afterScreenUpdates = true
        return try? await web.takeSnapshot(configuration: shot)
    }

    private func resize(_ size: NSSize) {
        window.setContentSize(size)
        web.frame = NSRect(origin: .zero, size: size)
    }
}
