import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reads what is playing in the Spotify or Apple Music desktop app. No login and no developer account:
/// title, artist and cover come from each app's own AppleScript dictionary on this Mac, and both apps announce
/// every play, pause and track change with a system-wide notification. Whichever app is playing is the one shown.
final class NowPlaying {
    enum State { case notRunning, unknown, playing, paused }

    var onState: ((State) -> Void)?
    /// title, artist, cover as a data: URL (nil when the track has none)
    var onTrack: ((String, String, String?) -> Void)?

    private let spotify = Player(.spotify)
    private let music = Player(.music)
    private(set) var state = State.notRunning
    private var shown: Player?
    private var shownKey = ""
    private(set) var last: (title: String, artist: String, cover: String?)?

    func start() {
        for p in [spotify, music] {
            p.onChange = { [weak self] in self?.changed() }
            p.start()
        }
    }

    /// Sends the current state and track again (used when the page has just loaded).
    func resend() {
        onState?(state)
        if let l = last { onTrack?(l.title, l.artist, l.cover) }
    }

    private func recompute() {
        let all = [spotify, music]
        // An app that says it is playing wins, the most recently started first. Music sometimes says "playing" while silent,
        // so when the audio system can tell, only apps that are really sending sound count.
        let saying = all.filter { $0.state == .playing }
        let sounding = saying.filter { SpotifyTap.isOutputRunning(bundleID: $0.app.bundleID) == true }
        let active = (sounding.isEmpty ? saying : sounding).max { $0.since < $1.since }
            ?? all.first { $0.state == .unknown }                                      // open, but may not be asked: the sound decides
            ?? all.filter { $0.state == .paused && $0.track != nil }.max { $0.changed < $1.changed }
        let s: State = active?.state ?? (all.contains { $0.state == .paused } ? .paused : .notRunning)
        if s != state { state = s; onState?(s) }
        let t = active?.track
        let key = t.map { "\(active!.app.bundleID)\u{1f}\($0.title)\u{1f}\($0.artist)\u{1f}\($0.cover?.count ?? -1)" } ?? ""
        if active !== shown {
            note("following \(active?.app.bundleID ?? "nothing") (" + all.map { "\($0.app.bundleID): \($0.state)\(SpotifyTap.isOutputRunning(bundleID: $0.app.bundleID) == true ? ", sounding" : "")" }.joined(separator: "; ") + ")")
        }
        guard key != shownKey || active !== shown else { return }
        shownKey = key; shown = active
        last = t
        onTrack?(t?.title ?? "", t?.artist ?? "", t?.cover)
    }

    /// The apps' own word and the audio system can disagree for a moment around play and pause; look again shortly after.
    private var recheck: DispatchWorkItem?
    fileprivate func changed() {
        recompute()
        recheck?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.recompute() }
        recheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

/// One music app.
final class Player {
    struct App {
        let bundleID: String
        let announcement: String      // the notification the app posts on every change
        let script: String
        let coverIsData: Bool         // Music hands over the picture itself; Spotify an address to fetch it from

        static let spotify = App(bundleID: "com.spotify.client", announcement: "com.spotify.client.PlaybackStateChanged", script: """
            tell application id "com.spotify.client"
                set playerNow to player state as string
                try
                    set theTrack to current track
                    return {playerNow, name of theTrack, artist of theTrack, id of theTrack, artwork url of theTrack}
                on error
                    return {playerNow}
                end try
            end tell
            """, coverIsData: false)

        static let music = App(bundleID: "com.apple.Music", announcement: "com.apple.Music.playerInfo", script: """
            tell application id "com.apple.Music"
                set playerNow to player state as string
                try
                    set theTrack to current track
                    set theCover to ""
                    try
                        set theCover to raw data of artwork 1 of theTrack
                    end try
                    return {playerNow, name of theTrack, artist of theTrack, (database ID of theTrack) as string, theCover}
                on error
                    return {playerNow}
                end try
            end tell
            """, coverIsData: true)
    }

    let app: App
    var onChange: (() -> Void)?
    private(set) var state = NowPlaying.State.notRunning
    private(set) var track: (title: String, artist: String, cover: String?)?
    /// When this app last started playing (or was last heard from).
    private(set) var since = Date.distantPast
    /// When it was last heard from at all.
    private(set) var changed = Date.distantPast

    /// AppleScript must not run on two threads at once, so both apps are asked on this one queue, one after the other.
    private static let work = DispatchQueue(label: "glassify.players")
    private var work: DispatchQueue { Self.work }
    private var script: NSAppleScript?          // only touched on `work`
    private var automationRefused = false       // only touched on `work`
    private var lastError = 0                   // only touched on `work`
    private var retries = 0
    private var trackKey: String?
    private var coverTask: URLSessionDataTask?
    private var generation = 0

    init(_ app: App) {
        self.app = app
    }

    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains { !$0.isTerminated }
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(app.announcement), object: nil, queue: .main) { [weak self] n in
            self?.refresh(announced: n.userInfo)
        }
        let ws = NSWorkspace.shared.notificationCenter
        let id = app.bundleID
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh(announced: nil) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == id else { return }
            self?.gone()
        }
        refresh(announced: nil)
    }

    private func gone() {
        generation += 1
        coverTask?.cancel()
        trackKey = nil; track = nil
        publish(.notRunning)
    }

    private func publish(_ s: NowPlaying.State) {
        if s == .playing && state != .playing { since = Date() }
        changed = Date()
        state = s
        onChange?()
    }

    private func refresh(announced info: [AnyHashable: Any]?) {
        let said = (info?["Player State"] as? String)?.lowercased()
        // The app says "stopped" on its way out; asking it anything at that point would launch it again.
        if said == "stopped" { publish(isRunning ? .paused : .notRunning); return }
        guard isRunning else { gone(); return }
        generation += 1
        let gen = generation
        work.async { [weak self] in
            guard let self else { return }
            let answer = self.ask()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if let a = answer {
                    self.retries = 0
                    self.setTrack(id: a.id, title: a.title, artist: a.artist, coverURL: a.coverURL, coverData: a.coverData, lookup: false)
                    self.publish(a.state == "playing" ? .playing : .paused)
                } else if let said {
                    // Automation was refused: fall back to what the announcement itself carries.
                    let id = (info?["Track ID"] as? String) ?? (info?["PersistentID"]).map { "\($0)" } ?? ""
                    self.setTrack(id: id, title: info?["Name"] as? String ?? "", artist: info?["Artist"] as? String ?? "", coverURL: "", coverData: nil, lookup: true)
                    self.publish(said == "playing" ? .playing : .paused)
                } else {
                    self.publish(.unknown)
                    // could not be asked just now (still starting up, or a permission prompt is open): try again a few times
                    if self.retries < 6 {
                        self.retries += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self, self.state == .unknown else { return }
                            self.refresh(announced: nil)
                        }
                    }
                }
            }
        }
    }

    private struct Answer { var state = "", title = "", artist = "", id = "", coverURL = ""; var coverData: Data? }

    /// Runs on `work`. Returns nil when the app could not be asked (not allowed, or it went away).
    private func ask() -> Answer? {
        guard isRunning else { return nil }
        if script == nil {
            script = NSAppleScript(source: app.script)
            var err: NSDictionary?
            if script?.compileAndReturnError(&err) != true { note("the script for \(app.bundleID) did not compile (\(err?[NSAppleScript.errorNumber] ?? "?"))"); script = nil; return nil }
        }
        var err: NSDictionary?
        guard let d = script?.executeAndReturnError(&err), err == nil else {
            let code = err?[NSAppleScript.errorNumber] as? Int ?? 0
            if code != lastError { lastError = code; note("asking \(app.bundleID) failed with error \(code)") }
            if code == -1743, !automationRefused {   // errAEEventNotPermitted
                automationRefused = true
                note("not allowed to ask \(app.bundleID) for the track; using its announcements instead")
            }
            return nil
        }
        var a = Answer()
        let n = d.numberOfItems
        guard n >= 1 else { return nil }
        a.state = d.atIndex(1)?.stringValue ?? ""
        if n >= 5 {
            a.title = d.atIndex(2)?.stringValue ?? ""
            a.artist = d.atIndex(3)?.stringValue ?? ""
            a.id = d.atIndex(4)?.stringValue ?? ""
            if app.coverIsData {
                if let raw = d.atIndex(5)?.data, raw.count > 64 { a.coverData = raw }
            } else {
                a.coverURL = d.atIndex(5)?.stringValue ?? ""
            }
        }
        return a
    }

    private func setTrack(id: String, title: String, artist: String, coverURL: String, coverData: Data?, lookup: Bool) {
        let key = id + "\u{1f}" + title + "\u{1f}" + artist
        guard key != trackKey else { return }
        trackKey = key
        coverTask?.cancel()
        let finish: (String?) -> Void = { [weak self] cover in
            DispatchQueue.main.async {
                guard let self, self.trackKey == key else { return }
                self.track = (title, artist, cover)
                self.onChange?()
            }
        }
        if let coverData {
            let small = Self.shrink(coverData)
            track = (title, artist, small)
        } else if let u = URL(string: coverURL), u.scheme == "https" || u.scheme == "http" {
            // keep showing the previous cover until the new one has arrived
            fetchImage(u, then: finish)
        } else if lookup, id.hasPrefix("spotify:track:"), var c = URLComponents(string: "https://open.spotify.com/oembed") {
            // Without Automation there is no cover address; Spotify's public embed info has one and needs no account.
            c.queryItems = [URLQueryItem(name: "url", value: id)]
            guard let u = c.url else { track = (title, artist, nil); return }
            var req = URLRequest(url: u); req.timeoutInterval = 6
            coverTask = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let s = j["thumbnail_url"] as? String, let img = URL(string: s) else { finish(nil); return }
                self?.fetchImage(img, then: finish)
            }
            coverTask?.resume()
        } else {
            track = (title, artist, nil)
        }
    }

    private func fetchImage(_ url: URL, then finish: @escaping (String?) -> Void) {
        var req = URLRequest(url: url); req.timeoutInterval = 6
        let t = URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, data.count > 64, data.count < 8_000_000 else { finish(nil); return }
            let mime = (resp as? HTTPURLResponse)?.mimeType ?? "image/jpeg"
            finish("data:\(mime.hasPrefix("image/") ? mime : "image/jpeg");base64," + data.base64EncodedString())
        }
        coverTask = t
        t.resume()
    }

    /// Music's covers can be several megabytes; the page only needs a small square.
    private static func shrink(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (out as Data).base64EncodedString()
    }
}
