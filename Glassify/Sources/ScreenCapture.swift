import Accelerate
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Clear mode: a live picture of the screen behind the glass, without the widget in it.
/// ScreenCaptureKit captures only a small rectangle around the widget (`sourceRect`) at low resolution, and it runs
/// only while Clear mode is showing. Pictures that are identical to the last one are dropped here, and while the
/// screen behind the glass stays still the capture slows to a few looks a second, so a static desktop costs very little.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let store: FrameStore
    /// Called on the main thread whenever a new picture is ready for the page.
    var onFrame: (() -> Void)?

    /// Extra screen captured around the needed area, so the picture stays right while the widget is being dragged.
    private let margin: CGFloat = 96
    /// The page works at 2 x 384 across and 2 x 83 per strip-height; pictures are delivered at exactly that size.
    private let outW = 768
    private let rowPx = 166.0
    private let activeRate: Int32 = 30
    private let stillRate: Int32 = 8
    /// Unchanged pictures in a row (at the active rate) before slowing down: about a second and a half.
    private let stillAfter = 45

    // main thread
    private var wanted = false
    private var starting = false
    private var asked = false
    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = 0
    private var displayBounds = CGRect.zero
    private var backing: CGFloat = 2
    private var region = CGRect.zero        // what the page needs, in global display points (origin top-left)
    private var rows = 1.7
    private var cfgRect = CGRect.zero       // what the stream was last asked to capture
    private var cfgScale: CGFloat = 1
    private var cfgStill = false
    private var still = false               // the screen behind the glass has not changed for a while
    private var updating = false
    private var settle: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private(set) var status = "off"

    // shared with the capture queue
    private let queue = DispatchQueue(label: "glassify.capture", qos: .utility)
    private var lock = os_unfair_lock()
    private var gRegion = CGRect.zero
    private var gRows = 1.7
    private var gRects: [CGRect] = []       // the rectangles the stream has been asked for lately (newest last)
    private var gOrigin = CGPoint.zero      // top-left of the captured display in global points
    private var renderQueued = false
    // capture queue only
    private var lastBuffer: CVPixelBuffer?
    private var lastRect = CGRect.zero      // the part of the screen that buffer shows
    private var lastContent = CGRect.zero   // where that picture sits inside the buffer, in pixels
    private var prev = [UInt8]()
    private var prevKey = ""
    private var unchanged = 0
    private var toldStill = false
    private(set) var framesSeen = 0
    private(set) var framesSent = 0

    init(store: FrameStore) { self.store = store }

    var isStill: Bool { still }

    // MARK: - control (main thread)

    func setWanted(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on { start() } else { stop() }
    }

    /// `r` is the screen area the page wants, starting at the top-left corner of the glass.
    func setRegion(_ r: CGRect, rows: Double) {
        guard r != region || rows != self.rows else { return }
        region = r; self.rows = rows
        os_unfair_lock_lock(&lock); gRegion = r; gRows = rows; os_unfair_lock_unlock(&lock)
        guard wanted, stream != nil else { return }
        if Self.display(for: r) != displayID { stop(); start(); return }
        reconfigure(recenter: false)
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reconfigure(recenter: true) }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        rerender()
    }

    private func start() {
        guard wanted, stream == nil, !starting, region.width > 1 else { return }
        guard CGPreflightScreenCaptureAccess() else {
            status = "no screen recording permission"
            if !asked { asked = true; note("Clear mode needs Screen Recording permission"); CGRequestScreenCaptureAccess() }
            again(in: 3)
            return
        }
        starting = true
        status = "starting"
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.starting = false
                guard self.wanted else { return }
                guard let content, error == nil else {
                    self.status = "screen content unavailable: \(error?.localizedDescription ?? "")"
                    self.again(in: 3); return
                }
                self.begin(with: content)
            }
        }
    }

    private func begin(with content: SCShareableContent) {
        let id = Self.display(for: region)
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { again(in: 3); return }
        displayID = display.displayID
        displayBounds = CGDisplayBounds(displayID)
        backing = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID })?.backingScaleFactor ?? 2

        // everything on the display except this app's own windows
        let pid = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let me = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == pid })
        }
        still = false
        let (cfg, rect, scale) = makeConfig()
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) } catch {
            status = "could not attach output: \(error.localizedDescription)"; again(in: 3); return
        }
        cfgRect = rect; cfgScale = scale; cfgStill = false
        os_unfair_lock_lock(&lock); gRects = [rect]; gOrigin = displayBounds.origin; os_unfair_lock_unlock(&lock)
        stream = s
        s.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = "could not start: \(error.localizedDescription)"
                    if self.stream === s { self.stream = nil }
                    self.again(in: 3)
                } else {
                    self.status = "capturing"
                    note("screen capture for Clear mode is running")
                    if !self.wanted { self.stop() }
                }
            }
        }
    }

    private func stop() {
        retry?.cancel(); settle?.cancel()
        status = "off"
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { _ in }
        queue.async { [weak self] in
            guard let self else { return }
            self.lastBuffer = nil; self.prev = []; self.prevKey = ""; self.unchanged = 0; self.toldStill = false
        }
    }

    private func again(in seconds: Double) {
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.start() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func makeConfig() -> (SCStreamConfiguration, CGRect, CGFloat) {
        var cap = region.insetBy(dx: -margin, dy: -margin).intersection(displayBounds).integral
        if cap.isNull || cap.width < 16 || cap.height < 16 {
            cap = CGRect(x: displayBounds.minX, y: displayBounds.minY, width: min(256, displayBounds.width), height: min(256, displayBounds.height))
        }
        // Enough pixels for the 768-wide picture, but never less than half the screen's own resolution:
        // the system's downscale stays gentle, and the careful averaging is done afterwards.
        let scale = min(backing, max(CGFloat(outW) / max(1, region.width), backing / 2))
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = cap.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)   // in the display's own points
        cfg.width = max(16, Int((cap.width * scale).rounded()))
        cfg.height = max(16, Int((cap.height * scale).rounded()))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: still ? stillRate : activeRate)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = false
        cfg.queueDepth = 4
        cfg.capturesAudio = false
        return (cfg, cap, scale)
    }

    private func reconfigure(recenter: Bool) {
        guard let s = stream, !updating else { return }
        let (cfg, rect, scale) = makeConfig()
        // Nothing to do when the stream already has exactly these settings. (This is also what guarantees the
        // "ask again after each update" below can never go round in circles.)
        if rect == cfgRect && abs(scale - cfgScale) < 0.001 && still == cfgStill { return }
        // Otherwise only bother the stream when the area the page needs is about to leave what is being captured,
        // when the widget has come to rest somewhere new, or when the capture rate should change.
        // At a screen edge the captured area cannot extend any further, so no slack is asked for on that side.
        var roomy = cfgRect.insetBy(dx: 12, dy: 12)
        if cfgRect.minX <= displayBounds.minX + 1 { roomy.size.width += roomy.minX - cfgRect.minX; roomy.origin.x = cfgRect.minX }
        if cfgRect.minY <= displayBounds.minY + 1 { roomy.size.height += roomy.minY - cfgRect.minY; roomy.origin.y = cfgRect.minY }
        if cfgRect.maxX >= displayBounds.maxX - 1 { roomy.size.width = cfgRect.maxX - roomy.minX }
        if cfgRect.maxY >= displayBounds.maxY - 1 { roomy.size.height = cfgRect.maxY - roomy.minY }
        let need = region.intersection(displayBounds)
        let covered = (need.isNull || roomy.contains(need)) && abs(scale - cfgScale) / cfgScale < 0.12
        if covered && !recenter && still == cfgStill { return }
        updating = true
        cfgRect = rect; cfgScale = scale; cfgStill = still
        os_unfair_lock_lock(&lock)
        gRects.append(rect); if gRects.count > 4 { gRects.removeFirst(gRects.count - 4) }
        os_unfair_lock_unlock(&lock)
        s.updateConfiguration(cfg) { [weak self] error in
            // a short pause before looking again keeps updates to a handful a second while the widget is dragged,
            // and a longer one if the system refused this update
            DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 0.05 : 1)) {
                guard let self else { return }
                self.updating = false
                if self.stream != nil { self.reconfigure(recenter: false) }
            }
        }
    }

    private func setStill(_ on: Bool) {
        guard on != still else { return }
        still = on
        reconfigure(recenter: false)
    }

    private func rerender() {
        os_unfair_lock_lock(&lock)
        let already = renderQueued
        renderQueued = true
        os_unfair_lock_unlock(&lock)
        if already { return }
        queue.async { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.lock); self.renderQueued = false; os_unfair_lock_unlock(&self.lock)
            self.render(newFrame: false)
        }
    }

    static func display(for r: CGRect) -> CGDirectDisplayID {
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        if CGGetDisplaysWithPoint(CGPoint(x: r.midX, y: r.minY + min(r.height, 60) / 2), 1, &id, &n) == .success, n > 0 { return id }
        if CGGetDisplaysWithRect(r, 1, &id, &n) == .success, n > 0 { return id }
        return CGMainDisplayID()
    }

    // MARK: - frames (capture queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st == .complete || st == .started,
              let pb = sampleBuffer.imageBuffer else { return }
        os_unfair_lock_lock(&lock)
        let asked = gRects, origin = gOrigin
        os_unfair_lock_unlock(&lock)
        guard var rect = asked.last else { return }
        // Each picture says which part of the screen it shows. While the widget is being dragged the capture rectangle
        // changes several times a second, so match the picture to one of the rectangles that were asked for.
        if let d = info[.screenRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d as CFDictionary), r.width > 1 {
            let local = r.offsetBy(dx: origin.x, dy: origin.y)
            func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5 && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5 }
            if let m = asked.last(where: { near($0, r) }) { rect = m }
            else if let m = asked.last(where: { near($0, local) }) { rect = m }
        }
        let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb)
        var content = CGRect(x: 0, y: 0, width: bw, height: bh)
        if let d = info[.contentRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d as CFDictionary), r.width > 1,
           let s = (info[.scaleFactor] as? NSNumber)?.doubleValue, s > 0 {
            content = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
        }
        lastBuffer = pb
        lastRect = rect
        lastContent = content
        framesSeen &+= 1
        #if DEBUG
        if framesSeen <= 2 {
            trace("frame \(framesSeen): \(bw)x\(bh) asked=\(asked) screenRect=\(String(describing: info[.screenRect])) contentRect=\(String(describing: info[.contentRect])) dirty=\(String(describing: info[.dirtyRects]))")
        }
        #endif
        render(newFrame: true)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.status = "stopped: \(error.localizedDescription)"
            if self.wanted { self.again(in: 2) }
        }
    }

    /// Cuts the area the page needs out of the last captured picture and averages it down to 768 x (166 per strip-height).
    private func render(newFrame: Bool) {
        guard let pb = lastBuffer else { return }
        os_unfair_lock_lock(&lock)
        let region = gRegion, rows = gRows
        os_unfair_lock_unlock(&lock)
        let cap = lastRect, content = lastContent
        guard region.width > 1, region.height > 1, cap.width > 1, cap.height > 1 else { return }
        let W = outW, H = max(2, Int((rowPx * rows).rounded()))

        // where the wanted area falls in the buffer (it may run off the captured part, or off the screen)
        let sx = content.width / cap.width, sy = content.height / cap.height
        let fx0 = content.minX + (region.minX - cap.minX) * sx, fx1 = content.minX + (region.maxX - cap.minX) * sx
        let fy0 = content.minY + (region.minY - cap.minY) * sy, fy1 = content.minY + (region.maxY - cap.minY) * sy
        let cx0 = max(content.minX, fx0), cx1 = min(content.maxX, fx1), cy0 = max(content.minY, fy0), cy1 = min(content.maxY, fy1)
        let has = cx1 - cx0 >= 1 && cy1 - cy0 >= 1
        var sx0 = 0, sy0 = 0, sw = 0, sh = 0, dx0 = 0, dy0 = 0, dw = 0, dh = 0
        var crop = [UInt8]()

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if has, let base = CVPixelBufferGetBaseAddress(pb) {
            let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
            sx0 = min(bw - 1, Int(cx0.rounded())); sy0 = min(bh - 1, Int(cy0.rounded()))
            sw = max(1, min(bw - sx0, Int((cx1 - cx0).rounded()))); sh = max(1, min(bh - sy0, Int((cy1 - cy0).rounded())))
            dx0 = max(0, min(W - 1, Int(((cx0 - fx0) / (fx1 - fx0) * CGFloat(W)).rounded())))
            dy0 = max(0, min(H - 1, Int(((cy0 - fy0) / (fy1 - fy0) * CGFloat(H)).rounded())))
            dw = max(1, min(W - dx0, Int(((cx1 - cx0) / (fx1 - fx0) * CGFloat(W)).rounded())))
            dh = max(1, min(H - dy0, Int(((cy1 - cy0) / (fy1 - fy0) * CGFloat(H)).rounded())))
            crop = [UInt8](repeating: 0, count: sw * sh * 4)
            crop.withUnsafeMutableBytes { p in
                for y in 0..<sh { memcpy(p.baseAddress! + y * sw * 4, base + (sy0 + y) * bpr + sx0 * 4, sw * 4) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        // Nothing new behind the glass? Then there is nothing to send. (The widget's own motion keeps the display "changing",
        // so the system delivers pictures even when what they show is identical.)
        let key = "\(sx0),\(sy0),\(sw),\(sh),\(dx0),\(dy0),\(dw),\(dh),\(W),\(H)"
        if key == prevKey, crop.count == prev.count, crop.withUnsafeBytes({ a in prev.withUnsafeBytes { b in memcmp(a.baseAddress, b.baseAddress, a.count) == 0 } }) {
            if newFrame {
                unchanged += 1
                if unchanged >= stillAfter, !toldStill {
                    toldStill = true
                    DispatchQueue.main.async { [weak self] in self?.setStill(true) }
                }
            }
            return
        }
        prevKey = key; prev = crop
        unchanged = 0
        if toldStill {
            toldStill = false
            DispatchQueue.main.async { [weak self] in self?.setStill(false) }
        }

        var out = [UInt8](repeating: 0, count: W * H * 4)
        out.withUnsafeMutableBytes { p in      // the preview's own fill for "nothing there": #0d0e13, here as BGRA
            var px: UInt32 = 0xFF0D0E13
            memset_pattern4(p.baseAddress!, &px, p.count)
        }
        if has {
            crop.withUnsafeMutableBytes { c in
                var src = vImage_Buffer(data: c.baseAddress!, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw * 4)
                out.withUnsafeMutableBytes { p in
                    var dst = vImage_Buffer(data: p.baseAddress! + dy0 * W * 4 + dx0 * 4, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: W * 4)
                    vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
        }
        out.withUnsafeMutableBytes { p in      // BGRA -> RGBA, fully opaque
            var buf = vImage_Buffer(data: p.baseAddress!, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 4)
            let map: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&buf, &buf, map, vImage_Flags(kvImageNoFlags))
            vImageOverwriteChannelsWithScalar_ARGB8888(255, &buf, &buf, 0x1, vImage_Flags(kvImageNoFlags))
        }
        store.set(Data(out), w: W, h: H, rows: rows)
        framesSent &+= 1
        DispatchQueue.main.async { [weak self] in self?.onFrame?() }
    }
}
