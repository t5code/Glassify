import AppKit

/// Reads what the Spotify desktop app is playing. No login and no developer account:
/// the title, artist and cover address come from Spotify's own AppleScript dictionary on this Mac,
/// and Spotify announces every play, pause and track change with a system-wide notification.
final class Spotify {
    enum State { case notRunning, unknown, playing, paused }

    var onState: ((State) -> Void)?
    /// title, artist, cover as a data: URL (nil when the track has none)
    var onTrack: ((String, String, String?) -> Void)?

    private static let bundleID = "com.spotify.client"
    private let work = DispatchQueue(label: "glassify.spotify")
    private var script: NSAppleScript?          // only touched on `work`
    private var automationRefused = false       // only touched on `work`
    private var trackKey: String? = nil
    private(set) var state = State.notRunning
    private var last: (title: String, artist: String, cover: String?)?
    private var coverTask: URLSessionDataTask?
    private var generation = 0

    private let source = """
    tell application id "com.spotify.client"
        set playerNow to player state as string
        try
            set theTrack to current track
            return {playerNow, name of theTrack, artist of theTrack, artwork url of theTrack, id of theTrack}
        on error
            return {playerNow}
        end try
    end tell
    """

    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains { !$0.isTerminated }
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.refresh(announced: n.userInfo)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh(announced: nil) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            self?.gone()
        }
        refresh(announced: nil)
    }

    /// Sends the current state and track again (used when the page has just loaded).
    func resend() {
        onState?(state)
        if let l = last { onTrack?(l.title, l.artist, l.cover) }
    }

    private func gone() {
        generation += 1
        coverTask?.cancel()
        trackKey = nil; last = nil
        publish(.notRunning)
        onTrack?("", "", nil)
    }

    private func publish(_ s: State) {
        state = s
        onState?(s)
    }

    private func refresh(announced info: [AnyHashable: Any]?) {
        let said = (info?["Player State"] as? String)?.lowercased()
        // Spotify says "stopped" on its way out; asking it anything at that point would launch it again.
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
                    self.publish(a.state == "playing" ? .playing : .paused)
                    self.setTrack(id: a.id, title: a.title, artist: a.artist, coverURL: a.cover, lookup: false)
                } else if let said {
                    // Automation was refused: fall back to what the announcement itself carries.
                    self.publish(said == "playing" ? .playing : .paused)
                    let id = info?["Track ID"] as? String ?? ""
                    self.setTrack(id: id, title: info?["Name"] as? String ?? "", artist: info?["Artist"] as? String ?? "", coverURL: "", lookup: true)
                } else {
                    self.publish(.unknown)
                }
            }
        }
    }

    private struct Answer { var state = "", title = "", artist = "", cover = "", id = "" }

    /// Runs on `work`. Returns nil when Spotify could not be asked (not allowed, or it went away).
    private func ask() -> Answer? {
        guard isRunning else { return nil }
        if script == nil {
            script = NSAppleScript(source: source)
            var err: NSDictionary?
            if script?.compileAndReturnError(&err) != true { trace("script did not compile: \(String(describing: err))"); script = nil; return nil }
        }
        var err: NSDictionary?
        guard let d = script?.executeAndReturnError(&err), err == nil else {
            let code = err?[NSAppleScript.errorNumber] as? Int ?? 0
            trace("asking Spotify failed: \(code) \(err?[NSAppleScript.errorMessage] ?? "")")
            if code == -1743, !automationRefused {   // errAEEventNotPermitted
                automationRefused = true
                note("not allowed to ask Spotify for the track; using its announcements instead")
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
            a.cover = d.atIndex(4)?.stringValue ?? ""
            a.id = d.atIndex(5)?.stringValue ?? ""
        }
        return a
    }

    private func setTrack(id: String, title: String, artist: String, coverURL: String, lookup: Bool) {
        let key = id + "\u{1f}" + title + "\u{1f}" + artist
        guard key != trackKey else { return }
        trackKey = key
        coverTask?.cancel()
        let finish: (String?) -> Void = { [weak self] cover in
            DispatchQueue.main.async {
                guard let self, self.trackKey == key else { return }
                self.last = (title, artist, cover)
                self.onTrack?(title, artist, cover)
            }
        }
        if let u = URL(string: coverURL), u.scheme == "https" || u.scheme == "http" {
            fetchImage(u, then: finish)
        } else if lookup, id.hasPrefix("spotify:track:"),
                  var c = URLComponents(string: "https://open.spotify.com/oembed") {
            // Without Automation there is no cover address; Spotify's public embed info has one and needs no account.
            c.queryItems = [URLQueryItem(name: "url", value: id)]
            guard let u = c.url else { finish(nil); return }
            var req = URLRequest(url: u); req.timeoutInterval = 6
            coverTask = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let s = j["thumbnail_url"] as? String, let img = URL(string: s) else { finish(nil); return }
                self?.fetchImage(img, then: finish)
            }
            coverTask?.resume()
        } else {
            finish(nil)
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
}
