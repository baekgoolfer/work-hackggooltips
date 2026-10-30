import Foundation
import CoreAudio

// =====================================================================================
// Permission-free audio signals for meeting detection (SPEC 5 + 13.1, docs/DETECTION.md).
//
//   AudioProcessMonitor   Core Audio process objects (kAudioHardwarePropertyProcessObjectList).
//                         PID + BundleID are cached per AudioObjectID, the (slow) IsRunningInput /
//                         IsRunningOutput flags are only read for processes that belong to a family.
//                         Steady state ~4-5 ms per poll on this Mac, ~50 ms if everything is read.
//   FamilyMatcher         bundle id -> platform family (Meet = browser, Zoom, Teams). Our own app is excluded.
//   FamilyAudio           the family's processes plus the aggregated raw in/out flags.
//   HysteresisFlag        in/out smoothing: a flag must be on for a while to turn on, and off for a while to
//                         turn off (bridges one missed poll).
//
// Facts this relies on (all verified on the reference Mac, see docs/DETECTION.md):
//   - reading these properties needs no TCC permission;
//   - the IsRunningInput/Output property listeners never fire, so we poll;
//   - IsRunningOutput means "an output stream is open", not "sound is audible" (silence counts as running).
// =====================================================================================

// MARK: - Core Audio process objects

struct AudioProcessInfo: Codable, Equatable {
    var objectID: UInt32
    var pid: Int32
    var bundleID: String
    var isRunningInput: Bool
    var isRunningOutput: Bool
}

final class AudioProcessMonitor {
    private struct Identity {
        let pid: pid_t
        let bundleID: String
    }

    /// Test seam: stands in for the three Core Audio reads (self test only; production uses the live calls).
    struct Source {
        var list: () -> [AudioObjectID]?
        var identity: (AudioObjectID) -> (pid: pid_t, bundleID: String)?
        var flags: (AudioObjectID) -> (input: Bool, output: Bool)
    }

    private let source: Source?

    init(source: Source? = nil) {
        self.source = source
    }

    /// PID and bundle id never change during the life of a process object.
    private var cache: [AudioObjectID: Identity] = [:]
    /// Number of process objects in the last enumeration (59 on an idle Mac); for the probe.
    private(set) var totalObjects = 0
    /// Non-nil when the last enumeration failed (logged by the caller when it changes).
    private(set) var lastError: String?

    /// Reads IsRunning* only for processes whose bundle id passes `interesting`.
    func poll(interesting: (String) -> Bool) -> [AudioProcessInfo] {
        return read(interesting)
    }

    /// The read of the call rule (docs/DETECTION.md section 3b): both flags of the processes that pass `interesting` (the known call apps, the
    /// apps already being watched, the browser while tab addresses are read), and with `scanOthers` every other process that has the MICROPHONE
    /// running, with its output flag read only for those (the generic rule needs both, and almost no process holds the microphone, so this is one
    /// property read per process object instead of two).
    func pollCalls(interesting: (String) -> Bool, scanOthers: Bool) -> [AudioProcessInfo] {
        return read(interesting, scanOthers: scanOthers)
    }

    /// Reads the flags of every process object (probe only: ~50 ms).
    func pollAll() -> [AudioProcessInfo] {
        return read { _ in true }
    }

    private func read(_ interesting: (String) -> Bool, scanOthers: Bool = false) -> [AudioProcessInfo] {
        guard let ids = objectList() else {
            // The list call failed (coreaudiod restarting?). Object ids may be reused for other processes afterwards, so
            // nothing cached under the old ids can be trusted.
            cache.removeAll()
            return []
        }
        totalObjects = ids.count
        let live = Set(ids)
        cache = cache.filter { live.contains($0.key) }          // object ids can be recycled: forget the dead ones
        var result: [AudioProcessInfo] = []
        for id in ids {
            if cache[id] == nil, let identity = lookupIdentity(id) { cache[id] = identity }
            guard let identity = cache[id] else { continue }
            if interesting(identity.bundleID) {
                let io = source?.flags(id) ?? (input: (readUInt32(id, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                                               output: (readUInt32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
                result.append(AudioProcessInfo(objectID: id, pid: identity.pid, bundleID: identity.bundleID,
                                               isRunningInput: io.input, isRunningOutput: io.output))
            } else if scanOthers, !identity.bundleID.isEmpty {
                // A process that does not hold the microphone cannot be a call of the generic rule: its output flag is never read.
                if let s = source {
                    let io = s.flags(id)
                    guard io.input else { continue }
                    result.append(AudioProcessInfo(objectID: id, pid: identity.pid, bundleID: identity.bundleID, isRunningInput: true, isRunningOutput: io.output))
                } else if (readUInt32(id, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
                    let output = (readUInt32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
                    result.append(AudioProcessInfo(objectID: id, pid: identity.pid, bundleID: identity.bundleID, isRunningInput: true, isRunningOutput: output))
                }
            }
        }
        return result
    }

    private func objectList() -> [AudioObjectID]? {
        if let s = source {
            let ids = s.list()
            lastError = ids == nil ? "scripted list failure" : nil
            return ids
        }
        return processObjectList()
    }

    private func lookupIdentity(_ object: AudioObjectID) -> Identity? {
        if let s = source { return s.identity(object).map { Identity(pid: $0.pid, bundleID: $0.bundleID) } }
        return readIdentity(object)
    }

    private func processObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            lastError = "process object list size: OSStatus \(sizeStatus)"
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            lastError = nil
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: count)
        var filled = size
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(system, &address, 0, nil, &filled, raw.baseAddress!)
        }
        guard status == noErr else {
            lastError = "process object list: OSStatus \(status)"
            return nil
        }
        lastError = nil
        return Array(ids.prefix(Int(filled) / MemoryLayout<AudioObjectID>.size))
    }

    private func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func readIdentity(_ object: AudioObjectID) -> Identity? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return nil }
        address.mSelector = kAudioProcessPropertyBundleID
        var cf: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        let bundle = status == noErr ? ((cf?.takeRetainedValue() as String?) ?? "") : ""
        return Identity(pid: pid, bundleID: bundle)
    }
}

// MARK: - Is the microphone in use at all?

/// "Is any audio INPUT device running somewhere?" (kAudioDevicePropertyDeviceIsRunningSomewhere of every device that has an input stream): one cheap read
/// per input device, no process object involved. The generic call rule needs a process that holds the microphone, and almost all the time nobody does, so
/// `AudioProcessMonitor.pollCalls(scanOthers:)` (one property read per process object, ~30 ms on a Mac with 60 of them) only runs while this says yes.
/// The device list is read again every 30 s (a Bluetooth headset that connects mid-call is found at the next refresh; the apps being tracked are read
/// regardless). Needs no permission. Not thread-safe by itself: the detector calls it under its own lock.
final class InputActivityGate {
    private var inputDevices: [AudioObjectID] = []
    private var refreshedAt: Date?
    private let refreshSeconds: TimeInterval

    init(refreshSeconds: TimeInterval = 30) { self.refreshSeconds = refreshSeconds }

    /// The number of input devices of the last refresh (diagnostics, tests).
    var inputDeviceCount: Int { inputDevices.count }

    func anyInputRunning(now: Date = Date()) -> Bool {
        if refreshedAt == nil || now.timeIntervalSince(refreshedAt ?? now) >= refreshSeconds || now < (refreshedAt ?? now) {
            inputDevices = Self.inputDeviceIDs()
            refreshedAt = now
        }
        for device in inputDevices where Self.isRunningSomewhere(device) { return true }
        return false
    }

    private static func inputDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, Int(size) >= MemoryLayout<AudioObjectID>.size else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        var filled = size
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in AudioObjectGetPropertyData(system, &address, 0, nil, &filled, raw.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.prefix(Int(filled) / MemoryLayout<AudioObjectID>.size).filter { hasInputStreams($0) }
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }
}

// MARK: - Families

/// Maps a Core Audio bundle id to the platform whose call it can carry.
///   Meet  : any bundle with a BROWSER_BUNDLE_IDS prefix (Chrome main + `.helper*`; the audio service lives in a helper)
///   Zoom  : us.zoom.xos (+ `.` children) and us.zoom.caphost
///   Teams : com.microsoft.teams* (new Teams `teams2` and classic)
/// Everything else (dictation, voice memos, Slack, our own app) is ignored by THIS matcher; the calls of other apps (Slack huddles, Webex, any
/// GUI app that holds the microphone and plays sound) are the job of `CallTracker` (CallApps.swift), which reads the same Core Audio process
/// objects through `AudioProcessMonitor.pollCalls`. Only enabled platforms match.
struct FamilyMatcher {
    /// Our own app and its helpers (the bundle id of the running app, lower case: ids are compared in lower case).
    static let ownBundlePrefix = AppInfo.bundleID.lowercased()
    /// Our own app or one of its children (`<id>.helper`), matched at a dot: another app whose id only starts with the same characters is not ours
    /// (an id of `com.goo` must not hide `com.google.Chrome`).
    static func isOwn(_ lowerBundle: String) -> Bool {
        return lowerBundle == ownBundlePrefix || lowerBundle.hasPrefix(ownBundlePrefix + ".")
    }
    static let zoomMainBundleID = "us.zoom.xos"
    static let zoomCaphostBundleID = "us.zoom.caphost"
    static let teamsPrefix = "com.microsoft.teams"
    static let teamsMainBundleID = "com.microsoft.teams2"

    let browserPrefixes: [String]
    let platforms: Set<Platform>

    init(browserBundleIDs: [String], enabledPlatforms: [Platform]) {
        self.browserPrefixes = browserBundleIDs.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.platforms = Set(enabledPlatforms)
    }

    func platform(of bundleID: String) -> Platform? {
        let b = bundleID.lowercased()
        guard !b.isEmpty, !Self.isOwn(b) else { return nil }
        if platforms.contains(.meet), browserPrefixes.contains(where: { b.hasPrefix($0) }) { return .meet }
        if platforms.contains(.zoom),
           b == Self.zoomMainBundleID || b.hasPrefix(Self.zoomMainBundleID + ".") || b == Self.zoomCaphostBundleID { return .zoom }
        if platforms.contains(.teams), b.hasPrefix(Self.teamsPrefix) { return .teams }
        return nil
    }

    func isInteresting(_ bundleID: String) -> Bool { platform(of: bundleID) != nil }

    func group(_ processes: [AudioProcessInfo]) -> [Platform: FamilyAudio] {
        var out: [Platform: FamilyAudio] = [:]
        for p in processes {
            guard let platform = platform(of: p.bundleID) else { continue }
            out[platform, default: FamilyAudio(platform: platform)].processes.append(p)
        }
        return out
    }
}

/// All of one family's Core Audio processes. `raw*` = any process of the family has the flag right now.
struct FamilyAudio: Equatable {
    var platform: Platform
    var processes: [AudioProcessInfo] = []

    var rawInput: Bool { processes.contains { $0.isRunningInput } }
    var rawOutput: Bool { processes.contains { $0.isRunningOutput } }
    var pids: [Int32] { processes.map { $0.pid }.sorted() }

    /// "4214:in+out,4215:in" for the processes that currently run IO (evidence strings).
    var ioSummary: String {
        let parts = processes.sorted { $0.pid < $1.pid }.compactMap { p -> String? in
            guard p.isRunningInput || p.isRunningOutput else { return nil }
            return "\(p.pid):" + [p.isRunningInput ? "in" : nil, p.isRunningOutput ? "out" : nil].compactMap { $0 }.joined(separator: "+")
        }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    func pids(ofBundle bundleID: String) -> [Int32] {
        let b = bundleID.lowercased()
        return processes.filter { $0.bundleID.lowercased() == b }.map { $0.pid }.sorted()
    }
}

// MARK: - Smoothing

/// A boolean that turns on only after the raw value has been true for `rise` seconds and turns off only after it has
/// been false for `fall` seconds. Time based (not poll-count based) so it behaves the same at 1 s (probe --watch) and
/// 2 s (app) polling and works with a virtual clock. At 2 s polling: rise 1.5 = 2 polls, rise 7 = 5 polls.
struct HysteresisFlag {
    let rise: TimeInterval
    let fall: TimeInterval
    private(set) var value = false
    private var risingSince: Date?
    private var lastTrue: Date?

    init(rise: TimeInterval, fall: TimeInterval) {
        self.rise = rise
        self.fall = fall
    }

    @discardableResult
    mutating func update(raw: Bool, now: Date) -> Bool {
        // A wall clock that moved backwards re-anchors the timers instead of freezing them.
        if let last = lastTrue, last > now { lastTrue = now }
        if let since = risingSince, since > now { risingSince = now }
        if raw {
            lastTrue = now
            if risingSince == nil { risingSince = now }
            if !value, let since = risingSince, now.timeIntervalSince(since) >= rise { value = true }
        } else {
            risingSince = nil                       // the "continuously on" run is broken
            if value, let last = lastTrue, now.timeIntervalSince(last) >= fall {
                value = false
                lastTrue = nil
            }
        }
        return value
    }
}

// MARK: - Audio devices (probe only: L-06 wants "Microsoft Teams Audio" IsRunningSomewhere)

struct AudioDeviceInfo: Codable, Equatable {
    var id: UInt32
    var name: String
    var uid: String
    var runningSomewhere: Bool
}

enum AudioDeviceList {
    static func all() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioObjectID>.size else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        var filled = size
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(system, &address, 0, nil, &filled, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.prefix(Int(filled) / MemoryLayout<AudioObjectID>.size).map { id in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                            mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &runningSize, &running)
            return AudioDeviceInfo(id: id,
                                   name: string(id, kAudioDevicePropertyDeviceNameCFString) ?? "?",
                                   uid: string(id, kAudioDevicePropertyDeviceUID) ?? "?",
                                   runningSomewhere: running != 0)
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value = cf?.takeRetainedValue() else { return nil }
        return value as String
    }
}
