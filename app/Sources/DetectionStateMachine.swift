import Foundation

// =====================================================================================
// DetectionStateMachine: pure logic (no I/O, no clock of its own) that turns the per-poll
// DetectionSnapshot into start / split / stop decisions. Contract: Types.swift (StateAction) and SPEC 5 / 13.1.
//
//   idle ──(a platform signal is inCall for START_DEBOUNCE)──▶ recording ──(grace without a signal)──▶ stop
//
// Rules (docs/DETECTION.md section 4; all exercised by `selftest-detector`):
//   - Debounce: a start needs the same meeting inCall for `startDebounce` seconds. A gap shorter than
//     `flickerTolerance` does not restart the debounce; a different platform or Meet code does.
//   - Evidence tiers (Zoom, docs/DETECTION.md section 3): a signal is STRONG or WEAK (`PlatformSignal.evidenceTier`, Teams and Meet are
//     always STRONG). STRONG evidence keeps the rules above. A run of inCall polls that has shown WEAK evidence only (the idle
//     UDP flicker of a signed-in Zoom: 4 sockets, no audio IO, for 4-14 s about every 2 minutes) only counts as a meeting once it has
//     lasted `weakDebounce` seconds (0 = no extra wait, the old behaviour; the wait is never shorter than `startDebounce`):
//       * start: a candidate that has seen a STRONG poll starts after `startDebounce`, a weak-only one after `max(startDebounce, weakDebounce)`;
//       * keep: a recording keeps itself alive with any inCall poll of one CONTINUOUS run that has shown STRONG evidence (as before: a call
//         that drops to a few sockets stays alive), and with a weak-only run once it has lasted `weakDebounce`. A weak-only run that
//         starts after a gap (a flicker during the grace of a call that has ended) does NOT re-arm the grace timer, so it can neither
//         move the stop later nor, after the stop, start a new recording. While such a run is still on, the session is not ended by it
//         either (only a poll without a signal ends it): a Zoom that reconnects inside a real meeting returns weak for its first polls and
//         must not be split in two recordings by that;
//       * a weak-only candidate gives way to a STRONG signal of another meeting (a Zoom flicker never delays a real Teams call).
//   - Grace: a session stops only after its platform has been without a *counting* inCall signal for the *effective* grace:
//     Meet = config grace, Zoom/Teams and the calls of other apps = max(config grace, 30 s) (breakout rooms / reconnects tear
//     down and rebuild media). Every counting inCall poll refreshes the timer, so a signal that keeps flipping inside the grace
//     never stops the session.
//   - Calls of other apps (platform .call, docs/DETECTION.md section 3b): there is one signal PER APP, keyed by the app (`meetingKey` = its main bundle id).
//     A candidate is "the same meeting" only for the same app, and a session follows the signal of ITS app only: another app's call neither keeps it
//     alive nor ends it, and while a session runs no other app starts anything (the machine is in the recording state). Two call apps never split into each other.
//   - A call of another app never blocks Zoom, Teams or Meet: while a session of platform .call runs, a STRONG, high-confidence signal of one of the three
//     that stays inCall for `startDebounce` ends the call session and starts that meeting (`.split`, the same debounce a start needs; a gap shorter than the
//     flicker tolerance does not restart it). The other way round nothing is preempted: a Zoom / Teams / Meet session is never taken over by a call app.
//   - Split (Meet only): a different meeting code that stays visible for the grace window ends the session and
//     starts a new one (`.split`). Flipping back to the old code, or a gap longer than the flicker tolerance,
//     cancels it. A missing code (tab query failed / Automation denied) never splits.
//   - Manual recording: adoptManualRecording() makes the machine track a user-started session without ever
//     stopping or splitting it; the caller ends it with reset().
//   - reset(): forget everything (idle, no candidate). A meeting that is still running is detected afresh and
//     starts again after the debounce (the caller suppresses that when it must not happen).
//   - A wall clock that moves backwards re-anchors the timers instead of freezing them.
// =====================================================================================

struct DetectionStateMachine {
    /// A missing inCall for less than this does not break a debounce or a pending split.
    static let flickerTolerance: TimeInterval = 3
    /// Zoom, Teams and the calls of other apps never use a grace shorter than this.
    static let zoomTeamsMinGrace: TimeInterval = 30

    private struct Candidate {
        var platform: Platform
        var key: String?
        var since: Date
        var lastSeen: Date
        /// A STRONG poll was seen in this run of inCall polls.
        var sawStrong: Bool
    }

    /// One continuous run of inCall polls of a recording's platform (continuous = no gap longer than the flicker tolerance).
    private struct Run {
        var since: Date
        var lastSeen: Date
        var sawStrong: Bool
    }

    private struct Session {
        var platform: Platform
        var key: String?
        var manual: Bool
        var lastAlive: Date
        var run: Run?
        /// The recording started on STRONG evidence (always true for a manual recording).
        var startedStrong: Bool
    }

    private struct PendingSplit {
        var key: String
        var since: Date
        var lastSeen: Date
    }

    /// A Zoom / Teams / Meet meeting that is in a call (STRONG, high confidence) while a call of another app is being recorded.
    private struct PendingPreempt {
        var platform: Platform
        var key: String?
        var since: Date
        var lastSeen: Date
    }

    private let startDebounce: TimeInterval
    private let grace: TimeInterval
    private let weakDebounce: TimeInterval
    private var candidate: Candidate?
    private var session: Session?
    private var pendingSplit: PendingSplit?
    private var pendingPreempt: PendingPreempt?

    /// `weakDebounce` = ZOOM_WEAK_DEBOUNCE_SECONDS: how long WEAK-only evidence must last before it counts (0 = it counts like STRONG evidence;
    /// the default keeps the behaviour of the two-argument contract in Types.swift).
    init(startDebounce: TimeInterval, grace: TimeInterval, weakDebounce: TimeInterval = 0) {
        self.startDebounce = max(0, startDebounce)
        self.grace = max(0, grace)
        self.weakDebounce = max(0, weakDebounce)
    }

    /// state == recording (including the grace period and a pending split)
    var isRecording: Bool { session != nil }

    /// inCall seen, still debouncing (menu: "Meeting detected")
    var isCandidate: Bool { session == nil && candidate != nil }

    /// The candidate has shown WEAK evidence only so far (and WEAK evidence has to wait): it is not "a meeting detected" yet.
    var candidateIsWeakOnly: Bool {
        guard session == nil, let c = candidate else { return false }
        return !c.sawStrong && waitsForWeak
    }

    /// The active session started on STRONG evidence (nil without a session). Read right after `.start` / `.split`.
    var sessionStartedStrong: Bool? { session?.startedStrong }

    /// Seconds WEAK-only evidence has to last before it counts (the configured value, never below the start debounce); 0 = no extra wait.
    var weakWait: TimeInterval { waitsForWeak ? max(startDebounce, weakDebounce) : 0 }

    private var waitsForWeak: Bool { weakDebounce > 0 }

    /// Grace that applies to a session of `platform` (Meet: config, Zoom/Teams/other calls: at least 30 s).
    func effectiveGrace(for platform: Platform) -> TimeInterval {
        switch platform {
        case .zoom, .teams, .call: return max(grace, Self.zoomTeamsMinGrace)
        case .meet, .manual: return grace
        }
    }

    mutating func step(now: Date, snapshot: DetectionSnapshot) -> StateAction {
        if let s = session {
            return s.manual ? .none : stepRecording(s, now: now, snapshot: snapshot)
        }
        return stepIdle(now: now, snapshot: snapshot)
    }

    /// Call after a manual stop / pause / app-initiated stop or a failed start.
    mutating func reset() {
        session = nil
        candidate = nil
        pendingSplit = nil
        pendingPreempt = nil
    }

    /// The user pressed "Start Recording Now": track it as recording, never auto-stop it.
    mutating func adoptManualRecording() {
        session = Session(platform: .manual, key: nil, manual: true, lastAlive: Date(), run: nil, startedStrong: true)
        candidate = nil
        pendingSplit = nil
        pendingPreempt = nil
    }

    // MARK: - Tier helpers

    /// How long a run has to last before a start / a keep: the plain debounce once STRONG evidence was seen (or when WEAK evidence does not wait).
    private func startNeeded(sawStrong: Bool) -> TimeInterval {
        return sawStrong || !waitsForWeak ? startDebounce : max(startDebounce, weakDebounce)
    }

    /// Does this run of inCall polls count as a meeting right now (keeps a recording alive)?
    private func counts(_ run: Run, now: Date) -> Bool {
        return run.sawStrong || !waitsForWeak || now.timeIntervalSince(run.since) >= max(startDebounce, weakDebounce)
    }

    /// The tier of a signal as far as this machine is concerned: without the weak wait (ZOOM_WEAK_DEBOUNCE_SECONDS=0) everything is STRONG.
    private func tier(of signal: PlatformSignal) -> EvidenceTier {
        return waitsForWeak ? signal.evidenceTier : .strong
    }

    /// The signal to follow when several are inCall: STRONG before WEAK, then high confidence, then enabled order.
    private func preferred(_ active: [PlatformSignal]) -> PlatformSignal? {
        return active.first { tier(of: $0) == .strong && $0.confidence == .high }
            ?? active.first { tier(of: $0) == .strong }
            ?? active.first { $0.confidence == .high }
            ?? active.first
    }

    // MARK: - Idle: debounce

    private mutating func stepIdle(now: Date, snapshot: DetectionSnapshot) -> StateAction {
        let active = snapshot.signals.filter { $0.inCall }
        // Keep following the current candidate while its signal is on; otherwise take the preferred signal.
        var chosen: PlatformSignal?
        if let c = candidate { chosen = active.first { Self.sameMeeting(c.platform, c.key, $0) } }
        // A candidate that has shown WEAK evidence only gives way to a STRONG signal of another meeting.
        if let c = candidate, !c.sawStrong, waitsForWeak,
           let strong = active.first(where: { tier(of: $0) == .strong && !Self.sameMeeting(c.platform, c.key, $0) }) {
            chosen = strong
        }
        if chosen == nil { chosen = preferred(active) }

        guard let signal = chosen else {
            if var c = candidate {
                c.lastSeen = min(c.lastSeen, now)
                candidate = now.timeIntervalSince(c.lastSeen) > Self.flickerTolerance ? nil : c
            }
            return .none
        }

        let strong = tier(of: signal) == .strong
        if var c = candidate, Self.sameMeeting(c.platform, c.key, signal) {
            c.since = min(c.since, now)
            c.lastSeen = now
            if c.key == nil { c.key = signal.meetingKey }
            if strong { c.sawStrong = true }
            candidate = c
        } else {
            candidate = Candidate(platform: signal.platform, key: signal.meetingKey, since: now, lastSeen: now, sawStrong: strong)
        }

        if let c = candidate, now.timeIntervalSince(c.since) >= startNeeded(sawStrong: c.sawStrong) {
            session = Session(platform: signal.platform, key: signal.meetingKey ?? c.key, manual: false, lastAlive: now,
                              run: Run(since: c.since, lastSeen: now, sawStrong: c.sawStrong), startedStrong: c.sawStrong)
            candidate = nil
            pendingSplit = nil
            pendingPreempt = nil
            return .start(signal)
        }
        return .none
    }

    // MARK: - Recording: grace and split

    private mutating func stepRecording(_ current: Session, now: Date, snapshot: DetectionSnapshot) -> StateAction {
        var s = current
        s.lastAlive = min(s.lastAlive, now)
        if s.platform == .call, let preempted = preemptCall(s, now: now, snapshot: snapshot) { return preempted }
        let signal = snapshot.signals.first { $0.inCall && Self.belongs($0, to: s) }

        if let signal = signal {
            // The run of inCall polls this one belongs to (a gap longer than the flicker tolerance has already ended the previous run).
            var run = s.run ?? Run(since: now, lastSeen: now, sawStrong: false)
            run.since = min(run.since, now)
            run.lastSeen = now
            if tier(of: signal) == .strong { run.sawStrong = true }
            s.run = run

            if s.platform == .meet, let currentKey = s.key, let seenKey = signal.meetingKey, currentKey != seenKey {
                // Another meeting code is showing: a meeting signal is still on, so the session stays alive, but if
                // the new code persists for the grace window this is a back-to-back meeting.
                s.lastAlive = now
                var p = pendingSplit.flatMap { $0.key == seenKey ? $0 : nil } ?? PendingSplit(key: seenKey, since: now, lastSeen: now)
                p.since = min(p.since, now)
                p.lastSeen = now
                if now.timeIntervalSince(p.since) >= effectiveGrace(for: .meet) {
                    session = Session(platform: .meet, key: seenKey, manual: false, lastAlive: now,
                                      run: Run(since: now, lastSeen: now, sawStrong: tier(of: signal) == .strong),
                                      startedStrong: tier(of: signal) == .strong)
                    pendingSplit = nil
                    return .split(signal)
                }
                pendingSplit = p
                session = s
                return .none
            }
            if s.key == nil { s.key = signal.meetingKey }
            // A weak-only run that has not lasted long enough (the flicker after a call that ended) does not RE-ARM the grace timer, so it can
            // never move the stop later than the grace says. It does not END the session either while it is still on: the session ends at the first
            // poll WITHOUT a signal once the grace is over. Why: when Zoom reconnects inside a real meeting (sockets gone for ~26 s, seen live
            // at 17:19 on 2026-10-10) it comes back weak for its first polls (1, 2, 4 ... sockets, audio IO not up yet); a stop here, at the very
            // poll that shows the call is back, would split one meeting in two recordings and lose ~15 s of it. A flicker that is on when the
            // grace runs out delays the stop by its own length at most (it either ends, then the next no-signal poll stops, or it lasts the weak
            // debounce, then it counts as a meeting like any other weak call).
            if counts(run, now: now) {
                s.lastAlive = now
            }
            pendingSplit = nil
            session = s
            return .none
        }

        // No signal for this platform in this poll.
        if var r = s.run {
            r.lastSeen = min(r.lastSeen, now)
            s.run = now.timeIntervalSince(r.lastSeen) > Self.flickerTolerance ? nil : r
        }
        if var p = pendingSplit {
            p.lastSeen = min(p.lastSeen, now)
            pendingSplit = now.timeIntervalSince(p.lastSeen) > Self.flickerTolerance ? nil : p
        }
        if now.timeIntervalSince(s.lastAlive) >= effectiveGrace(for: s.platform) {
            reset()
            return .stop(.meetingEnded)
        }
        session = s
        return .none
    }

    /// A call of another app is running: a Zoom / Teams / Meet meeting that is STRONG and high confidence for `startDebounce` takes over (`.split`). nil = nothing yet.
    /// Without this, a Slack huddle or Discord channel left open (or a generic false positive) would silently cost the real Zoom / Teams meeting.
    private mutating func preemptCall(_ s: Session, now: Date, snapshot: DetectionSnapshot) -> StateAction? {
        let challenger = snapshot.signals.first {
            $0.inCall && $0.platform != .call && $0.platform != .manual && tier(of: $0) == .strong && $0.confidence == .high
        }
        guard let c = challenger else {
            if var p = pendingPreempt {
                p.lastSeen = min(p.lastSeen, now)
                pendingPreempt = now.timeIntervalSince(p.lastSeen) > Self.flickerTolerance ? nil : p
            }
            return nil
        }
        var p = pendingPreempt.flatMap { Self.sameMeeting($0.platform, $0.key, c) ? $0 : nil } ?? PendingPreempt(platform: c.platform, key: c.meetingKey, since: now, lastSeen: now)
        p.since = min(p.since, now)
        p.lastSeen = now
        guard now.timeIntervalSince(p.since) >= startDebounce else {
            pendingPreempt = p
            return nil
        }
        session = Session(platform: c.platform, key: c.meetingKey, manual: false, lastAlive: now,
                          run: Run(since: p.since, lastSeen: now, sawStrong: true), startedStrong: true)
        candidate = nil
        pendingSplit = nil
        pendingPreempt = nil
        return .split(c)
    }

    /// Does this signal carry the session's meeting? The platform, and for a call of another app the app (one signal per app).
    private static func belongs(_ signal: PlatformSignal, to session: Session) -> Bool {
        guard signal.platform == session.platform else { return false }
        if session.platform == .call, let key = session.key { return signal.meetingKey == key }
        return true
    }

    /// Same meeting = same platform and, when both sides know a Meet code, the same code. A missing code on either
    /// side is "unknown", not "different".
    private static func sameMeeting(_ platform: Platform, _ key: String?, _ signal: PlatformSignal) -> Bool {
        guard platform == signal.platform else { return false }
        guard let a = key, let b = signal.meetingKey else { return true }
        return a == b
    }
}
