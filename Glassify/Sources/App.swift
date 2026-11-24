import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    #if DEBUG
    /// `--test`: a silent copy for automated checks. Its own settings, and no Spotify, audio or screen access.
    let testMode = CommandLine.arguments.contains("--test")
    lazy var defaults: UserDefaults = testMode ? UserDefaults(suiteName: "app.glassify.widget.test")! : .standard
    #else
    let testMode = false
    let defaults = UserDefaults.standard
    #endif
    var panel: WidgetPanel!
    var web: WidgetWebView!
    var backdrop: NSView!

    let frames = FrameStore()
    lazy var capture = ScreenCapture(store: frames)
    let tap = SpotifyTap()
    let spectrum = Spectrum()
    let spotify = NowPlaying()
    var link: CADisplayLink?

    // what the page last told us about its layout (points)
    var fitW: CGFloat = 600
    var fitStrip: CGFloat = 600 / ASPECT
    var fitPanel: CGFloat = 0
    var shapeW: CGFloat = 600
    var shapeH: CGFloat = 600 / ASPECT
    var shapeR: CGFloat = 300 / ASPECT

    var shrink: DispatchWorkItem?
    var dragFrom: (mouse: NSPoint, origin: NSPoint)?
    var pageReady = false
    var playing = false
    var clearOn = false
    var bandCount = 24
    var monitors: [Any] = []

    // MARK: - launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = defaults.string(forKey: "settings")
        var scale: CGFloat = 1
        if let d = settings?.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let s = j["scale"] as? Double, s >= 0.5, s <= 1.6 { scale = s }
            if let n = j["N"] as? Int, n >= 4, n <= 40 { bandCount = n }
        }
        fitW = (600 * scale).rounded(); fitStrip = fitW / ASPECT
        shapeW = fitW; shapeH = fitStrip; shapeR = fitStrip / 2

        panel = WidgetPanel(contentRect: startFrame(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                       // the glass draws its own shadow
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true               // until the mouse is over the glass itself
        // Pinned in front: one step below the menu bar, which is above ordinary windows, other apps' floating palettes
        // (After Effects and friends raise theirs when they become active) and the Dock; menus still open over it.
        // (Set last: marking a panel as "floating" would put it back on the ordinary floating level.)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

        let root = FlippedView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        panel.contentView = root

        // the desktop showing through the slightly see-through glass is blurred by the window (see Backdrop.swift)
        backdrop = Backdrop.exact() ?? Backdrop.system()
        root.addSubview(backdrop)
        layoutBackdrop()

        let cfg = WKWebViewConfiguration()
        let server = PageServer(frames: frames)
        server.settings = { [weak self] in self?.defaults.string(forKey: "settings") }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--web"), i + 1 < CommandLine.arguments.count { server.webRoot = URL(fileURLWithPath: CommandLine.arguments[i + 1]) }
        #endif
        cfg.setURLSchemeHandler(server, forURLScheme: "glassify")
        cfg.userContentController.add(self, name: "glassify")
        #if DEBUG
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if testMode { cfg.websiteDataStore = .nonPersistent() }
        #endif
        web = WidgetWebView(frame: root.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        web.allowsMagnification = false
        root.addSubview(web)
        web.load(URLRequest(url: URL(string: "glassify://app/index.html")!))
        panel.makeFirstResponder(web)

        capture.onFrame = { [weak self] in
            guard let self, self.pageReady, self.clearOn else { return }
            self.web.evaluateJavaScript("__gw.frame()", completionHandler: nil)
        }
        spotify.onState = { [weak self] s in self?.spotifyChanged(s) }
        spotify.onTrack = { [weak self] title, artist, cover in self?.sendTrack(title, artist, cover) }

        let l = web.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .rightMouseUp, .leftMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouse(e) }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouse(e); return e }) { monitors.append(m) }
        // safety net in case a move slips past the monitors
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.updatePassThrough() }
        RunLoop.main.add(t, forMode: .common)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.panel.allowKey = false }
        nc.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in self?.regionChanged() }
        nc.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in self?.regionChanged() }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.keepReachable(); self?.regionChanged() }

        panel.orderFrontRegardless()
        if !testMode { spotify.start() }
        #if DEBUG
        startDebug()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePosition()
        tap.shutdown()
        capture.setWanted(false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "glassify" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.load(URLRequest(url: URL(string: "glassify://app/index.html")!))
    }

    // MARK: - window geometry

    var widgetTopLeft: NSPoint { NSPoint(x: panel.frame.minX + PADX, y: panel.frame.maxY - PADT) }

    func windowSize(panelHeight: CGFloat) -> NSSize {
        NSSize(width: ceil(fitW) + 2 * PADX, height: ceil(fitStrip + panelHeight) + PADT + PADB)
    }

    func startFrame() -> NSRect {
        let size = windowSize(panelHeight: 0)
        var tl: NSPoint?
        if defaults.object(forKey: "x") != nil {
            let p = NSPoint(x: defaults.double(forKey: "x"), y: defaults.double(forKey: "y"))
            if handleOnScreen(p) { tl = p }
        }
        if tl == nil {
            let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            tl = NSPoint(x: (v.midX - fitW / 2).rounded(), y: (v.maxY - 96).rounded())
        }
        return NSRect(x: tl!.x - PADX, y: tl!.y + PADT - size.height, width: size.width, height: size.height)
    }

    /// True when the small move bar at the top of the glass is somewhere a mouse can reach.
    func handleOnScreen(_ topLeft: NSPoint) -> Bool {
        let handle = NSPoint(x: topLeft.x + fitW / 2, y: topLeft.y - 11)
        return NSScreen.screens.contains { $0.frame.insetBy(dx: 8, dy: 8).contains(handle) }
    }

    func keepReachable() {
        guard !handleOnScreen(widgetTopLeft) else { return }
        let v = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let tl = NSPoint(x: min(max(widgetTopLeft.x, v.minX + 8), v.maxX - fitW - 8), y: min(max(widgetTopLeft.y, v.minY + fitStrip + 8), v.maxY - 8))
        panel.setFrameOrigin(NSPoint(x: tl.x - PADX, y: tl.y + PADT - panel.frame.height))
        savePosition()
    }

    func savePosition() {
        let p = widgetTopLeft
        defaults.set(Double(p.x), forKey: "x")
        defaults.set(Double(p.y), forKey: "y")
    }

    func setWindowSize(_ s: NSSize) {
        var f = panel.frame
        guard f.size != s else { return }
        f.origin.y = f.maxY - s.height          // the top-left corner stays put
        f.size = s
        panel.setFrame(f, display: true)
    }

    /// The page says how big the glass is (and how tall its open settings are). Grow at once, shrink once the motion has finished.
    func applyFit(w: CGFloat, strip: CGFloat, panelH: CGFloat) {
        fitW = w; fitStrip = strip; fitPanel = panelH
        let target = windowSize(panelHeight: panelH)
        let cur = panel.frame.size
        setWindowSize(NSSize(width: max(cur.width, target.width), height: max(cur.height, target.height)))
        shrink?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setWindowSize(self.windowSize(panelHeight: self.fitPanel))
            self.regionChanged()
        }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        regionChanged()
        savePosition()
    }

    func layoutBackdrop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = NSRect(x: PADX + 0.5, y: PADT + 0.5, width: max(0, shapeW - 1), height: max(0, shapeH - 1))
        backdrop.layer?.cornerRadius = max(0, min(shapeR, shapeH / 2, shapeW / 2) - 0.5)
        CATransaction.commit()
    }

    /// Tells the screen capture which part of the screen sits behind the glass.
    func regionChanged() {
        guard clearOn else { return }
        let f = panel.frame
        // 0.7 of a strip more than the glass covers (the glass bends what lies just below it into view), rounded up to
        // whole picture rows: the page works at 166 rows per strip-height, so its copy of the picture is exact.
        let px = min(996, ((Double((f.height - PADT - PADB) / max(1, fitStrip)) + 0.7) * 166).rounded(.up))
        let rows = px / 166
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0     // global display coordinates count down from the top of the main screen
        let r = CGRect(x: f.minX + PADX, y: primaryTop - (f.maxY - PADT), width: fitW, height: fitStrip * CGFloat(rows))
        capture.setRegion(r, rows: rows)
    }

    // MARK: - mouse: only the glass itself takes clicks; the clear margin around it lets them through

    func glassContains(_ p: NSPoint) -> Bool {
        let f = panel.frame
        let r = NSRect(x: f.minX + PADX, y: f.maxY - PADT - shapeH, width: shapeW, height: shapeH)
        guard r.contains(p) else { return false }
        let rad = min(shapeR, shapeH / 2, shapeW / 2)
        let cx = min(max(p.x, r.minX + rad), r.maxX - rad), cy = min(max(p.y, r.minY + rad), r.maxY - rad)
        return hypot(p.x - cx, p.y - cy) <= rad
    }

    func updatePassThrough() {
        guard NSEvent.pressedMouseButtons == 0, dragFrom == nil else { return }
        let through = !glassContains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }
    }

    func mouse(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDragged:
            if let d = dragFrom {
                let m = NSEvent.mouseLocation
                panel.setFrameOrigin(NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y))
            }
        case .leftMouseUp:
            endDrag()
            updatePassThrough()
        default:
            updatePassThrough()
        }
    }

    func endDrag() {
        guard dragFrom != nil else { return }
        dragFrom = nil
        savePosition()
    }

    // MARK: - messages from the page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let t = m["t"] as? String else { return }
        func num(_ k: String) -> CGFloat? { (m[k] as? NSNumber).map { CGFloat(truncating: $0) }.flatMap { $0.isFinite ? $0 : nil } }
        switch t {
        case "ready":
            pageReady = true
            spotify.resend()
            if clearOn, frames.get() != nil { web.evaluateJavaScript("__gw.frame()", completionHandler: nil) }
            web.evaluateJavaScript("__gw.playing(\(playing))", completionHandler: nil)
        case "save":
            if let j = m["json"] as? String, j.count < 20000 { defaults.set(j, forKey: "settings") }
        case "fit":
            if let w = num("w"), let s = num("strip"), let p = num("panel"), w >= 200, w <= 1200, s > 20, p >= 0, p < 2000 { applyFit(w: w, strip: s, panelH: p) }
        case "shape":
            if let w = num("w"), let h = num("h"), let r = num("r"), w > 0, h > 0 {
                shapeW = w; shapeH = h; shapeR = r
                layoutBackdrop()
                updatePassThrough()
            }
        case "clear":
            clearOn = (m["on"] as? Bool) ?? false
            if clearOn { regionChanged() } else { frames.clear() }
            if !testMode { capture.setWanted(clearOn) }
        case "drag":
            if NSEvent.pressedMouseButtons & 1 != 0 { dragFrom = (NSEvent.mouseLocation, panel.frame.origin) }
        case "dragEnd":
            endDrag()
        case "nudge":
            if let dx = num("dx"), let dy = num("dy") {
                let o = panel.frame.origin
                panel.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y - dy))
                keepReachable()
                savePosition()
            }
        case "key":
            if !panel.reallyKey { panel.takeKeyboard() }
        default:
            break
        }
    }

    // MARK: - Spotify -> page

    func spotifyChanged(_ s: NowPlaying.State) {
        switch s {
        case .playing:
            tap.setWanted(true); link?.isPaused = false; setPlaying(true)
        case .unknown:
            // Spotify is open but may not be asked what it is doing: listen, and let the sound itself decide (see tick)
            tap.setWanted(true); link?.isPaused = false
        case .paused, .notRunning:
            tap.setWanted(false); link?.isPaused = true; spectrum.reset(); setPlaying(false)
            if pageReady { web.evaluateJavaScript("__gw.bands([])", completionHandler: nil) }
        }
    }

    func setPlaying(_ p: Bool) {
        guard p != playing else { return }
        playing = p
        if pageReady { web.evaluateJavaScript("__gw.playing(\(p))", completionHandler: nil) }
    }

    func sendTrack(_ title: String, _ artist: String, _ cover: String?) {
        guard pageReady else { return }
        web.callAsyncJavaScript("__gw.track(t,a,c)", arguments: ["t": title, "a": artist, "c": cover ?? NSNull()], in: nil, in: .page, completionHandler: nil)
    }

    private var quiet = 0

    /// Once per screen refresh while music may be playing: analyse the newest sound and hand the bar energies to the page.
    @objc func tick(_ l: CADisplayLink) {
        guard pageReady else { return }
        let b = spectrum.bands(from: tap, count: bandCount)
        if spotify.state == .unknown {
            if let b, b.contains(where: { $0 > 0.02 }) { quiet = 0; setPlaying(true) }
            else { quiet += 1; if quiet > 90 { setPlaying(false) } }
        }
        guard let b else { return }
        var s = "__gw.bands(["
        s.reserveCapacity(200)
        for (i, v) in b.enumerated() {
            if i > 0 { s += "," }
            s += v <= 0 ? "0" : String(format: "%.3f", v)
        }
        s += "])"
        web.evaluateJavaScript(s, completionHandler: nil)
    }
}
