import Foundation
import CoreAudio
import AudioToolbox

// =====================================================================================
// SystemAudioTap: records "everything the Mac plays" (the remote participants) with a Core Audio
// process tap (CATapDescription, macOS 14.2+). No ScreenCaptureKit, no virtual driver, no kernel ext.
//
// Graph per build:   CATapDescription -> AudioHardwareCreateProcessTap -> private aggregate device that
//                    contains the tap (+ one output device as clock) -> IOProc -> mono mix -> Recorder
//
//  * mode .global (default): stereo mix of ALL processes except our own process object.
//  * mode .app: only the process objects whose bundle id belongs to the meeting platform's family
//    (Chrome*, us.zoom.*, com.microsoft.teams*). Process objects are only created once a process has talked
//    to the audio system, so the list is re-checked every 2 s and the tap is rebuilt when NEW members appear.
//    If no family process exists at start we fall back to the global tap (and say so in the log).
//  * muteBehavior is .unmuted: the user's speakers keep playing.
//  * isPrivate tap + private aggregate: both are visible only to this process and are destroyed by the HAL
//    when the process exits, even by a crash (documented in AudioHardware.h / CATapDescription.h). On top of
//    that we sweep for leftovers with our UID prefix before every build and destroy on every teardown.
//
// Which device clocks the aggregate ("tap host strategy", see TapHost / TapHostPolicy below). A global tap
// (CATapDescription without deviceUID) is a mix of every process's OUTPUT, wherever that output goes: CATapDescription.h
// documents deviceUID as "an optional deviceUID that will have a value if this tap only taps a specific hardware
// device", and the global initializers never set it; AudioHardware.h says the Tap class "contains a list of input
// streams that originate from the output stream(s) of one or more processes". So the device that hosts the aggregate is
// only a clock, and the built-in output can host it while the sound goes to a USB / Bluetooth speakerphone. That is the
// assumption the first choice relies on for devices that also have input streams; it cannot be verified without the tap
// permission, so the strategy is SELF-HEALING and covers every way the assumption could be wrong: a graph that delivers
// only digital silence while other apps have audio output open is replaced after 10 s (an unproven strategy that has an
// alternative) or 45 s by the next candidate (speakerphone: built-in output -> tap only -> the speakerphone itself), a
// strategy that delivered audio is remembered per default output device for the rest of the run, and the active
// strategy is written to app.log ("tap host strategy ...") and to session.json tracks.remote.device
// ("<device> [tap host: ...]", with " -> " between the entries when it changed during the recording).
// A BLUETOOTH default output (transport type 'blue' / 'blea') is treated like a headset even when it shows no input streams
// (macOS lists the hands-free microphone of AirPods as a separate ":input" device): its sample rate follows the Bluetooth
// profile (A2DP 44.1 / 48 kHz, hands-free 16 / 24 kHz as soon as ANY app opens the microphone, and the recorder opens the
// microphone first), so the built-in output clocks the aggregate and the profile cannot change the tap's clock. The default
// output stays in the candidate list (second, it is the configuration that delivered audio on the AirPods test).
//
// Output device changes (AirPods connect / dock): the default output device is watched (+ the host device's nominal
// sample rate, the tap format, and a 2 s polling backstop in HALCapture); a change that matters tears everything down and
// builds it again. Recorder fills the gap with silence using the host timestamps of the first buffer after the rebuild.
//
// Known macOS 26 problem: after long uptimes a tap can return all-zero buffers while audio is playing (Apple
// developer forums thread 825780; only a full tap + aggregate rebuild helps). HALCapture detects "digital
// silence for 45 s while another process has audio output open" and rebuilds, with exponential backoff.
//
// Sample rate: the file rate is fixed by Recorder (48 kHz). The tap's format is read from kAudioTapPropertyFormat on
// every build, BUT THAT PROPERTY DOES NOT SAY AT WHICH RATE THE AGGREGATE DELIVERS THE TAP: the aggregate runs at the rate
// of its clock device, so a Bluetooth headset whose microphone is open (hands-free profile, 16 / 24 kHz) delivers 24 kHz audio
// while the tap format still says 48000 Hz (AirPods Pro, 2026-10-10: audio at 2x speed, the other half zero-filled).
// So HALCapture MEASURES the delivered rate against the host clock (RateMeter), holds the first ~0.5 s of a build back
// until it knows it, and resamples from the measured rate (any of 16 / 24 / 44.1 / ... kHz) to the fixed file rate. The
// HAL's own rate figures (aggregate nominal / actual rate, aggregate input stream, host device, default output) are logged
// on every build and offered as hints (`Opened.rateHints`), but never trusted over the measurement.
//
// Environment knobs for the live test (not used in normal operation):
//   MC_TAP_AUTOSTART=1   set kAudioAggregateDeviceTapAutoStartKey (IO waits for the first tapped audio)
//   MC_TAP_HOST=builtin|default|tap-only   pin the host strategy (no automatic switching); with `open` use
//                        `open -n -W --env MC_TAP_HOST=tap-only -a ... --args selftest-capture --live ...`
// =====================================================================================

// MARK: - Tap host strategy

/// Which device (if any) clocks the private aggregate that holds the tap.
enum TapHost: String, CaseIterable {
    /// The default output device (the device the sound really goes to). The proven configuration for devices WITHOUT
    /// input streams (MacBook speakers, HDMI, USB DAC): hosting on it cannot open any microphone.
    case defaultOutput = "default-output"
    /// The built-in output (MacBook speakers) clocks the aggregate although the sound goes elsewhere. Used FIRST while the
    /// default output also has input streams (USB speakerphone or headset), and for ANY Bluetooth output (AirPods: their
    /// output device has no input streams, the microphone is a separate ":input" device): the aggregate then contains no
    /// input stream of that device at all, so its microphone side is never started by the tap, the tap's buffers can never
    /// be mistaken for the device's microphone, and above all the aggregate's sample rate does not follow the Bluetooth
    /// profile (A2DP 44.1 / 48 kHz <-> hands-free 16 / 24 kHz), which is what made the tap deliver 24 kHz audio labelled 48 kHz.
    /// (The default output itself is the next / last automatic candidate for such a device, see TapHostPolicy.candidates.)
    case builtInOutput = "built-in-output"
    /// No sub-device: the aggregate holds only the tap. No device dependence at all; the fallback when the host choice
    /// above stays silent. NOT verified on this Mac (the build can fail: then the next candidate is used).
    case tapOnly = "tap-only"

    /// Text for session.json (tracks.remote.device) and the menu.
    var title: String {
        switch self {
        case .defaultOutput: return "default output"
        case .builtInOutput: return "built-in output"
        case .tapOnly: return "none (tap only)"
        }
    }
}

enum TapHostPolicy {
    /// An unproven strategy that has an alternative is given this long (digital silence while other apps have audio
    /// output open) before the graph is rebuilt with the next candidate. Much shorter than the 45 s long-silence heal,
    /// because the silence it reacts to would be missing remote audio anyway.
    static let quickHealSeconds: TimeInterval = 10

    struct Environment: Equatable {
        var defaultHasInputStreams: Bool          // the default OUTPUT device also has input streams (speakerphone, headset)
        var builtInDistinctFromDefault: Bool      // a built-in output exists and is not the default output
        /// The default output's transport type is Bluetooth / Bluetooth LE. AirPods show NO input streams on their output
        /// device (the microphone is a separate ":input" device), so `defaultHasInputStreams` alone does not catch them.
        var defaultIsBluetooth: Bool = false
    }

    /// The environment from what the HAL says about the default output device (a plain description, so the self-test can
    /// feed fake devices of any transport type).
    static func environment(defaultOutput d: CaptureHAL.DeviceDescription, builtInDistinctFromDefault: Bool) -> Environment {
        Environment(defaultHasInputStreams: d.hasInputStreams, builtInDistinctFromDefault: builtInDistinctFromDefault,
                    defaultIsBluetooth: d.isBluetooth)
    }

    /// Candidates in the order they are tried (the first one is used first, the next after silence or a failure).
    ///  * default output without input streams (MacBook speakers, HDMI, USB DAC, ...): just itself; a rebuild repairs a stuck tap.
    ///  * default output with input streams (USB speakerphone, headset): the built-in output as clock, then
    ///    tap-only, then the default output itself as the LAST resort. Why the last one is there at all: the header
    ///    says a tap is a mix of process output, wherever it goes, but nobody has run it on this Mac with the sound on
    ///    a USB device. If both clocks that avoid the device's input streams stayed silent, the remote track would be
    ///    empty for the whole meeting, which is the one outcome this app must not accept. The default output as host
    ///    is what AudioCap-style recorders use everywhere; it is last because its aggregate also contains the device's
    ///    input streams (only the trailing tap buffers are read, see CaptureHAL.Mixer.selectBuffers / the stream usage
    ///    in CoreAudioBackend) and, for a Bluetooth headset, could wake the hands-free profile.
    ///  * a BLUETOOTH default output (with or without input streams): the built-in output as clock, then the default output
    ///    itself (the configuration that delivered audio, at the hands-free rate, on the AirPods test of 2026-10-10: it
    ///    is a safe second choice because the delivered rate is measured), then tap-only. CATapDescription.h: a global
    ///    tap is "a mix of all processes' output", not bound to a device (`deviceUID` is only set by the device-bound
    ///    initializer), so the clock device does not decide WHAT is captured, only at which rate it is delivered.
    ///  * the same, but there is no other output to borrow the clock from: the default output, then tap-only.
    static func candidates(_ e: Environment) -> [TapHost] {
        if e.defaultIsBluetooth {
            return e.builtInDistinctFromDefault ? [.builtInOutput, .defaultOutput, .tapOnly] : [.defaultOutput, .tapOnly]
        }
        guard e.defaultHasInputStreams else { return [.defaultOutput] }
        return e.builtInDistinctFromDefault ? [.builtInOutput, .tapOnly, .defaultOutput] : [.defaultOutput, .tapOnly]
    }

    /// Why `candidates(e)` looks the way it does, for app.log (one line).
    static func explain(_ e: Environment, transport: String) -> String {
        if e.defaultIsBluetooth {
            return e.builtInDistinctFromDefault
                ? "the default output is a Bluetooth device (transport \(transport)): its sample rate follows the Bluetooth profile (hands-free 16/24 kHz while a microphone is open), "
                  + "so the built-in output clocks the tap and the profile cannot change the capture clock; a global tap mixes every process's output wherever it is routed"
                : "the default output is a Bluetooth device (transport \(transport)) but there is no built-in output to borrow a clock from: its own clock is used, the delivered rate is measured"
        }
        if e.defaultHasInputStreams {
            return "the default output also has input streams (transport \(transport)): a clock device without them keeps the microphone side of the device unopened"
        }
        return "the default output (transport \(transport)) has no input streams: it clocks the tap itself"
    }

    /// MC_TAP_HOST: builtin | default | tap-only (anything else = automatic).
    static func parseOverride(_ value: String?) -> TapHost? {
        switch value?.lowercased() {
        case "builtin", "built-in", "built-in-output": return .builtInOutput
        case "default", "default-output": return .defaultOutput
        case "tap-only", "taponly", "none": return .tapOnly
        default: return nil
        }
    }
}

/// Decides which candidate the next build uses. Value type, no device access: unit-tested with scenarios.
///  * a new default output device: start with the remembered strategy for it (one that delivered audio before), else the first candidate;
///  * on the same device, the next candidate after (a) a silence rebuild of a graph that never proved itself, (b) two silence
///    rebuilds in a row even if it had, (c) a graph that could not be started;
///  * a strategy that delivered audio keeps being used (a full rebuild is the cure for the stuck-tap bug, not a change of clock).
struct TapHostChooser {
    struct Choice: Equatable {
        var host: TapHost
        var why: String
    }

    private(set) var deviceUID: String?
    private(set) var current: TapHost?
    private var index = 0
    private var healCount = 0
    private var silentHealsSinceAudio = 0
    private var startFailed = false
    private var candidateCount = 1
    private var currentIsProven = false
    private var troubleArmed = false
    private var troubleUsed = false                     // once per output device

    /// The recorder saw a rate-like gap pattern that neither the measured rate nor its own ratio explains: ONE new graph per
    /// output device. A strategy that has not delivered audio yet (unproven) and has alternatives moves on to the next
    /// candidate; a proven one (or a single / pinned candidate) is only re-created, like the stuck-tap cure. Returns whether a
    /// new graph should be built (false: already used for this device).
    mutating func noteRateTrouble() -> Bool {
        guard current != nil, !troubleUsed else { return false }
        troubleUsed = true
        troubleArmed = candidateCount > 1 && !currentIsProven
        return true
    }

    mutating func choose(deviceUID: String, candidates: [TapHost], healCount: Int, remembered: TapHost?, forced: Bool = false) -> Choice {
        precondition(!candidates.isEmpty, "TapHostChooser needs at least one candidate")
        candidateCount = candidates.count
        var why: String
        if self.deviceUID != deviceUID {
            self.deviceUID = deviceUID
            self.healCount = healCount
            silentHealsSinceAudio = 0
            startFailed = false
            troubleArmed = false
            troubleUsed = false
            if let r = remembered, let i = candidates.firstIndex(of: r) {
                index = i
                why = "delivered audio earlier in this run on this output device"
            } else {
                index = 0
                why = "first choice for this output device"
            }
        } else {
            let silentRebuilds = max(0, healCount - self.healCount)
            self.healCount = healCount
            silentHealsSinceAudio += silentRebuilds
            let unproven = remembered != current
            let flip = candidates.count > 1 && (startFailed || (silentRebuilds > 0 && (unproven || silentHealsSinceAudio >= 2)))
            if flip {
                let previous = current
                index = (index + 1) % candidates.count
                why = startFailed ? "\(previous?.rawValue ?? "?") could not be started"
                                  : "\(previous?.rawValue ?? "?") delivered only digital silence while other apps had audio output open"
                if !startFailed { silentHealsSinceAudio = 0 }
            } else {
                why = silentRebuilds > 0 ? "kept: a rebuild is the cure for a stuck tap" : "unchanged"
            }
            startFailed = false
            if troubleArmed {
                troubleArmed = false
                if candidates.count > 1 && !flip {
                    index = (index + 1) % candidates.count
                    why = "a periodic gap pattern in the remote track that neither the measured rate nor the recorder's ratio explained; trying the next strategy"
                }
            }
        }
        index %= candidates.count
        let host = candidates[index]
        current = host
        currentIsProven = remembered == host
        return Choice(host: host, why: forced ? "pinned by MC_TAP_HOST" : why)
    }

    mutating func noteStartFailure() { startFailed = true }
    mutating func noteAudio() { silentHealsSinceAudio = 0 }
}

/// Process-wide memory of the strategy that delivered audio, per default output device UID.
enum TapHostMemory {
    private static let lock = NSLock()
    private static var proven: [String: TapHost] = [:]

    static func recall(_ deviceUID: String) -> TapHost? {
        lock.lock(); defer { lock.unlock() }
        return proven[deviceUID]
    }
    static func remember(_ host: TapHost, for deviceUID: String) {
        lock.lock(); defer { lock.unlock() }
        proven[deviceUID] = host
    }
    static func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        proven = [:]
    }
}

final class SystemAudioTap: CaptureTrackSource {
    // MARK: CaptureTrackSource

    let sampleRate: Double
    var onSamples: (([Float], UInt64) -> Void)?
    var onWarning: ((String) -> Void)?
    var onDeviceChange: ((String) -> Void)?

    var sourceLabel: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return usingApp ? "app-tap" : "global-tap"
    }

    /// The device the user is listening on (default output), not the aggregate.
    var deviceName: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deviceName
    }

    private let requestedMode: SystemAudioMode
    private let signal: PlatformSignal
    private let config: AppConfig
    private var engine: HALCapture?
    private let stateLock = NSLock()
    private var usingApp = false
    private var _deviceName = ""
    private var hostChooser = TapHostChooser()          // HALCapture's control queue only (openTap, onFirstAudio, onStartFailure)

    /// Pure: touches no Core Audio object until start().
    init(sampleRate: Double, mode: SystemAudioMode, signal: PlatformSignal, config: AppConfig) {
        self.sampleRate = sampleRate
        self.requestedMode = mode
        self.signal = signal
        self.config = config
    }

    func start() throws {
        let engine = HALCapture(
            label: "system audio",
            targetRate: sampleRate,
            systemTriggers: [kAudioHardwarePropertyDefaultOutputDevice],
            healZeroRun: true,
            outputActivity: { [weak self] in self?.foreignOutputActive() ?? false },
            open: { [weak self] in
                guard let self = self else { throw RecorderError.failed("system audio tap released") }
                return try self.openTap()
            })
        engine.handler = { [weak self] samples, host in self?.onSamples?(samples, host) }
        engine.onWarning = { [weak self] message in self?.onWarning?(message) }
        engine.onDeviceChange = { [weak self] name in self?.onDeviceChange?(name) }
        engine.onFirstAudio = { [weak self] in self?.hostStrategyDeliveredAudio() }
        self.engine = engine
        try engine.start()
    }

    /// Control queue: the graph that is running now delivered a non-zero sample, so its host strategy works here.
    private func hostStrategyDeliveredAudio() {
        guard let host = hostChooser.current, let uid = hostChooser.deviceUID else { return }
        hostChooser.noteAudio()
        if TapHostMemory.recall(uid) != host {
            TapHostMemory.remember(host, for: uid)
            Log.info("system audio: tap host strategy \(host.rawValue) delivers audio; remembered for this output device")
        }
    }

    func stop() {
        engine?.stop()
    }

    /// Recorder: sustained equal gap fills on the remote track = a rate mismatch. The engine re-measures the delivered rate now.
    func timelineRateSuspected(deliveredRatio: Double) {
        engine?.rateSuspected(deliveredRatio: deliveredRatio)
    }

    // MARK: Building one tap + aggregate (called by HALCapture on its control queue)

    static let aggregateUIDPrefix = "\(AppInfo.bundleID).tap."
    private static let liveLock = NSLock()
    private static var liveAggregateUIDs = Set<String>()

    private func openTap() throws -> HALCapture.Opened {
        let leaked = Self.destroyLeakedAggregates()
        if leaked > 0 { Log.warn("system audio: destroyed \(leaked) leaked aggregate device(s) from an earlier run") }

        guard let defaultOut = CaptureHAL.defaultDevice(input: false), let defaultUID = CaptureHAL.deviceUID(defaultOut) else {
            throw RecorderError.deviceUnavailable("no default audio output device")
        }
        let env = ProcessInfo.processInfo.environment
        let listeningName = CaptureHAL.deviceName(defaultOut) ?? defaultUID

        // Host strategy candidates for this output device (see TapHost / TapHostPolicy).
        let builtIn = CaptureHAL.builtInOutputDevice()
        let defaultDescription = CaptureHAL.describeDevice(defaultOut)
        let environment = TapHostPolicy.environment(defaultOutput: defaultDescription,
                                                    builtInDistinctFromDefault: builtIn != nil && builtIn != defaultOut)
        let forced = TapHostPolicy.parseOverride(env["MC_TAP_HOST"])
        let candidates = forced.map { [$0] } ?? TapHostPolicy.candidates(environment)
        let remembered = TapHostMemory.recall(defaultUID)

        // --- which processes ---
        var included: [AudioObjectID] = []
        let prefixes = Self.familyPrefixes(signal: signal, config: config)
        if requestedMode == .app {
            if prefixes.isEmpty {
                Log.warn("system audio: app mode requested but platform '\(signal.platform.rawValue)' has no process family; using the global tap")
            } else {
                included = Self.processes(matching: prefixes).map { $0.objectID }
                if included.isEmpty {
                    Log.warn("system audio: no audio process of \(prefixes) exists yet; using the global tap for this recording")
                }
            }
        }
        let useApp = !included.isEmpty
        let tapDesc: CATapDescription
        if useApp {
            tapDesc = CATapDescription(stereoMixdownOfProcesses: included)
        } else {
            // Exclude ourselves so we can never record our own sounds. Our process object only exists once we have
            // used the audio system (the mic track starts first), otherwise the list is empty.
            tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        }
        tapDesc.uuid = UUID()
        tapDesc.name = "\(AppInfo.shortName) system audio"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted               // never silence the user's speakers

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw RecorderError.failed("AudioHardwareCreateProcessTap failed: \(CaptureHAL.describe(status))")
        }

        // --- private aggregate device holding the tap: the host strategy decides what (if anything) clocks it ---
        // If the HAL refuses to create the aggregate for one strategy, the next candidate is tried right away.
        let aggregateUID = Self.aggregateUIDPrefix + UUID().uuidString
        let autoStart = env["MC_TAP_AUTOSTART"] == "1"
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var choice = TapHostChooser.Choice(host: .defaultOutput, why: "")
        var hostDevice: AudioObjectID?
        var hostUID: String?
        var createStatus: OSStatus = noErr
        for _ in 0..<candidates.count {
            choice = hostChooser.choose(deviceUID: defaultUID, candidates: candidates, healCount: engine?.zeroHealCount ?? 0,
                                        remembered: remembered, forced: forced != nil)
            hostDevice = nil
            hostUID = nil
            switch choice.host {
            case .defaultOutput:
                hostDevice = defaultOut; hostUID = defaultUID
            case .builtInOutput:
                if let b = builtIn, let uid = CaptureHAL.deviceUID(b) {
                    hostDevice = b; hostUID = uid
                } else {
                    Log.warn("system audio: no built-in output device to clock the tap; using the default output")
                    hostDevice = defaultOut; hostUID = defaultUID
                }
            case .tapOnly:
                break
            }
            var dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "\(AppInfo.shortName) Tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: autoStart,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                ]],
            ]
            if let uid = hostUID {
                dict[kAudioAggregateDeviceMainSubDeviceKey] = uid
                dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
            } else {
                dict[kAudioAggregateDeviceSubDeviceListKey] = [[String: Any]]()        // tap only: no sub-device at all
            }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            createStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
            if createStatus == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) { break }
            Log.warn("system audio: AudioHardwareCreateAggregateDevice failed for tap host strategy \(choice.host.rawValue): \(CaptureHAL.describe(createStatus))")
            hostChooser.noteStartFailure()
        }
        guard createStatus == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw RecorderError.failed("AudioHardwareCreateAggregateDevice failed: \(CaptureHAL.describe(createStatus))")
        }
        let host = choice.host
        Self.liveLock.lock(); Self.liveAggregateUIDs.insert(aggregateUID); Self.liveLock.unlock()
        let cleanup: () -> Void = {
            let a = AudioHardwareDestroyAggregateDevice(aggregateID)
            let t = AudioHardwareDestroyProcessTap(tapID)
            Self.liveLock.lock(); Self.liveAggregateUIDs.remove(aggregateUID); Self.liveLock.unlock()
            if a != noErr || t != noErr {
                Log.warn("system audio: cleanup statuses aggregate=\(CaptureHAL.describe(a)) tap=\(CaptureHAL.describe(t))")
            }
        }

        // --- the real stream format of the tap ---
        var asbd = AudioStreamBasicDescription()
        let fmtStatus = CaptureHAL.get(tapID, kAudioTapPropertyFormat, into: &asbd)
        guard fmtStatus == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0, let kind = CaptureHAL.SampleKind(asbd) else {
            cleanup()
            hostChooser.noteStartFailure()
            throw RecorderError.failed("cannot read a usable tap format (status \(CaptureHAL.describe(fmtStatus)), "
                                       + "rate \(asbd.mSampleRate), channels \(asbd.mChannelsPerFrame), flags \(asbd.mFormatFlags), bits \(asbd.mBitsPerChannel))")
        }
        let hostName = hostDevice.flatMap { CaptureHAL.deviceName($0) } ?? hostUID ?? "-"
        Log.info("system audio: tap host strategy \(host.rawValue) (\(choice.why)); candidates \(candidates.map { $0.rawValue }); "
                 + "host '\(host == .tapOnly ? "none" : hostName)', listening on '\(listeningName)' "
                 + "(default output has input streams: \(environment.defaultHasInputStreams), transport \(defaultDescription.transportName))")
        Log.info("system audio: tap host policy: \(forced != nil ? "pinned by MC_TAP_HOST, automatic choice would be \(TapHostPolicy.candidates(environment).map { $0.rawValue })" : TapHostPolicy.explain(environment, transport: defaultDescription.transportName))")
        Log.info("system audio: tap \(useApp ? "app(\(included.count) processes)" : "global"), "
                 + "tap format \(Int(asbd.mSampleRate)) Hz \(asbd.mChannelsPerFrame) ch \(kind) flags=0x\(String(asbd.mFormatFlags, radix: 16))")
        let aggID = aggregateID, hostDev = hostDevice
        let rateHints: () -> [(name: String, rate: Double)] = {
            var out: [(name: String, rate: Double)] = []
            if let r = CaptureHAL.nominalRate(aggID) { out.append(("aggregate nominal rate", r)) }
            if let last = CaptureHAL.streams(aggID, input: true).last, let f = CaptureHAL.streamFormat(last), f.mSampleRate > 0 {
                out.append(("aggregate tap stream", f.mSampleRate))
            }
            var actual: Float64 = 0
            if CaptureHAL.get(aggID, kAudioDevicePropertyActualSampleRate, into: &actual) == noErr, actual > 0 {
                out.append(("aggregate actual rate", actual))
            }
            if let h = hostDev, let r = CaptureHAL.nominalRate(h) { out.append(("tap host nominal rate", r)) }
            if let r = CaptureHAL.nominalRate(defaultOut) { out.append(("default output nominal rate", r)) }
            return out
        }
        // The HAL's own rate figures, once per build, so a mismatch found later can be read against them in app.log.
        Log.info("system audio: rates: tap format \(Int(asbd.mSampleRate)) Hz; "
                 + rateHints().map { "\($0.name) \(Int($0.rate.rounded())) Hz" }.joined(separator: "; "))

        // session.json tracks.remote.device: the device the user listens on plus the strategy that clocks the tap.
        let deviceLabel = "\(listeningName) [tap host: \(host.title)]"
        stateLock.lock()
        usingApp = useApp
        _deviceName = deviceLabel
        stateLock.unlock()

        // --- loop-proof change detection ---
        // The signature holds only what is a property of REAL devices and what our own IO cannot change (an aggregate's rate
        // is deliberately NOT in it: it can settle after AudioDeviceStart, which would rebuild the graph forever):
        // host device + its nominal rate, the default output's UID, nominal rate and stream format (a Bluetooth profile switch
        // A2DP <-> hands-free changes the last two, whatever clocks the aggregate), and the tap format. A change of any of them
        // re-creates the graph: the new graph is verified against the host clock again (RateMeter) and the tap host policy is
        // re-evaluated for the new device.
        let followsDefault = host == .defaultOutput
        let includedSet = Set(included)
        let signatureNow: () -> String = {
            let curDefaultID = CaptureHAL.defaultDevice(input: false)
            let curDefault = curDefaultID.flatMap { CaptureHAL.deviceUID($0) } ?? "none"
            let hostPart = followsDefault ? curDefault : (hostUID ?? "none")
            let hostRate = Int(hostDevice.flatMap { CaptureHAL.nominalRate($0) } ?? 0)
            let outRate = Int(curDefaultID.flatMap { CaptureHAL.nominalRate($0) } ?? 0)
            let outStream = curDefaultID.flatMap { CaptureHAL.streams($0, input: false).first }.flatMap { CaptureHAL.streamFormat($0) }
            var tapFormat = AudioStreamBasicDescription()
            CaptureHAL.get(tapID, kAudioTapPropertyFormat, into: &tapFormat)
            var sig = "host=\(hostPart)@\(hostRate)|out=\(curDefault)@\(outRate)/\(Int(outStream?.mSampleRate ?? 0))x\(outStream?.mChannelsPerFrame ?? 0)"
                + "|tap=\(Int(tapFormat.mSampleRate))x\(tapFormat.mChannelsPerFrame)"
            if useApp {
                // Only NEW family processes force a rebuild; processes that exit do not.
                let fresh = Self.processes(matching: prefixes).map { $0.objectID }.filter { !includedSet.contains($0) }.sorted()
                sig += "|new=\(fresh)"
            }
            return sig
        }

        var watched: [(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope)] = [
            (tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal),
        ]
        if let h = hostDevice { watched.insert((h, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal), at: 0) }
        // The device the user listens on: its rate / stream format change when a Bluetooth headset switches profile
        // (A2DP <-> hands-free), which is the moment the delivered rate of a graph clocked by it changes.
        if hostDevice != defaultOut { watched.append((defaultOut, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)) }
        watched.append((defaultOut, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
        for stream in CaptureHAL.streams(defaultOut, input: false) {
            watched.append((stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal))
        }

        return HALCapture.Opened(
            ioDevice: aggregateID,
            deviceName: deviceLabel,
            nativeRate: asbd.mSampleRate,
            kind: kind,
            maxChannels: 2,
            tailChannels: Int(asbd.mChannelsPerFrame),
            disableOutputStreams: true,
            watched: watched,
            signature: signatureNow(),
            currentSignature: signatureNow,
            cleanup: cleanup,
            // An unproven strategy that has an alternative gets a short silence check; a strategy that delivered audio
            // on this device earlier, or a pinned one, only the normal long one.
            quickSilenceHeal: candidates.count > 1 && remembered != host && forced == nil ? TapHostPolicy.quickHealSeconds : nil,
            onStartFailure: { [weak self] error in
                Log.warn("system audio: AudioDeviceStart failed with tap host strategy \(host.rawValue): \(error)")
                self?.hostChooser.noteStartFailure()
            },
            rateHints: rateHints,
            rateSourceName: "tap format",
            onRateProblemUnresolved: { [weak self] in
                guard let self = self, self.hostChooser.noteRateTrouble() else { return false }
                Log.info("system audio: the remote track shows periodic gap fills that the measured rate does not explain; re-creating the tap once"
                         + " (tap host strategy \(host.rawValue) -> next candidate unless it has delivered audio)")
                return true
            })
    }

    /// True if some other process (of the family in app mode) currently has an audio output stream running.
    private func foreignOutputActive() -> Bool {
        let own = getpid()
        let prefixes = usingApp ? Self.familyPrefixes(signal: signal, config: config) : []
        return Self.listProcesses().contains { p in
            p.runningOutput && p.pid != own && (prefixes.isEmpty || Self.matches(p.bundleID, prefixes))
        }
    }

    // MARK: Leftover aggregate devices

    /// Destroys aggregate devices carrying our UID prefix that this process does not currently own.
    /// Private aggregates vanish with their process, so this only matters after a failed teardown.
    @discardableResult
    static func destroyLeakedAggregates() -> Int {
        var destroyed = 0
        for dev in CaptureHAL.allDevices() {
            guard let uid = CaptureHAL.deviceUID(dev), uid.hasPrefix(aggregateUIDPrefix) else { continue }
            liveLock.lock(); let isLive = liveAggregateUIDs.contains(uid); liveLock.unlock()
            if isLive { continue }
            if AudioHardwareDestroyAggregateDevice(dev) == noErr { destroyed += 1 }
        }
        return destroyed
    }

    // MARK: Process objects (own small enumeration; AudioProcessMonitor belongs to the detector)

    struct TapProcess {
        var objectID: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var runningOutput: Bool
        var runningInput: Bool
    }

    /// Core Audio process objects. Reading these needs no permission.
    static func listProcesses() -> [TapProcess] {
        let ids: [AudioObjectID] = CaptureHAL.getArray(CaptureHAL.systemObject, kAudioHardwarePropertyProcessObjectList)
        return ids.map { id in
            var pid: pid_t = -1
            CaptureHAL.get(id, kAudioProcessPropertyPID, into: &pid)
            var out: UInt32 = 0
            CaptureHAL.get(id, kAudioProcessPropertyIsRunningOutput, into: &out)
            var inp: UInt32 = 0
            CaptureHAL.get(id, kAudioProcessPropertyIsRunningInput, into: &inp)
            return TapProcess(objectID: id, pid: pid, bundleID: CaptureHAL.getString(id, kAudioProcessPropertyBundleID) ?? "",
                              runningOutput: out != 0, runningInput: inp != 0)
        }
    }

    static func processes(matching prefixes: [String]) -> [TapProcess] {
        let own = getpid()
        return listProcesses().filter { $0.pid != own && matches($0.bundleID, prefixes) }
    }

    static func matches(_ bundleID: String, _ prefixes: [String]) -> Bool {
        let b = bundleID.lowercased()
        return !b.isEmpty && prefixes.contains { b.hasPrefix($0.lowercased()) }
    }

    /// Our own process object (to exclude from the global tap); nil until we have used the audio system.
    static func ownProcessObject() -> AudioObjectID? {
        var addr = CaptureHAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(CaptureHAL.systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != AudioObjectID(kAudioObjectUnknown) ? object : nil
    }

    /// Bundle-id prefixes of the processes that make the call's sound (SPEC section 5).
    static func familyPrefixes(signal: PlatformSignal, config: AppConfig) -> [String] {
        var prefixes: [String]
        switch signal.platform {
        case .meet: prefixes = config.browserBundleIDs
        case .zoom: prefixes = ["us.zoom."]
        case .teams: prefixes = ["com.microsoft.teams"]
        case .manual: prefixes = []
        case .call: prefixes = []          // the app's own bundle id is appended below (its helpers share the prefix)
        }
        if signal.platform == .call, let b = signal.bundleID, !b.isEmpty { return [b] }
        if let b = signal.bundleID, !b.isEmpty, !prefixes.isEmpty { prefixes.append(b) }
        return prefixes
    }

    // MARK: Permission probe (used by requestCapturePermissions)

    /// A tap that is not (yet) allowed to record System Audio still creates fine, starts IO and delivers buffers that
    /// are ALL ZEROS, and there is no public API to query that permission. So callbacks alone prove nothing: the probe
    /// plays a short sound of its own (child process, so the global tap does not exclude it) and says "ok" only if
    /// that sound shows up in the samples.
    static let probePeakThreshold: Float = 1e-4        // about -80 dBFS; digital silence is exactly 0
    static let probeWindowSeconds: TimeInterval = 15   // long enough to read the permission dialog and click Allow

    /// Returns "ok" on success. Every other result starts with "error" (Setup.interpretPermission("system_audio", ...)
    /// accepts exactly "ok" and fails anything that starts with "error" or mentions "denied" / "silence").
    /// Creates a real tap + aggregate and starts IO; only AudioDeviceStart triggers the "System Audio Recording"
    /// prompt (tap creation alone does not). Never call this from an agent shell (requestCapturePermissions refuses
    /// to unless running as the signed app).
    static func probePermission(config: AppConfig) -> String {
        let tap = SystemAudioTap(sampleRate: 48000, mode: .global,
                                 signal: PlatformSignal(platform: .manual, inCall: false), config: config)
        return probe(source: tap, window: probeWindowSeconds, sound: ProbeSound.system())
    }

    /// The probe logic on any source (the self-test runs it on synthetic sources, no device involved).
    static func probe(source: CaptureTrackSource, window: TimeInterval, sound: ProbeSound?) -> String {
        let lock = NSLock()
        var callbacks = 0
        var peak: Float = 0
        source.onSamples = { samples, _ in
            var p: Float = 0
            for s in samples { p = max(p, s.magnitude) }      // NaN never wins max(), so it cannot fake audio
            lock.lock(); callbacks += 1; peak = max(peak, p); lock.unlock()
        }
        do {
            try source.start()
        } catch {
            return "error: \(error)"
        }
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            sound?.tick()
            Thread.sleep(forTimeInterval: 0.1)
            lock.lock(); let heard = peak > probePeakThreshold; lock.unlock()
            if heard { break }
        }
        sound?.stop()
        source.stop()                                          // delivers what is still queued
        lock.lock(); let finalCallbacks = callbacks, finalPeak = peak; lock.unlock()
        if finalPeak > probePeakThreshold { return "ok" }
        if finalCallbacks > 0 {
            return "error: callbacks flowed but only digital silence (permission pending or denied; click Allow and re-run setup; "
                 + "also check that the Mac's sound output is not muted)"
        }
        return "error: tap started but no audio callbacks arrived within \(String(format: "%g", window)) s (permission dialog still open, or the tap is not delivering)"
    }

    /// Plays a short sound every `interval` seconds (never two at once) while the probe waits, so a user who clicks
    /// Allow late still gets a measurable sound. A child process: our own process is excluded from the global tap.
    final class ProbeSound {
        private let executable: String
        private let arguments: [String]
        private let interval: TimeInterval
        private var process: Process?
        private var lastLaunch = Date.distantPast
        private(set) var launches = 0

        init(executable: String, arguments: [String], interval: TimeInterval = 1.5) {
            self.executable = executable
            self.arguments = arguments
            self.interval = interval
        }

        /// afplay of the system "Tink" (short, unobtrusive), or `say` if that file is not there.
        static func system() -> ProbeSound {
            let tink = "/System/Library/Sounds/Tink.aiff"
            if FileManager.default.fileExists(atPath: tink) {
                return ProbeSound(executable: "/usr/bin/afplay", arguments: [tink])
            }
            return ProbeSound(executable: "/usr/bin/say", arguments: ["Meeting capture audio check"])
        }

        /// Call about every 100 ms from the probe's thread.
        func tick() {
            if let p = process, p.isRunning { return }
            guard Date().timeIntervalSince(lastLaunch) >= interval else { return }
            lastLaunch = Date()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                process = p
                launches += 1
            } catch {
                process = nil
                Log.warn("capture probe: cannot play a sound with \(executable): \(error)")
            }
        }

        func stop() {
            if let p = process, p.isRunning { p.terminate() }
            process = nil
        }
    }
}
