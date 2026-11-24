import CoreAudio
import Foundation

/// Listens to the sound the music apps themselves produce (Spotify and Apple Music), using a Core Audio process tap
/// (macOS 14.2+). The tap sits on their output before it reaches any device, so speakers, wired or Bluetooth headphones
/// all behave the same, and nothing else playing on the Mac is heard.
/// Flow, as Apple documents it: CATapDescription -> AudioHardwareCreateProcessTap -> a private aggregate device
/// whose tap list holds the tap -> an IO proc on that device.
final class SpotifyTap {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private var tapped: [AudioObjectID] = []
    private var wanted = false
    private var stopLater: DispatchWorkItem?
    private var listening = false
    /// Everything that builds or removes the tap runs here, off the main thread: the very first start waits for the
    /// person to answer the permission prompt, and the widget must stay responsive meanwhile.
    private let ctl = DispatchQueue(label: "glassify.tap.control")

    private var lock = os_unfair_lock()
    private var ring = [Float](repeating: 0, count: 8192)
    private var head = 0
    private var lastWrite = 0.0
    private var tapChannels = 2
    private var failedFor: [AudioObjectID] = []
    private var clockDevice: String?
    private var watchingOutput = false
    private var isFloat = true
    private(set) var sampleRate = 48000.0
    private(set) var callbacks = 0
    private(set) var peak: Float = 0

    var isBuilt: Bool { aggID != kAudioObjectUnknown }
    var isRunning: Bool { running }

    /// `on` = Spotify is (or may be) playing.
    func setWanted(_ on: Bool) {
        ctl.async { [self] in
            wanted = on
            stopLater?.cancel(); stopLater = nil
            if on {
                failedFor = []
                watchProcessList()
                sync()
            } else {
                // pauses are often short: keep the tap alive for a moment, then stop listening altogether
                let w = DispatchWorkItem { [weak self] in self?.sync() }
                stopLater = w
                ctl.asyncAfter(deadline: .now() + 4, execute: w)
            }
        }
    }

    func shutdown() {
        ctl.sync {
            wanted = false
            teardown()
        }
    }

    /// The most recent `count` mono samples, oldest first. False when no fresh audio has arrived lately.
    func latest(into out: inout [Float], count: Int) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard running, CFAbsoluteTimeGetCurrent() - lastWrite < 0.25 else { return false }
        let n = ring.count
        var i = (head - count + n * 2) % n
        for k in 0..<count { out[k] = ring[i]; i += 1; if i == n { i = 0 } }
        return true
    }

    // MARK: - lifecycle

    private func sync() {
        let procs = wanted ? Self.spotifyProcessObjects() : []
        if procs != tapped || (!wanted && isBuilt) {
            teardown()
        }
        guard wanted, !procs.isEmpty, !isBuilt else { return }
        if procs == failedFor { return }            // already tried this Spotify process; wait for something to change
        // First the plain form (the tap alone drives the device). If the audio server will not run that,
        // borrow the clock of the current output device.
        if !build(procs, clockFromOutput: false) && !build(procs, clockFromOutput: true) {
            failedFor = procs
            note("could not listen to the music app's sound")
        }
    }

    private func build(_ procs: [AudioObjectID], clockFromOutput: Bool) -> Bool {
        let desc = CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID()
        desc.name = "Glassify"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { trace("create tap failed \(err)"); return false }
        tapID = tap

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 {
            sampleRate = fmt.mSampleRate
            isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 && fmt.mBitsPerChannel == 32
            tapChannels = Int(max(1, fmt.mChannelsPerFrame))
        }

        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Glassify",
            kAudioAggregateDeviceUIDKey: "glassify-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        if clockFromOutput {
            guard let out = Self.defaultOutputUID() else { teardown(); return false }
            agg[kAudioAggregateDeviceMainSubDeviceKey] = out
            // output side only: none of that device's inputs (a headset microphone, say) are opened
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: out, kAudioSubDeviceInputChannelsKey: 0]]
            clockDevice = out
            watchOutputDevice()
        } else {
            clockDevice = nil
        }
        var dev = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev)
        guard err == noErr, dev != kAudioObjectUnknown else { trace("create aggregate failed \(err)"); teardown(); return false }
        aggID = dev

        // no queue: the block runs directly on the audio thread (it only copies samples), which avoids ~100 thread hand-offs a second
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProc, dev, nil) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard err == noErr, let proc = ioProc else { trace("create io proc failed \(err)"); teardown(); return false }
        err = AudioDeviceStart(dev, proc)   // the first start is what makes macOS ask for audio capture permission
        guard err == noErr else { trace("start failed \(err) clockFromOutput=\(clockFromOutput)"); teardown(); return false }
        os_unfair_lock_lock(&lock); running = true; os_unfair_lock_unlock(&lock)
        tapped = procs
        note("listening to the music app's sound (\(Int(sampleRate)) Hz, \(tapChannels) ch\(clockFromOutput ? ", output clock" : ""))")
        return true
    }

    private func teardown() {
        if aggID != kAudioObjectUnknown {
            if let p = ioProc {
                AudioDeviceStop(aggID, p)
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapped = []
        clockDevice = nil
        os_unfair_lock_lock(&lock)
        running = false
        for i in 0..<ring.count { ring[i] = 0 }
        lastWrite = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Spotify only shows up as an audio process once it has opened its output, and gets a new object each launch.
    private func watchProcessList() {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(Self.system, &addr, ctl) { [weak self] _, _ in
            guard let self, self.wanted else { return }
            self.sync()
        }
    }

    /// Only matters when the device borrows the output's clock: follow the output when it changes (headphones on or off).
    private func watchOutputDevice() {
        guard !watchingOutput else { return }
        watchingOutput = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(Self.system, &addr, ctl) { [weak self] _, _ in
            guard let self, self.wanted, let clock = self.clockDevice, clock != Self.defaultOutputUID() else { return }
            self.teardown()
            self.failedFor = []
            self.sync()
        }
    }

    static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &dev) == noErr, dev != kAudioObjectUnknown else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    // MARK: - audio thread

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard isFloat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // The tap's stream comes last (after any streams of a borrowed clock device).
        guard let lastBuf = abl.last, let d0 = lastBuf.mData else { return }
        let a = d0.assumingMemoryBound(to: Float.self)
        var pk: Float = 0
        os_unfair_lock_lock(&lock)
        let n = ring.count
        if lastBuf.mNumberChannels == 1, tapChannels == 2, abl.count >= 2, abl[abl.count - 2].mNumberChannels == 1, let d1 = abl[abl.count - 2].mData {
            // two separate mono buffers (left, right)
            let b = d1.assumingMemoryBound(to: Float.self)
            let frames = Int(min(lastBuf.mDataByteSize, abl[abl.count - 2].mDataByteSize)) / 4
            for i in 0..<frames {
                let v = (a[i] + b[i]) * 0.5
                ring[head] = v; head += 1; if head == n { head = 0 }
                pk = max(pk, abs(v))
            }
        } else {
            let ch = max(1, Int(lastBuf.mNumberChannels))
            let frames = Int(lastBuf.mDataByteSize) / 4 / ch
            for i in 0..<frames {
                var v: Float = 0
                for c in 0..<ch { v += a[i * ch + c] }
                v /= Float(ch)
                ring[head] = v; head += 1; if head == n { head = 0 }
                pk = max(pk, abs(v))
            }
        }
        lastWrite = CFAbsoluteTimeGetCurrent()
        callbacks &+= 1
        peak = max(pk, peak * 0.95)
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - finding the music apps

    /// Is the app with this bundle id sending sound to an output right now? nil when the audio system does not know the app.
    static func isOutputRunning(bundleID: String) -> Bool? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var all = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &all) == noErr else { return nil }
        var known = false
        for obj in all {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(obj, &a, 0, nil, &n, &s) == noErr, let id = s?.takeRetainedValue() as String?, id == bundleID || id.hasPrefix(bundleID + ".") else { continue }
            known = true
            a.mSelector = kAudioProcessPropertyIsRunningOutput
            var running: UInt32 = 0
            n = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(obj, &a, 0, nil, &n, &running) == noErr, running != 0 { return true }
        }
        return known ? false : nil
    }


    static func spotifyProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var all = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &all) == noErr else { return [] }
        return all.filter { obj in
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(obj, &a, 0, nil, &n, &s) == noErr, let id = s?.takeRetainedValue() as String? else { return false }
            return id == "com.spotify.client" || id.hasPrefix("com.spotify.client.") || id == "com.apple.Music" || id.hasPrefix("com.apple.Music.")
        }.sorted()
    }
}
