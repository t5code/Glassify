import AppKit

/// What softens the desktop showing through the slightly see-through glass (Drift and Vinyl let about 16% through).
/// In preview.html this is `backdrop-filter: blur(22px) saturate(1.5)`; a web page cannot blur the desktop, so the window does it.
enum Backdrop {
    /// The system's own material: always available, close to the design but a little darker and less saturated.
    static func system(material: NSVisualEffectView.Material = .hudWindow) -> NSVisualEffectView {
        let v = NSVisualEffectView(frame: .zero)
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.layer?.cornerCurve = .circular
        return v
    }

    /// The same Core Animation backdrop the system material is built on, with exactly the design's two filters and no tint.
    /// Returns nil if this macOS does not offer it, in which case the system material is used.
    static func exact() -> NSView? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: make) else { return nil }
        func filter(_ type: String) -> NSObject? { filterClass.perform(make, with: type)?.takeUnretainedValue() as? NSObject }
        guard let blur = filter("gaussianBlur"), let sat = filter("colorSaturate") else { return nil }
        blur.setValue(22, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        sat.setValue(1.5, forKey: "inputAmount")
        let layer = layerClass.init()
        guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")) else { return nil }
        layer.setValue(true, forKey: "windowServerAware")
        layer.filters = [blur, sat]
        layer.masksToBounds = true
        layer.cornerCurve = .circular
        let v = NSView(frame: .zero)
        v.layer = layer
        v.wantsLayer = true
        return v
    }
}
