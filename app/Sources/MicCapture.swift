import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// =====================================================================================
// MicCapture: records the DEFAULT INPUT DEVICE (the user's voice) as a mono track at a fixed sample rate.
//
// Implementation choice: a plain Core Audio IOProc on the default input device (shared HALCapture engine),
// not AVAudioEngine. Reasons:
//   * AVAudioEngine on macOS also drives the default OUTPUT device and posts configuration-change
//     notifications for output changes that do not concern a mic-only recorder; installTap with a stale
//     format raises an Objective-C exception that Swift cannot catch (would kill an unattended app).
//   * The HAL gives exact capture host timestamps (needed for the track offset and for gap filling).
//   * One code path with the system-audio tap: same rebuild-on-change logic, same resampler
//     (AVAudioConverter) when the device rate differs from the fixed file rate.
// Default input device changes (AirPods, Continuity iPhone mic, docks) are handled by a listener on
// kAudioHardwarePropertyDefaultInputDevice plus listeners on the device's sample rate / stream configuration /
// liveness; each triggers a full rebuild on the new default device, and Recorder fills the gap with silence.
//
// NO voice processing (VPIO / voiceProcessingEnabled) in v1: it ducks other audio, applies echo
// cancellation that fights Zoom/Meet's own, and changes the system-wide audio session. The raw mic is
// recorded; echo of the speakers in the mic track is removed later by the Python pipeline.
//
// Permission: AVCaptureDevice audio authorization is checked before any device is touched. In unattended
// mode (allowPermissionPrompt == false) anything but .authorized throws RecorderError.permissionDenied so
// the app can tell the user; only setup / self-test (allowPermissionPrompt == true) may show the system prompt.
// =====================================================================================

final class MicCapture: CaptureTrackSource {
    let sampleRate: Double
    /// Only setup / self-test paths set this to true. Unattended recording must never pop a dialog.
    var allowPermissionPrompt = false
    var onSamples: (([Float], UInt64) -> Void)?
    var onWarning: ((String) -> Void)?
    var onDeviceChange: ((String) -> Void)?

    var sourceLabel: String { "mic" }
    var deviceName: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deviceName
    }
    /// The input device the capture is on right now (it follows a default-device switch); nil before the first build and after stop().
    /// MuteGate's device signal asks for it on every poll.
    var currentInputDevice: AudioObjectID? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _inputDevice
    }

    private var engine: HALCapture?
    private let stateLock = NSLock()
    private var _deviceName = ""
    private var _inputDevice: AudioObjectID?

    /// Pure: touches no device until start().
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func start() throws {
        try Self.ensureAuthorized(allowPrompt: allowPermissionPrompt)
        let engine = HALCapture(
            label: "microphone",
            targetRate: sampleRate,
            systemTriggers: [kAudioHardwarePropertyDefaultInputDevice],
            healZeroRun: false,
            open: { [weak self] in
                guard let self = self else { throw RecorderError.failed("microphone capture released") }
                return try self.openInput()
            })
        engine.handler = { [weak self] samples, host in self?.onSamples?(samples, host) }
        engine.onWarning = { [weak self] message in self?.onWarning?(message) }
        engine.onDeviceChange = { [weak self] name in self?.onDeviceChange?(name) }
        self.engine = engine
        try engine.start()
    }

    func stop() {
        engine?.stop()
        stateLock.lock(); _inputDevice = nil; stateLock.unlock()
    }

    /// Recorder: sustained equal gap fills on the mic track = a rate mismatch. The engine re-measures the delivered rate now.
    func timelineRateSuspected(deliveredRatio: Double) {
        engine?.rateSuspected(deliveredRatio: deliveredRatio)
    }

    // MARK: Building the capture graph (called by HALCapture on its control queue)

    private func openInput() throws -> HALCapture.Opened {
        guard let device = CaptureHAL.defaultDevice(input: true) else {
            throw RecorderError.deviceUnavailable("no default audio input device (microphone)")
        }
        let uid = CaptureHAL.deviceUID(device) ?? "unknown"
        let name = CaptureHAL.deviceName(device) ?? uid
        let streams = CaptureHAL.streams(device, input: true)
        guard let first = streams.first, let asbd = CaptureHAL.streamFormat(first) else {
            throw RecorderError.deviceUnavailable("default input device '\(name)' has no readable input stream")
        }
        guard let kind = CaptureHAL.SampleKind(asbd) else {
            throw RecorderError.failed("input device '\(name)' uses an unsupported sample format (flags \(asbd.mFormatFlags), \(asbd.mBitsPerChannel) bit)")
        }
        guard let rate = CaptureHAL.nominalRate(device) ?? (asbd.mSampleRate > 0 ? asbd.mSampleRate : nil) else {
            throw RecorderError.failed("input device '\(name)' reports no sample rate")
        }
        let channels = Int(asbd.mChannelsPerFrame)
        Log.info("microphone: default input '\(name)' uid=\(uid) \(Int(rate)) Hz \(channels) ch \(kind) streams=\(streams.count)")

        stateLock.lock(); _deviceName = name; _inputDevice = device; stateLock.unlock()

        let signatureNow: () -> String = {
            let curUID = CaptureHAL.defaultDevice(input: true).flatMap { CaptureHAL.deviceUID($0) } ?? "none"
            let curRate = Int(CaptureHAL.nominalRate(device) ?? 0)
            var alive: UInt32 = 1
            CaptureHAL.get(device, kAudioDevicePropertyDeviceIsAlive, into: &alive)
            return "in=\(curUID)@\(curRate)|alive=\(alive)"
        }
        return HALCapture.Opened(
            ioDevice: device,
            deviceName: name,
            nativeRate: rate,
            kind: kind,
            maxChannels: 2,
            tailChannels: nil,
            disableOutputStreams: true,           // e.g. AirPods are one device with input AND output
            watched: [
                (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                (device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
                (device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            ] + streams.map { ($0, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal) },
            signature: signatureNow(),
            currentSignature: signatureNow,
            cleanup: {},
            // A Bluetooth headset microphone runs at the hands-free rate (16 / 24 kHz) and may switch profile under us: the
            // delivered rate is verified against the host clock like the tap's, these are only the HAL's own figures for it.
            rateHints: {
                var out: [(name: String, rate: Double)] = []
                if let r = CaptureHAL.nominalRate(device) { out.append(("input device nominal rate", r)) }
                if let s = CaptureHAL.streams(device, input: true).first, let f = CaptureHAL.streamFormat(s), f.mSampleRate > 0 {
                    out.append(("input stream format", f.mSampleRate))
                }
                return out
            },
            rateSourceName: "device format")
    }

    // MARK: Authorization (read-only query never prompts; request does)

    /// "authorized" | "denied" | "restricted" | "notDetermined". Read-only, shows no dialog.
    static func authorizationStatusString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }

    /// Throws RecorderError.permissionDenied unless the microphone is authorized (prompting only if allowed).
    static func ensureAuthorized(allowPrompt: Bool) throws {
        switch authorizationStatusString() {
        case "authorized":
            return
        case "notDetermined":
            guard allowPrompt else {
                throw RecorderError.permissionDenied("microphone permission has not been granted yet; run `\(AppInfo.shortName) setup` once and allow the prompt")
            }
            let result = requestAuthorization(timeout: 120)
            if result != "authorized" {
                throw RecorderError.permissionDenied("microphone access was not granted (\(result))")
            }
        case "restricted":
            throw RecorderError.permissionDenied("microphone access is restricted by a system policy")
        default:
            throw RecorderError.permissionDenied("microphone access is denied; enable it in System Settings > Privacy & Security > Microphone")
        }
    }

    /// Shows the system prompt if the status is notDetermined and blocks until answered (or timeout).
    /// Returns the resulting status string. Setup / self-test only; never call from an agent shell.
    static func requestAuthorization(timeout: TimeInterval) -> String {
        if authorizationStatusString() == "notDetermined" {
            let done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
            _ = done.wait(timeout: .now() + timeout)
        }
        return authorizationStatusString()
    }
}

// MARK: Mute signal of the input device (MuteGate)

extension MicCapture: MuteSignalProviding {
    /// The microphone's own mute state: the mute switch or an input volume of 0 of the device the capture is on right now (10 polls a
    /// second: reading two properties costs microseconds). No permission is needed; a device without the properties reads unknown.
    func muteSignals() -> [MuteSignalSource] {
        return [PolledMuteSignal(name: "device", interval: 0.1) { [weak self] in
            guard let device = self?.currentInputDevice else { return .unknown }
            return CaptureHAL.inputMuteReading(device: device)
        }]
    }
}
