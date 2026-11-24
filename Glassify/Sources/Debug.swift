#if DEBUG
import AppKit
import ScreenCaptureKit
import WebKit

/// Development only (never compiled into the app that ships): lets a test script poke the running widget.
/// Start with `--debug <folder>`; the app then reads `<folder>/cmd`, runs it and writes `<folder>/out`.
nonisolated(unsafe) var debugPages: [String: (NSWindow, WKWebView)] = [:]

extension AppDelegate {
    func startDebug() {
        let args = CommandLine.arguments
        // the folder comes from `--debug <folder>`, or (when macOS itself relaunched the app) from the saved `debugDir` setting
        var path = UserDefaults.standard.string(forKey: "debugDir")
        if let i = args.firstIndex(of: "--debug"), i + 1 < args.count { path = args[i + 1] }
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        let dir = URL(fileURLWithPath: path)
        let cmd = dir.appendingPathComponent("cmd"), out = dir.appendingPathComponent("out")
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let text = try? String(contentsOf: cmd, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: cmd)
            self.debugRun(text, dir: dir) { result in try? result.write(to: out, atomically: true, encoding: .utf8) }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func synth(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 0) -> NSEvent {
        // x,y are page coordinates (origin top-left of the window)
        let p = NSPoint(x: x, y: panel.frame.height - y)
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0)!
    }

    private func debugRun(_ text: String, dir: URL, done: @escaping (String) -> Void) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let nums = rest.split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
        switch parts.first ?? "" {
        case "js":
            web.evaluateJavaScript(rest) { v, e in done(e.map { "ERR \($0)" } ?? String(describing: v ?? "nil")) }
        case "snap":
            let c = WKSnapshotConfiguration()
            web.takeSnapshot(with: c) { img, e in
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { done("ERR \(String(describing: e))"); return }
                try? png.write(to: dir.appendingPathComponent(rest.isEmpty ? "snap.png" : rest))
                done("ok \(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        case "move":
            web.mouseMoved(with: synth(.mouseMoved, nums[0], nums[1])); done("ok")
        case "down":
            web.mouseDown(with: synth(.leftMouseDown, nums[0], nums[1], clicks: 1)); done("ok")
        case "up":
            web.mouseUp(with: synth(.leftMouseUp, nums[0], nums[1], clicks: 1)); done("ok")
        case "click":
            web.mouseDown(with: synth(.leftMouseDown, nums[0], nums[1], clicks: 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.web.mouseUp(with: self.synth(.leftMouseUp, nums[0], nums[1], clicks: 1)); done("ok")
            }
        case "key":
            panel.takeKeyboard(); done("reallyKey=\(panel.reallyKey) appKey=\(NSApp.keyWindow === panel)")
        case "origin":
            panel.setFrameOrigin(NSPoint(x: nums[0], y: nums[1])); done("ok")
        case "pv":
            // Comparison pages in ordinary hidden windows, drawn by the same engine. Their animation clock is stepped by hand
            // (`__step(n)` runs n frames of 1/60 s), so two pages can be brought to exactly the same moment and compared.
            let sub = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard sub.count >= 2 else { done("?"); return }
            let name = sub[1], arg = sub.count > 2 ? sub[2] : ""
            if sub[0] == "open" {
                let cfg = WKWebViewConfiguration()
                cfg.websiteDataStore = .nonPersistent()
                cfg.userContentController.addUserScript(WKUserScript(source: """
                    window.__cb=null; window.__now=0;
                    window.requestAnimationFrame=function(cb){ window.__cb=cb; return 1; };
                    window.__step=function(n){ for(let i=0;i<n;i++){ const cb=window.__cb; window.__cb=null; window.__now+=1000/60; if(cb) cb(window.__now); } return window.__now; };
                    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
                let v = WKWebView(frame: w.contentView!.bounds, configuration: cfg); v.autoresizingMask = [.width, .height]
                w.contentView!.addSubview(v); w.isReleasedWhenClosed = false
                w.setFrameOrigin(NSPoint(x: -3000, y: -3000)); w.orderBack(nil)
                let u = URL(fileURLWithPath: arg); v.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
                debugPages[name] = (w, v); done("ok")
            } else if sub[0] == "js", let v = debugPages[name]?.1 {
                v.evaluateJavaScript(arg) { r, e in done(e.map { "ERR \($0)" } ?? String(describing: r ?? "nil")) }
            } else if sub[0] == "snap", let v = debugPages[name]?.1 {
                let f = arg.split(separator: " ").map(String.init)
                let c = WKSnapshotConfiguration()
                if f.count >= 5, let x = Double(f[1]), let y = Double(f[2]), let w = Double(f[3]), let h = Double(f[4]) { c.rect = CGRect(x: x, y: y, width: w, height: h) }
                v.takeSnapshot(with: c) { img, e in
                    guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { done("ERR"); return }
                    try? png.write(to: dir.appendingPathComponent(f[0])); done("ok \(rep.pixelsWide)x\(rep.pixelsHigh)")
                }
            } else { done("?") }
        case "cmp":
            // how different are two snapshots: size, largest channel difference, share of pixels off by more than 2/255
            let f = rest.split(separator: " ").map(String.init)
            func load(_ n: String) -> (Int, Int, [UInt8])? {
                guard let img = NSImage(contentsOf: dir.appendingPathComponent(n)), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                let w = cg.width, h = cg.height
                var buf = [UInt8](repeating: 0, count: w * h * 4)
                let ok = buf.withUnsafeMutableBytes { p -> Bool in
                    guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
                }
                return ok ? (w, h, buf) : nil
            }
            guard f.count >= 2, let a = load(f[0]), let b = load(f[1]) else { done("ERR load"); return }
            guard a.0 == b.0, a.1 == b.1 else { done("sizes differ \(a.0)x\(a.1) vs \(b.0)x\(b.1)"); return }
            var maxD = 0, off = 0, sum = 0
            for i in stride(from: 0, to: a.2.count, by: 4) {
                var d = 0
                for c in 0..<3 { d = max(d, abs(Int(a.2[i + c]) - Int(b.2[i + c]))) }
                maxD = max(maxD, d); sum += d; if d > 2 { off += 1 }
            }
            let n = a.2.count / 4
            done("\(a.0)x\(a.1) max=\(maxD) mean=\(String(format: "%.3f", Double(sum) / Double(n))) pixelsOffBy>2=\(off) (\(String(format: "%.3f", 100 * Double(off) / Double(n)))%)")
        case "fake":
            // a made-up picture of "the screen" for the page, to test the hand-over without any screen access:
            // left half red, right half green, with a blue band across the first strip-height's lower half
            let rows = nums.first.map { Double($0) } ?? 1.7048
            let W = 768, H = Int((166 * rows).rounded())
            var px = [UInt8](repeating: 255, count: W * H * 4)
            for y in 0..<H { for x in 0..<W {
                let i = (y * W + x) * 4
                px[i] = x < W / 2 ? 220 : 20; px[i + 1] = x < W / 2 ? 30 : 200; px[i + 2] = (y >= 83 && y < 166) ? 230 : 30
            } }
            frames.set(Data(px), w: W, h: H, rows: Double(H) / 166)
            web.evaluateJavaScript("__gw.frame()", completionHandler: nil); done("ok \(W)x\(H)")
        case "frame":
            // save the picture last handed to the page
            guard let f = frames.get(), let prov = CGDataProvider(data: f.data as CFData),
                  let cg = CGImage(width: f.w, height: f.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { done("no frame"); return }
            try? png.write(to: dir.appendingPathComponent(rest.isEmpty ? "frame.png" : rest)); done("ok \(f.w)x\(f.h) rows=\(f.rows)")
        case "shot":
            // a real screenshot (everything, the widget included) of a rectangle given in global display points: x y w h
            guard nums.count >= 4 else { done("?"); return }
            let r = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
            let name = rest.split(separator: " ").count > 4 ? String(rest.split(separator: " ")[4]) : "shot.png"
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                guard let content, let d = content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(r) }) else { done("ERR \(String(describing: error))"); return }
                let b = CGDisplayBounds(d.displayID)
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = r.offsetBy(dx: -b.minX, dy: -b.minY)
                cfg.width = Int(r.width * 2); cfg.height = Int(r.height * 2); cfg.showsCursor = false
                cfg.colorSpaceName = CGColorSpace.sRGB
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, e in
                    guard let img, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { done("ERR \(String(describing: e))"); return }
                    try? png.write(to: dir.appendingPathComponent(name)); done("ok \(img.width)x\(img.height)")
                }
            }
        case "region":
            let f = panel.frame
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - (f.maxY - PADT)
            done("widget global x=\(f.minX + PADX) y=\(top) w=\(fitW) strip=\(fitStrip)")
        case "bd":
            // swap what blurs the desktop behind the glass: `bd exact` or `bd system <material number>`
            let f = rest.split(separator: " ").map(String.init)
            var v: NSView?
            if f.first == "exact" { v = Backdrop.exact() }
            else { v = Backdrop.system(material: NSVisualEffectView.Material(rawValue: Int(f.count > 1 ? f[1] : "13") ?? 13) ?? .hudWindow) }
            guard let v, let root = panel.contentView else { done("not available"); return }
            backdrop.removeFromSuperview()
            backdrop = v
            root.addSubview(v, positioned: .below, relativeTo: web)
            layoutBackdrop(); done("ok \(type(of: v)) layer=\(type(of: v.layer!))")
        case "info":
            let f = panel.frame
            done("""
            frame=\(f) ignores=\(panel.ignoresMouseEvents) reallyKey=\(panel.reallyKey) visible=\(panel.isVisible) screen=\(panel.screen?.frame ?? .zero)
            fit w=\(fitW) strip=\(fitStrip) panel=\(fitPanel) shape=\(shapeW)x\(shapeH) r=\(shapeR) backdrop=\(backdrop.frame)
            spotify=\(spotify.state) playing=\(playing) ready=\(pageReady) linkPaused=\(link?.isPaused ?? true)
            tap built=\(tap.isBuilt) running=\(tap.isRunning) rate=\(tap.sampleRate) callbacks=\(tap.callbacks) peak=\(tap.peak)
            capture clear=\(clearOn) status=\(capture.status) frames=\(capture.framesSeen) sent=\(capture.framesSent) still=\(capture.isStill) preflight=\(CGPreflightScreenCaptureAccess()) backdrop=\(type(of: backdrop!))
            """)
        default:
            done("?")
        }
    }
}
#endif
