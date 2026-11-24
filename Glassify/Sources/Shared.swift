import AppKit
import WebKit

/// Room around the glass inside the transparent window, so the page's own drop shadow has somewhere to fall.
/// These match `.widget{left:56px;top:32px}` in Web/index.html.
let PADX: CGFloat = 56
let PADT: CGFloat = 32
let PADB: CGFloat = 80
let ASPECT: CGFloat = 4.6

func note(_ s: @autoclosure () -> String) {
    NSLog("Glassify: %@", s())
}

func trace(_ s: @autoclosure () -> String) {
    #if DEBUG
    NSLog("Glassify· %@", s())
    #endif
}

/// The newest picture of the screen behind the glass, shared between the capture queue and the page.
final class FrameStore {
    private var lock = os_unfair_lock()
    private var data = Data()
    private var w = 0, h = 0
    private var rows = 1.0

    func set(_ d: Data, w: Int, h: Int, rows: Double) {
        os_unfair_lock_lock(&lock)
        data = d; self.w = w; self.h = h; self.rows = rows
        os_unfair_lock_unlock(&lock)
    }

    func get() -> (data: Data, w: Int, h: Int, rows: Double)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return w > 0 ? (data, w, h, rows) : nil
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        data = Data(); w = 0; h = 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Serves the page itself and the screen pictures to it under glassify://app/…
final class PageServer: NSObject, WKURLSchemeHandler {
    let frames: FrameStore
    /// The saved settings as JSON text; the app's copy is the one that counts.
    var settings: () -> String? = { nil }
    /// Development only: read the page from another folder instead of the app bundle.
    var webRoot: URL?
    init(frames: FrameStore) { self.frames = frames }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == "/frame" {
            guard let f = frames.get() else {
                let r = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "no-store"])!
                task.didReceive(r); task.didFinish(); return
            }
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/octet-stream", "Content-Length": String(f.data.count), "Cache-Control": "no-store",
                "X-W": String(f.w), "X-H": String(f.h), "X-Rows": String(format: "%.4f", f.rows),
            ])!
            task.didReceive(r); task.didReceive(f.data); task.didFinish()
            return
        }
        let name = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        guard !name.contains(".."), let file = (webRoot ?? Bundle.main.resourceURL?.appendingPathComponent("Web"))?.appendingPathComponent(name),
              var d = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish(); return
        }
        if name == "index.html", let json = settings(), let lit = try? JSONEncoder().encode(json), let js = String(data: lit, encoding: .utf8),
           let page = String(data: d, encoding: .utf8) {
            // hand the page its saved settings before its script starts
            let safe = js.replacingOccurrences(of: "</", with: "<\\/")
            d = Data(page.replacingOccurrences(of: "/*GLASSIFY_SETTINGS*/", with: "try{localStorage.setItem('glasswake.v1',\(safe))}catch(e){}").utf8)
        }
        let type = name.hasSuffix(".html") ? "text/html; charset=utf-8" : "application/octet-stream"
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Content-Length": String(d.count)])!
        task.didReceive(r); task.didReceive(d); task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A borderless floating panel. It does not activate the app, so the editor underneath keeps the keyboard.
final class WidgetPanel: NSPanel {
    /// WebKit only tracks hover, sets cursors and draws controls as live while its window counts as key.
    /// The widget must behave that way while another app is in front, so it reports itself as key,
    /// except in the moment it really asks for the keyboard.
    var pretendKey = true

    override var isKeyWindow: Bool { pretendKey ? true : super.isKeyWindow }
    var reallyKey: Bool { super.isKeyWindow }
    /// The widget only takes the keyboard after a click inside its settings, never by being hovered or by a press on the bars.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func takeKeyboard() {
        allowKey = true
        pretendKey = false
        makeKey()
        pretendKey = true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class WidgetWebView: WKWebView {
    private var always: NSTrackingArea?

    /// WebKit's own tracking area only reports the mouse in a key window; this one reports it always.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = always { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        always = a
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
        let quit = NSMenuItem(title: "Quit Glassify", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }
}
