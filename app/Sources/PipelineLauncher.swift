import Foundation

// =====================================================================================
// PipelineLauncher: runs the Python post-processing as a child process, one job at a time.
//
//   PYTHON_BIN -m mcap process <session_dir>      (cwd = PROJECT_DIR/pipeline, minimal env)
//   PYTHON_BIN -m mcap reprocess --last           (menu: "Reprocess Last Meeting")
//   PYTHON_BIN -m mcap reprocess --pending        (the retry sweep, SPEC 15)
//   PYTHON_BIN -m mcap gcal upcoming --from-minutes N --to-minutes M   (the calendar auto-start, `runCalendarCommand` at the end of this file: not a job of
//                                                                      the queue; a blocking run of its own with a 20 s limit, stdout only)
//
// stdout+stderr are appended to LOG_DIR/pipeline-<session_id>.log. While a job runs, the session's
// state.json (SPEC 4.3, written only by Python) is read every 2 s so the menu can show the stage.
// Sessions are never retried here except once after a watchdog kill (below): a failure is reported once and the queue moves
// on; failed-but-retryable sessions are picked up again by the retry sweep (SessionController), through this same serial queue.
//
// STALL WATCHDOG (SPEC 15): a job with no state.json update and no log output for `stallTimeout` (90 min) is killed. The time is
// measured with `ProcessInfo.systemUptime` = CLOCK_UPTIME_RAW (mach_absolute_time), which does NOT advance while the Mac sleeps
// (CLOCK_MONOTONIC_RAW / mach_continuous_time do; `Date()` is wall-clock and jumps). So a lid closed for 8 hours is not "8 hours
// of silence". `systemDidWake()` also re-arms the watchdog (the child was suspended with the machine; its connections are gone,
// it deserves a fresh window). A job killed by the watchdog is queued ONCE more; if it stalls again it is reported as failed
// and left for the retry sweep (its state.json still says "not done", which the sweep treats as interrupted).
//
// SPEC 18, checked BEFORE python is started, so that a refusal leaves the session exactly as it was
// (no log file, no state.json, no attempt counted; the controller hears `.blocked`):
//   * RuntimeTrust: with a company policy that names a `runtime.root`, python and the pipeline must live in that root-owned folder;
//   * PipelineContract: with a policy (valid or locked), with policy.required, or for a session whose session.json says local_only=true,
//     `python -m mcap --version` must be at least max(0.2.0, policy.min_pipeline_version). The personal install without a policy and with
//     the flag off keeps running an older pipeline.
// With a policy the child gets no MCAP_* variable and a PATH without ~/.local/bin and /opt/homebrew/bin. Under LOG_CONTENT=0, and for a
// local-only meeting, app.log lines carry no meeting title and no folder name (its slug carries the title), and neither does a failure
// text (the folder a session was being moved to is named in it): paths are cut out of it before it is logged or reported.
// The personal install without a policy asks for the pipeline version at neither app start nor launch. The controller asks
// (`probePipelineVersion`: one `python -m mcap --version` in the background, then `onVersionKnown`) when the local-only menu item needs it:
// an unknown version is not taken as new enough, because an old pipeline never re-reads session.json.
//
// SPEC 18 (optional): `CompanyServerConnect` at the end of this file runs ONE
//   PYTHON_BIN -m mcap asr-engines enroll remote --code-stdin      (the menu item "Connect to Company Server...")
// with the enrollment code of the administrator on the child's STDIN. The code is not a secret, but it still never goes into argv, the
// environment or a log; the token the child gets for it goes to the Keychain from the child itself, and this app never reads it. Nothing
// is started unless the policy allows the company-server relay (lane asr_remote, engine remote, no locked local-only flag) and the Mac is set
// up for one (an org consent in the policy or ASR_REMOTE_URL). Without that the item is not in the menu and the personal install is unchanged.
// =====================================================================================

final class PipelineLauncher: PipelineRunning {

    var onEvent: ((PipelineEvent) -> Void)? {
        get { queue.sync { _onEvent } }
        set { queue.sync { _onEvent = newValue } }
    }

    /// Set by the app: true while a recording is active. `reprocessLast` refuses then, and a reprocess that was queued before
    /// the recording started is dropped instead of launched: it is a long ASR run that would compete with the recorder for
    /// CPU, memory and disk I/O. (The menu item is disabled during a recording too; this is the second line of defence.)
    var recordingActive: (() -> Bool)? {
        get { queue.sync { _recordingActive } }
        set { queue.sync { _recordingActive = newValue } }
    }

    /// `mcap` exit code for "this session is locked by another run" (pipeline/mcap/cli.py EXIT_BUSY).
    static let busyExitStatus: Int32 = 75

    private enum Job: Equatable {
        case process(URL)
        case reprocessLast
        case reprocessPending
    }

    private final class Running {
        let job: Job
        let sessionID: String
        let process: Process
        let logURL: URL
        let logHandle: FileHandle
        let startedAt = Date()
        let logOffset: UInt64                       // size of the log file when this job started (its output begins here)
        var lastActivityWall: Date                  // newest state.json / log mtime seen: only used to notice that something changed
        var lastActivityUptime: TimeInterval        // systemUptime (awake time) at that change, or at the last wake
        var timer: DispatchSourceTimer?
        var lastText: String?
        var stalled = false
        init(job: Job, sessionID: String, process: Process, logURL: URL, logHandle: FileHandle, logOffset: UInt64, uptime: TimeInterval) {
            self.job = job; self.sessionID = sessionID; self.process = process
            self.logURL = logURL; self.logHandle = logHandle; self.logOffset = logOffset
            self.lastActivityWall = startedAt; self.lastActivityUptime = uptime
        }
    }

    private let config: AppConfig
    private let logDir: URL
    private let policyBox: PolicyBox
    private let logContent: Bool                    // LOG_CONTENT (default 1): 0 = no meeting title and no slug path in app.log
    private let localArchiveDir: URL                // LOCAL_ARCHIVE_DIR: where a local-only meeting is published
    private let versionProbe: PipelineVersionProbe
    private let versionRunner: PipelineVersionProbe.Runner?
    private let fileInfo: (URL) -> OrgPolicy.FileInfo?
    private let versionLock = NSLock()
    private var knownVersion: String?               // the last `python -m mcap --version` answer (nil = not asked yet or no answer)
    private var versionProbing = false              // a background probe is running
    private var versionProbed = false               // a background probe has answered (even with 'could not tell'): not repeated
    private var _onVersionKnown: (() -> Void)?
    private let statePollInterval: TimeInterval
    private let stallTimeout: TimeInterval
    /// Awake-time clock for the watchdog (ProcessInfo.systemUptime; the self-test injects a virtual one).
    private let uptime: () -> TimeInterval
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).pipeline", qos: .utility)

    private var _onEvent: ((PipelineEvent) -> Void)?
    private var _recordingActive: (() -> Bool)?
    private var pending: [Job] = []
    private var running: Running?
    private var lastFinalDir: URL?
    private var shuttingDown = false
    private var stallRestarts: [String: Int] = [:]      // session path -> times the watchdog killed it and it was queued again
    private let outcomeLock = NSLock()
    private var outcomes: [String: PipelineOutcome] = [:]    // session name -> what state.json / session.json said when it ended
    private var outcomeOrder: [String] = []
    private static let maxOutcomes = 64

    /// - statePollInterval: how often state.json is read (SPEC: 2 s).
    /// - stallTimeout: a job with no state.json update AND no log output for this long (AWAKE time, see the header) is killed,
    ///   so a hung Python can never block the queue forever. (First-run model download prints progress to the log, so 90 min of
    ///   silence really means stuck.)
    /// - uptime: the awake-time clock; only the self-test replaces it.
    /// - policy / privacy: SPEC 18 (nil = the personal install: no policy, today's behaviour); the box is shared with the controller, which
    ///   replaces the policy when the file changes.
    /// - versionProbe / versionRunner / fileInfo: only the self test replaces them (no real python is asked for its version, no real
    ///   file owner is needed to test the runtime trust).
    init(config: AppConfig, logDir: URL? = nil, statePollInterval: TimeInterval = 2, stallTimeout: TimeInterval = 90 * 60,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         policy: PolicyBox? = nil, privacy: PrivacySettings? = nil,
         versionProbe: PipelineVersionProbe = PipelineVersionProbe.shared, versionRunner: PipelineVersionProbe.Runner? = nil,
         fileInfo: @escaping (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile) {
        self.config = config
        self.logDir = logDir ?? config.logDir
        self.policyBox = policy ?? PolicyBox(OrgPolicy.absent())
        let settings = privacy ?? PrivacySettings.build(from: [:], supportDir: config.supportDir, source: "the built-in defaults")
        self.logContent = settings.logContent
        self.localArchiveDir = settings.localArchiveDir
        self.versionProbe = versionProbe
        self.versionRunner = versionRunner
        self.fileInfo = fileInfo
        self.statePollInterval = statePollInterval
        self.stallTimeout = stallTimeout
        self.uptime = uptime
    }

    // MARK: PipelineRunning

    func enqueue(_ sessionDir: URL) {
        queue.async {
            // Keep the path exactly as given (standardizing would rewrite /private/tmp to /tmp etc.).
            self.add(.process(sessionDir))
        }
    }

    /// What the menu shows when a reprocess was asked for but not started because a recording is active. The controller has
    /// already shown "Queued: reprocess last meeting" by then (it checks first, the launcher a moment later), so a silent
    /// refusal would leave that text on screen until the next job: the refusal is reported as a failure instead.
    static let reprocessBlockedMessage = "Reprocess Last Meeting was not started because a recording is active. Try again after the recording."

    func reprocessLast() {
        queue.async {
            if self._recordingActive?() == true {
                Log.warn("pipeline: reprocess of the last meeting refused: a recording is active")
                self.emit(.failed(session: Self.name(of: .reprocessLast), message: Self.reprocessBlockedMessage))
                return
            }
            self.add(.reprocessLast)
        }
    }

    /// The retry sweep: `mcap reprocess --pending`. Same serial queue, so it never overlaps another job; a duplicate is ignored.
    func reprocessPending() {
        queue.async { self.add(.reprocessPending) }
    }

    func isProcessing(_ sessionDir: URL) -> Bool {
        // Compared as files (a listing of the folder and the URL the job was queued with can differ in /private, a trailing slash).
        func same(_ job: Job) -> Bool {
            if case .process(let dir) = job { return ShellUtil.sameFile(dir, sessionDir) }
            return false
        }
        return queue.sync { (running.map { same($0.job) } ?? false) || pending.contains(where: same) }
    }

    /// What was read (state.json, session.json: read-only) just before the end of this session / job was reported; the controller
    /// builds the notification texts from it (title, platform, length, final_dir or session folder, error kind, reset time, log).
    func outcome(forSession session: String) -> PipelineOutcome? {
        outcomeLock.lock(); defer { outcomeLock.unlock() }
        return outcomes[session]
    }

    /// The pipeline version as far as this launcher knows it (the launch check, `prepareContractCheck` and `probePipelineVersion` ask
    /// `python -m mcap --version`, cached by the probe); nil = not asked yet or no answer. Never starts a process (the menu reads it on
    /// every published state).
    var pipelineVersion: String? {
        versionLock.lock(); defer { versionLock.unlock() }
        return knownVersion
    }

    /// Called when a version answer arrived (set by the controller, which then computes the menu again).
    var onVersionKnown: (() -> Void)? {
        get { versionLock.lock(); defer { versionLock.unlock() }; return _onVersionKnown }
        set { versionLock.lock(); _onVersionKnown = newValue; versionLock.unlock() }
    }

    private func remember(version: String?) {
        versionLock.lock(); knownVersion = version; versionLock.unlock()
    }

    /// Asks for the pipeline version in the background when something requires one (a policy, policy.required, or LOCAL_ONLY_DEFAULT), so
    /// that the menu can say "too old" before the first meeting and the first launch does not wait for it. The personal install without a
    /// policy and with the flag off does not run anything extra at start (it asks when a recording or a finished session needs the
    /// answer: `probePipelineVersion`). Call once at app start.
    func prepareContractCheck(localOnlyDefault: Bool) {
        guard policyBox.policy.isEnforced || localOnlyDefault else { return }
        probePipelineVersion()
    }

    /// The controller needs the version for the local-only toggle and does not know it: one `python -m mcap --version` in the
    /// background, then `onVersionKnown`. Returns at once. Asked at most once while the answer is pending or known (an answer of 'could
    /// not tell' is an answer too: the next launch of a job asks again); never an untrusted python.
    func probePipelineVersion() {
        versionLock.lock()
        guard !versionProbing, knownVersion == nil, !versionProbed else { versionLock.unlock(); return }
        versionProbing = true
        versionLock.unlock()
        let python = config.pythonBin, project = config.projectDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var answer: String?
            // Never ask an untrusted python: the runtime check comes first, as it does at launch.
            if case .untrusted = RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: self.policyBox.policy, fileInfo: self.fileInfo) {
                answer = nil
            } else {
                answer = self.versionProbe.version(pythonBin: python, projectDir: project, runner: self.versionRunner)
            }
            self.versionLock.lock()
            self.versionProbing = false
            self.versionProbed = true
            if answer != nil { self.knownVersion = answer }
            let callback = self._onVersionKnown
            self.versionLock.unlock()
            callback?()
        }
    }

    /// Reads the facts of `session` and keeps them for `outcome(forSession:)`. Called on the launcher queue BEFORE the event is emitted
    /// (the file reads, which may touch Google Drive, happen here and never on the controller's queue).
    private func record(session: String, finalDir: URL? = nil, localOnly: Bool? = nil) {
        var o = PipelineFacts.outcome(session: session, sessionsDir: config.sessionsDir, finalDir: finalDir, logDir: logDir)
        if o.localOnly == nil { o.localOnly = localOnly }          // a job that is not one session (the sweep) can be told it touched a local-only one
        outcomeLock.lock()
        if outcomes.updateValue(o, forKey: session) == nil { outcomeOrder.append(session) }
        while outcomeOrder.count > Self.maxOutcomes { outcomes.removeValue(forKey: outcomeOrder.removeFirst()) }
        outcomeLock.unlock()
    }

    /// The Mac woke up: give the running job a fresh stall window (see the header).
    func systemDidWake() {
        queue.async {
            guard let r = self.running else { return }
            r.lastActivityUptime = self.uptime()
            Log.info("pipeline: wake from sleep: stall watchdog re-armed for \(r.sessionID)")
        }
    }

    func shutdown() {
        queue.sync {
            shuttingDown = true
            pending.removeAll()
            guard let r = running else { return }
            Log.info("pipeline: stopping \(r.sessionID) because the app is quitting (it resumes at next launch)")
            r.timer?.cancel()
            r.process.terminate()
        }
    }

    /// Where "Open Meeting Folder" should go: the last published folder, else the newest folder in ARCHIVE_DIR,
    /// else ARCHIVE_DIR itself. Does file I/O (ARCHIVE_DIR is on Google Drive): call off the main thread.
    func lastMeetingFolder() -> URL? {
        let fm = FileManager.default
        if let d = queue.sync(execute: { lastFinalDir }), fm.fileExists(atPath: d.path) { return d }

        // 1. newest done state.json that still sits in staging and names a final_dir
        var best: (date: Date, url: URL)?
        if let dirs = try? fm.contentsOfDirectory(at: config.sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in dirs {
                guard let state = ShellUtil.readJSON(dir.appendingPathComponent("state.json")),
                      state["stage"] as? String == "done",
                      let path = state["final_dir"] as? String, fm.fileExists(atPath: path) else { continue }
                let updated = (state["updated"] as? String).flatMap(ShellUtil.parseISO8601) ?? .distantPast
                if let current = best, updated <= current.date { continue }
                best = (updated, URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        if let b = best { return b.url }

        // 2. newest YYYY-MM/YYYY-MM-DD_HHMM_* folder by name (names sort chronologically)
        if let months = try? fm.contentsOfDirectory(at: config.archiveDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let monthDirs = months.filter { Self.isDirectory($0) && $0.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for month in monthDirs {
                let kids = (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                if let newest = kids.filter({ Self.isDirectory($0) }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
                    return newest
                }
            }
        }
        // 3. ARCHIVE_DIR, if it exists; otherwise staging so the menu item still opens something useful
        if fm.fileExists(atPath: config.archiveDir.path) { return config.archiveDir }
        return fm.fileExists(atPath: config.sessionsDir.path) ? config.sessionsDir : nil
    }

    // MARK: Queue handling (queue)

    private func add(_ job: Job) {
        guard !shuttingDown else { return }
        if running?.job == job || pending.contains(job) {
            Log.info("pipeline: \(Self.name(of: job)) is already queued/running; ignoring duplicate")
            return
        }
        Log.info("pipeline: queued \(Self.name(of: job))")
        pending.append(job)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        while running == nil, !shuttingDown, !pending.isEmpty {
            let job = pending.removeFirst()
            if case .reprocessLast = job, _recordingActive?() == true {
                Log.warn("pipeline: queued reprocess of the last meeting dropped: a recording is active")
                emit(.failed(session: Self.name(of: job), message: Self.reprocessBlockedMessage))
                continue
            }
            launch(job)
        }
    }

    private func launch(_ job: Job) {
        let fm = FileManager.default
        let sid = Self.name(of: job)

        // Preflight: give an actionable message instead of a cryptic launch error.
        guard fm.isExecutableFile(atPath: config.pythonBin.path) else {
            fail(sid, "Python not found at \(config.pythonBin.path). Run scripts/setup_python.sh.")
            return
        }
        let pipelineDir = config.projectDir.appendingPathComponent("pipeline", isDirectory: true)
        guard fm.fileExists(atPath: pipelineDir.appendingPathComponent("mcap").path) else {
            fail(sid, "Pipeline package not found in \(pipelineDir.path). Check PROJECT_DIR in config.env.")
            return
        }

        // SPEC 18: the runtime and the contract are checked before anything is created or started (see the header).
        if let block = launchBlock(for: job) {
            Log.error("pipeline: \(sid) not started: \(block.logText)")
            emit(.blocked(session: sid, reason: block))
            return                                      // running stays nil: startNextIfIdle goes on with the next job
        }

        // Log file (append: a retried session keeps its history)
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logName: String
        switch job {
        case .process: logName = "pipeline-\(sid).log"
        case .reprocessLast: logName = "pipeline-reprocess-\(Int(Date().timeIntervalSince1970)).log"
        case .reprocessPending: logName = "pipeline-retry-sweep.log"            // one file, appended: the sweep runs every few hours
        }
        let logURL = logDir.appendingPathComponent(logName)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            fail(sid, "Cannot open pipeline log \(logURL.path)")
            return
        }
        let logOffset = (try? handle.seekToEnd()) ?? 0

        let proc = Process()
        proc.executableURL = config.pythonBin
        switch job {
        case .process(let dir): proc.arguments = ["-m", "mcap", "process", dir.path]
        case .reprocessLast: proc.arguments = ["-m", "mcap", "reprocess", "--last"]
        case .reprocessPending: proc.arguments = ["-m", "mcap", "reprocess", "--pending"]
        }
        proc.currentDirectoryURL = pipelineDir
        proc.environment = Self.sanitizedEnvironment(policy: policyBox.policy)
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = handle
        proc.standardError = handle
        proc.qualityOfService = .utility

        let r = Running(job: job, sessionID: sid, process: proc, logURL: logURL, logHandle: handle, logOffset: logOffset, uptime: uptime())
        proc.terminationHandler = { [weak self] p in
            self?.queue.async { self?.processExited(p) }
        }
        running = r

        let header = "\n===== \(ShellUtil.iso8601(Date())) \(config.pythonBin.path) \((proc.arguments ?? []).joined(separator: " ")) =====\n"
        try? handle.write(contentsOf: Data(header.utf8))

        do {
            try proc.run()
        } catch {
            running = nil
            try? handle.close()
            fail(sid, "Cannot launch Python: \(error.localizedDescription)")
            return
        }
        Log.info("pipeline: started \(sid) (pid \(proc.processIdentifier)), log: \(logURL.path)")
        emit(.progress(session: sid, text: "Starting"))

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + statePollInterval, repeating: statePollInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.pollState() }
        r.timer = t
        t.resume()
    }

    /// Every statePollInterval: publish the stage text and watch for a hung job.
    private func pollState() {
        guard let r = running else { return }
        if let (stage, detail, _) = readState(for: r) {
            let text = Self.stageText(stage: stage, detail: detail)
            if text != r.lastText {
                r.lastText = text
                emit(.progress(session: r.sessionID, text: text))
            }
        } else if r.lastText == nil, let text = Self.searchingText(for: r.job) {
            r.lastText = text
            emit(.progress(session: r.sessionID, text: text))
        }

        // Watchdog on AWAKE time. The file times (wall clock) only tell us THAT something was written; how long ago is measured
        // with the awake-time clock, which stands still while the Mac sleeps (see the header comment).
        let seen = max(mtime(stateFile(for: r)) ?? .distantPast, mtime(r.logURL) ?? .distantPast)
        if seen > r.lastActivityWall {
            r.lastActivityWall = seen
            r.lastActivityUptime = uptime()
        }
        if !r.stalled, uptime() - r.lastActivityUptime > stallTimeout {
            r.stalled = true
            Log.error("pipeline: \(r.sessionID) shows no activity for \(Int(stallTimeout)) s of awake time; killing it")
            r.process.terminate()
            let pid = r.process.processIdentifier
            queue.asyncAfter(deadline: .now() + 5) {
                if r.process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func processExited(_ proc: Process) {
        guard let r = running, r.process === proc else { return }
        r.timer?.cancel()
        try? r.logHandle.close()
        running = nil

        let status = proc.terminationStatus
        let signalled = proc.terminationReason == .uncaughtSignal
        let state = readState(for: r)
        Log.info("pipeline: \(r.sessionID) exited \(signalled ? "by signal" : "with status") \(status)")

        defer { startNextIfIdle() }

        if shuttingDown { return }                        // we terminated it ourselves while quitting
        if r.stalled {
            // Killed by the watchdog: a session job is queued ONCE more (Python resumes where it stopped); if it stalls again it
            // is reported and left for the retry sweep (its state.json still says "not done" = interrupted).
            if case .process(let dir) = r.job {
                if (stallRestarts[dir.path] ?? 0) < 1 {
                    stallRestarts[dir.path] = 1
                    Log.warn("pipeline: \(r.sessionID) was killed by the stall watchdog; queued once more (a second stall leaves it for the retry sweep)")
                    pending.append(r.job)
                    emit(.progress(session: r.sessionID, text: "Restarting after a stall"))
                    return
                }
                fail(r.sessionID, "Pipeline stopped responding again and was killed. It is left for the automatic retry sweep. See \(r.logURL.lastPathComponent).")
                return
            }
            fail(r.sessionID, "Pipeline stopped responding and was killed. See \(r.logURL.lastPathComponent).")
            return
        }
        if case .reprocessPending = r.job {
            finishSweep(r, status: status)
            return
        }
        if status == Self.busyExitStatus {
            // `mcap` exits 75 when another mcap process (a terminal, an earlier job) holds the session: not an error, and nothing
            // to tell the user. The other process finishes it; the retry sweep looks again if it does not.
            Log.info("pipeline: \(r.sessionID) is being processed by another mcap process (exit \(status)); leaving it to that one")
            emit(.nothingToReport(session: r.sessionID))
            return
        }
        // A failure text from Python can name the folder the session was being moved to (its name carries the slug of the title): for a
        // local-only meeting and under LOG_CONTENT=0 it reaches app.log, the menu and the notification without any path.
        let hideText = !logContent || hidesMeetingContent(of: r)
        if let (stage, _, error) = state, stage == "failed" {
            fail(r.sessionID, shown(error ?? "pipeline reported failure (see \(r.logURL.lastPathComponent))", hide: hideText))
            return
        }
        if status != 0 {
            let reason = (state?.2) ?? Self.lastLogLine(r.logURL, limit: hideText ? 2_000 : 200) ?? "exit status \(status)"
            fail(r.sessionID, shown(reason, hide: hideText, clip: 200))
            return
        }
        if let (stage, _, _) = state, stage != "done" {
            fail(r.sessionID, "pipeline exited early in stage '\(stage)' (see \(r.logURL.lastPathComponent))")
            return
        }

        // Success. state.json may be gone if publish moved the whole folder to ARCHIVE_DIR: then look the
        // published folder up by its name (YYYY-MM-DD_HHMM_<slug> starts with the session id's date/time).
        if case .process(let dir) = r.job { stallRestarts.removeValue(forKey: dir.path) }
        let raw = readStateDictionary(for: r)
        var title = raw?["title"] as? String
        var finalDir = (raw?["final_dir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if raw == nil, case .process = r.job { finalDir = findPublishedFolder(sessionID: r.sessionID) }
        // `reprocess --last` chooses its own target; its last stdout line is "DONE: <folder>".
        if finalDir == nil, case .reprocessLast = r.job { finalDir = Self.doneFolders(inLog: r.logURL, from: r.logOffset).last }
        if title == nil, let d = finalDir { title = Self.noteTitle(in: d) }
        let discarded = (raw?["discarded"] as? Bool) ?? false
        if let d = finalDir, FileManager.default.fileExists(atPath: d.path) { lastFinalDir = d }
        // No meeting title and no folder name (its slug carries the title) under LOG_CONTENT=0 or for a local-only meeting.
        let localOnlyRun = Self.booleanValue(raw?["local_only"]) == true
        let detail = (!logContent || localOnlyRun) ? " (title and folder omitted from the log\(localOnlyRun ? ": local-only" : ": LOG_CONTENT=0"))"
                                                    : " title=\(title ?? "-") final_dir=\(finalDir?.path ?? "-")"
        Log.info("pipeline: \(r.sessionID) finished\(discarded ? " (discarded: no speech)" : "")\(detail)")
        record(session: r.sessionID, finalDir: finalDir)
        emit(.finished(session: r.sessionID, title: title, finalDir: finalDir, discarded: discarded))
    }

    /// `mcap reprocess --pending` ended (exit 0: all fine or nothing pending; 1: some session failed again). Its stdout lists
    /// "  DONE: <folder>" and "  FAILED: <reason>" per session: every folder that is done becomes a "finished" event (so the
    /// user hears "Meeting note ready" for it), failures become one "failed" event with the first reason.
    private func finishSweep(_ r: Running, status: Int32) {
        let done = Self.doneFolders(inLog: r.logURL, from: r.logOffset)
        for folder in done {
            if FileManager.default.fileExists(atPath: folder.path) { lastFinalDir = folder }
            let title = Self.noteTitle(in: folder)
            record(session: folder.lastPathComponent, finalDir: folder)
            if logContent && outcome(forSession: folder.lastPathComponent)?.localOnly != true {
                Log.info("pipeline: retry sweep finished \(folder.lastPathComponent) title=\(title ?? "-")")
            } else {
                Log.info("pipeline: retry sweep finished a session (title and folder omitted from the log)")
            }
            emit(.finished(session: folder.lastPathComponent, title: title, finalDir: folder, discarded: false))
        }
        if status != 0 {
            // The sweep does not say which session failed: any local-only meeting in this sweep (finished now, or still in staging) makes
            // the text path-free, and the outcome of the sweep job says so for the controller (which scrubs what it logs and shows).
            let localOnlyInvolved = stagingHasLocalOnlySession() || done.contains { outcome(forSession: $0.lastPathComponent)?.localOnly == true }
            let hide = !logContent || localOnlyInvolved
            let reasons = Self.failedReasons(inLog: r.logURL, from: r.logOffset, limit: hide ? 2_000 : 200)
            var message = shown(reasons.first ?? Self.lastLogLine(r.logURL, limit: hide ? 2_000 : 200) ?? "exit status \(status)", hide: hide, clip: 200)
            if reasons.count > 1 { message += " (and \(reasons.count - 1) more; see \(r.logURL.lastPathComponent))" }
            fail(r.sessionID, message, localOnly: localOnlyInvolved ? true : nil)
        } else {
            emit(.nothingToReport(session: r.sessionID))
        }
    }

    /// ARCHIVE_DIR/YYYY-MM/<YYYY-MM-DD_HHMM>_<slug> for a session id like 2026-10-07_1400_meet (nil if not found).
    private func findPublishedFolder(sessionID: String) -> URL? {
        guard sessionID.count >= 15 else { return nil }
        let stamp = String(sessionID.prefix(15))                       // "2026-10-07_1400"
        // ARCHIVE_DIR first; a local-only meeting (or one the organisation kept off Drive) is in LOCAL_ARCHIVE_DIR.
        for root in [config.archiveDir, localArchiveDir] {
            let monthDir = root.appendingPathComponent(String(stamp.prefix(7)), isDirectory: true)
            let kids = (try? FileManager.default.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            if let found = kids.filter({ Self.isDirectory($0) && $0.lastPathComponent.hasPrefix(stamp + "_") })
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first { return found }
        }
        return nil
    }

    // MARK: Runtime trust and pipeline contract

    /// session.json `local_only` as the launcher must read it: a real boolean is itself; the key missing or null is nil (no statement);
    /// anything else is true (Python reads a non-boolean as true too: fail closed).
    static func localOnlyFlag(in sessionDir: URL) -> Bool? {
        guard let json = ShellUtil.readJSON(sessionDir.appendingPathComponent("session.json")), let raw = json["local_only"], !(raw is NSNull) else { return nil }
        return booleanValue(raw) ?? true
    }

    /// A JSON value that is a real boolean (not the number 0 or 1), else nil.
    static func booleanValue(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Does any session in staging say local_only=true (a reprocess job picks its sessions by itself)?
    private func stagingHasLocalOnlySession() -> Bool {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: config.sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.contains { Self.localOnlyFlag(in: $0) == true }
    }

    /// nil = the job may start. The runtime check comes first and an untrusted python is never started, not even for its version.
    private func launchBlock(for job: Job) -> PipelineBlock? {
        let policy = policyBox.policy
        if case .untrusted(let why) = RuntimeTrust.verify(pythonBin: config.pythonBin, projectDir: config.projectDir, policy: policy, fileInfo: fileInfo) {
            return .runtimeUntrusted(why)
        }
        var sessionLocalOnly: Bool?
        switch job {
        case .process(let dir): sessionLocalOnly = Self.localOnlyFlag(in: dir)
        case .reprocessLast, .reprocessPending: sessionLocalOnly = !policy.isEnforced && stagingHasLocalOnlySession() ? true : nil
        }
        guard let required = PipelineContract.required(policy: policy, sessionLocalOnly: sessionLocalOnly) else { return nil }
        let have = versionProbe.version(pythonBin: config.pythonBin, projectDir: config.projectDir, runner: versionRunner)
        remember(version: have)
        if let have = have, PipelineContract.satisfied(version: have, required: required) { return nil }
        return .pipelineTooOld(have: have, required: required)
    }

    /// First "# Title" line of meeting-note.md (the note's H1), if the file exists.
    static func noteTitle(in folder: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent("meeting-note.md")) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 4096), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                let title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }

    private func fail(_ session: String, _ message: String, localOnly: Bool? = nil) {
        Log.error("pipeline: \(session) failed: \(message)")
        record(session: session, localOnly: localOnly)
        emit(.failed(session: session, message: message))
        startNextIfIdle()
    }

    /// `message` as it may be shown: without paths and folder names when `hide` (local-only meeting, LOG_CONTENT=0); `clip` then cuts what is
    /// left to that many characters (the cut comes after the scrub, so a long path does not take the cause with it).
    private func shown(_ message: String, hide: Bool, clip: Int? = nil) -> String {
        let text = hide ? NotificationText.withoutPaths(message) : message
        return clip.map { String(text.prefix($0)) } ?? text
    }

    /// Does the job that ended concern a local-only meeting (session.json of its folder, state.json)? A reprocess job picks its sessions by
    /// itself: any local-only session in staging counts.
    private func hidesMeetingContent(of r: Running) -> Bool {
        switch r.job {
        case .process(let dir):
            return Self.localOnlyFlag(in: dir) == true || Self.booleanValue(readStateDictionary(for: r)?["local_only"]) == true
        case .reprocessLast, .reprocessPending:
            return stagingHasLocalOnlySession()
        }
    }

    private func emit(_ event: PipelineEvent) {
        _onEvent?(event)
    }

    // MARK: state.json

    private func stateFile(for r: Running) -> URL {
        switch r.job {
        case .process(let dir): return dir.appendingPathComponent("state.json")
        case .reprocessLast, .reprocessPending: return newestStateFile(since: r.startedAt) ?? logDir.appendingPathComponent("__none__")
        }
    }

    private func readStateDictionary(for r: Running) -> [String: Any]? {
        return ShellUtil.readJSON(stateFile(for: r))
    }

    /// (stage, stage_detail, error)
    private func readState(for r: Running) -> (String, String?, String?)? {
        guard let d = readStateDictionary(for: r), let stage = d["stage"] as? String else { return nil }
        let detail = d["stage_detail"] as? String
        let error = d["error"] as? String
        return (stage, detail, error)
    }

    /// `reprocess --last` picks its own target; the best we can do is follow the staging state.json that changed
    /// after the job started. (A reprocess of an already published folder has no staging state.)
    private func newestStateFile(since: Date) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: config.sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var best: (Date, URL)?
        for dir in dirs {
            let f = dir.appendingPathComponent("state.json")
            guard let m = mtime(f), m >= since else { continue }
            if let current = best, m <= current.0 { continue }
            best = (m, f)
        }
        return best?.1
    }

    private func mtime(_ url: URL) -> Date? {
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Pure helpers

    /// Minimal, explicit environment for the child. Nothing is inherited, so ANTHROPIC_* (API billing paths),
    /// CLAUDE_* and friends cannot leak into the pipeline. MCAP_CONFIG is forwarded when set so a test config
    /// applies to both processes, and so is MCAP_SECURITY_BIN (a path to a fake Keychain tool, see Setup.swift) so that a test run
    /// can never make the child read the real Keychain.
    ///
    /// SPEC 17: this is the same for CLAUDE_AUTH=subscription and =api. In api mode the Python side reads the API key from the
    /// Keychain itself and puts it into the environment of its own `claude -p` call; this app never sees the key and never puts
    /// one (or any ANTHROPIC_* variable) into the environment it hands to Python.
    ///
    /// SPEC 18: on a policy-managed Mac (`policy` given and a policy file or policy.required exists) no MCAP_* variable is
    /// forwarded (they are test hooks the pipeline ignores there anyway) and PATH loses the two user-writable directories ~/.local/bin and
    /// /opt/homebrew/bin. Without a policy (nil, or absent) the result is exactly what it always was.
    ///
    /// The two names of the app (MCAP_APP_NAME, MCAP_APP_SHORT_NAME) are always handed over, policy or not: they are the app's own Info.plist values, not something
    /// the caller's environment can set, and the pipeline needs them to name the app the way the app does (the Google sign-in page) when it runs from a checkout or a
    /// company release, where no app encloses it (pipeline/mcap/appinfo.py).
    static func sanitizedEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment, policy: OrgPolicy? = nil) -> [String: String] {
        let home = NSHomeDirectory()
        let managed = policy?.isEnforced ?? false
        var env: [String: String] = [
            "HOME": home,
            "PATH": managed ? "/usr/bin:/bin" : "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "MCAP_APP_NAME": AppInfo.displayName,
            "MCAP_APP_SHORT_NAME": AppInfo.shortName,
        ]
        if !managed {
            if let c = base["MCAP_CONFIG"], !c.isEmpty { env["MCAP_CONFIG"] = c }
            if let b = base[ApiKeyItem.securityBinEnv], !b.isEmpty { env[ApiKeyItem.securityBinEnv] = b }
        }
        return env
    }

    /// state.json stage -> menu text, e.g. ("transcribing", "remote 12/48") -> "Transcribing remote 12/48".
    static func stageText(stage: String, detail: String?) -> String {
        let d = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func with(_ base: String) -> String { d.isEmpty ? base : "\(base) \(d)" }
        switch stage {
        case "queued": return "Queued"
        case "audio": return with("Preparing audio")
        case "transcribing": return with("Transcribing")
        case "noting": return "Creating note"
        case "publishing": return "Saving to archive"
        case "done": return "Finishing"
        case "failed": return "Failed"
        default: return with(stage.prefix(1).uppercased() + stage.dropFirst())
        }
    }

    /// The log file name a job of this name writes (LOG_DIR/pipeline-<id>.log; the sweep appends to one file); nil for
    /// `reprocess --last`, whose name carries a timestamp the notification cannot know.
    static func logFileName(forSession name: String) -> String? {
        if name == SessionController.sweepJobName { return "pipeline-retry-sweep.log" }
        if name == "reprocess-last" || name.isEmpty || name.contains("/") { return nil }
        return "pipeline-\(name).log"
    }

    private static func name(of job: Job) -> String {
        switch job {
        case .process(let dir): return dir.lastPathComponent
        case .reprocessLast: return "reprocess-last"
        case .reprocessPending: return SessionController.sweepJobName
        }
    }

    /// Menu text for a job that has no state.json of its own (yet).
    private static func searchingText(for job: Job) -> String? {
        switch job {
        case .process: return nil
        case .reprocessLast: return "Reprocessing last meeting"
        case .reprocessPending: return "Retrying failed meetings"
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// The lines a job wrote to its log (from `offset`, the file size when it started). Whole file read, capped at the last 256 KB.
    private static func logLines(_ url: URL, from offset: UInt64) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        guard size > offset else { return [] }
        let start = max(offset, size > 262_144 ? size - 262_144 : 0)
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).map { String($0) }
    }

    /// "DONE: /abs/path/to/folder" lines (Python prints them per session; the summary line "DONE: pending: ..." and a
    /// "DONE: None" of a discarded session do not start with "/").
    static func doneFolders(inLog url: URL, from offset: UInt64) -> [URL] {
        return doneFolders(in: logLines(url, from: offset))
    }

    static func doneFolders(in lines: [String]) -> [URL] {
        var out: [URL] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("DONE: ") else { continue }
            let path = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { out.append(URL(fileURLWithPath: path, isDirectory: true)) }
        }
        return out
    }

    /// "  FAILED: <reason>" lines of `reprocess --pending` (one per failed session; the summary line starts at column 0 with
    /// "FAILED: pending: ..." and is not a reason).
    static func failedReasons(inLog url: URL, from offset: UInt64, limit: Int = 200) -> [String] {
        return failedReasons(in: logLines(url, from: offset), limit: limit)
    }

    /// `limit`: characters kept of each reason (a caller that has to remove paths first asks for more and clips afterwards, so that a
    /// long path in front of the cause does not cut the cause off).
    static func failedReasons(in lines: [String], limit: Int = 200) -> [String] {
        return lines.compactMap { line in
            guard line.hasPrefix("  FAILED: ") else { return nil }
            let reason = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? nil : String(reason.prefix(limit))
        }
    }

    /// Last non-empty line of a log file (short tail read), for error messages.
    private static func lastLogLine(_ url: URL, limit: Int = 200) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty && !$0.hasPrefix("=====") }
        return line.map { String($0.prefix(limit)) }
    }
}

// MARK: - Connect to Company Server

extension PipelineLauncher {
    /// The connector for the menu item "Connect to Company Server...", sharing this launcher's policy box (the controller's 60 s watcher keeps it
    /// current), runtime-trust check and pipeline-version probe. `notifier` is the app's own (App.swift); without one the connector posts through
    /// a notifier of its own that never touches the click handler. `remoteURL` / `runner` only the self test replaces.
    func companyServerConnect(notifier: NotificationPosting? = nil, remoteURL: ((OrgPolicy) -> String?)? = nil,
                              runner: CompanyServerConnect.Runner? = nil, timeout: TimeInterval = CompanyServerConnect.timeoutSeconds) -> CompanyServerConnect {
        let box = policyBox
        return CompanyServerConnect(config: config, logDir: logDir, policy: { box.policy }, remoteURL: remoteURL, notifier: notifier,
                                    versionProbe: versionProbe, versionRunner: versionRunner, fileInfo: fileInfo, runner: runner, timeout: timeout)
    }
}

/// The policy of this Mac for a caller that has no `PolicyBox` (the menu of an App.swift that did not hand it one): read when first asked and
/// again only when the policy files changed (`PolicyWatcher.systemFingerprint`: three lstat calls), so asking on every menu opening costs
/// nothing and writes no log line. A locked policy is read again at most once a minute (the confirming second read waits half a second).
final class SystemPolicyReader {
    static let lockedRecheckSeconds: TimeInterval = 60

    private let load: () -> OrgPolicy
    private let fingerprint: () -> String
    private let now: () -> Date
    private let lock = NSLock()
    private var cached: (policy: OrgPolicy, fingerprint: String, readAt: Date)?

    init(load: @escaping () -> OrgPolicy = { OrgPolicy.load() }, fingerprint: @escaping () -> String = { PolicyWatcher.systemFingerprint() },
         now: @escaping () -> Date = { Date() }) {
        self.load = load
        self.fingerprint = fingerprint
        self.now = now
    }

    func current() -> OrgPolicy {
        let seen = fingerprint()
        lock.lock(); let held = cached; lock.unlock()
        if let held = held, held.fingerprint == seen, !held.policy.isLocked || now().timeIntervalSince(held.readAt) < Self.lockedRecheckSeconds { return held.policy }
        let fresh = load()
        lock.lock(); cached = (fresh, seen, now()); lock.unlock()
        return fresh
    }
}

/// `python -m mcap asr-engines enroll remote --code-stdin`, started by the menu item "Connect to Company Server...".
///
/// The administrator gives the person a one-time enrollment code (10 minutes, single use). The code goes to the child on its stdin; it is
/// never an argument (ps shows those), never in the environment (every child would inherit it) and never in a log. The child exchanges it for a
/// token with the company server and stores the token in the Keychain itself: this app never reads the token and never runs `security`. What
/// the person is told is a fixed Korean sentence picked from the exit status and, for the kind of failure, from the child's fixed English
/// message (no text of the server or of the child is copied); what the child printed is kept in LOG_DIR/company-server-connect.log after the
/// code and anything shaped like a token were cut out of it.
///
/// No effect without a policy-allowed relay: `availability` is the verdict the menu shows (the lane, the engine list, the
/// local-only lock and the HOST list, which for a company policy is empty = no server unless the policy names it: the same four things the
/// pipeline's decision table asks), `precheck` repeats it with the current policy when the item is clicked (before the person is asked for the
/// code) and again before anything is started, followed by the runtime trust and the pipeline contract of SPEC 18. A refusal starts no
/// enrollment: the code goes nowhere and nothing reaches a server.
final class CompanyServerConnect {
    static let menuTitle = "Connect to Company Server\u{2026}"
    /// The command of SPEC 18. The code is NOT an argument.
    static let arguments = ["-m", "mcap", "asr-engines", "enroll", "remote", "--code-stdin"]
    /// The longest an enrollment may take: it is one request to the company server (the pipeline's own request timeout is shorter).
    static let timeoutSeconds: TimeInterval = 120
    /// What the last attempt printed, code and token-shaped text cut out (LOG_DIR; the next attempt overwrites it).
    static let logFileName = "company-server-connect.log"
    static let notificationIdentifier = "mcap.company-server-connect"
    static let maxOutputBytes = 65_536

    /// Why the policy keeps the relay closed.
    enum Denial: Equatable {
        case policyLocked           // the policy cannot be read: every external lane is closed
        case laneDenied             // lanes.asr_remote is not allow
        case engineNotAllowed       // asr.allowed_engines does not name remote
        case localOnlyLocked        // local_only.locked: no external lane at all
        case hostNotAllowed         // asr.allowed_hosts (a company policy without one = empty = no host) does not name the server

        var reasonText: String {
            switch self {
            case .policyLocked: return tr("The organisation policy cannot be read, so sending out is blocked", ko: "조직 정책을 읽을 수 없어 외부 전송이 막혀 있어요")
            case .laneDenied: return tr("The organisation policy does not allow a connection to the company server", ko: "조직 정책이 회사 서버 연결을 허용하지 않아요")
            case .engineNotAllowed: return tr("The company server is not among the engines the policy allows", ko: "조직 정책의 허용 엔진에 회사 서버가 없어요")
            case .localOnlyLocked: return tr("Local-only is fixed by policy, so the company server cannot be used", ko: "로컬 전용이 조직 정책으로 고정돼 회사 서버를 쓸 수 없어요")
            case .hostNotAllowed: return tr("This company server is not in the policy's list of allowed servers", ko: "조직 정책의 허용 서버 목록에 이 회사 서버가 없어요")
            }
        }
    }

    /// What the menu item shows: no item (nothing says this Mac uses a company server), an item the policy keeps closed, an item that works.
    enum Availability: Equatable {
        case hidden
        case denied(Denial)
        case ready
    }

    /// No enrollment was started and the code went nowhere (a `python -m mcap --version` of a trusted python may have been asked, once).
    enum Refusal: Equatable {
        case notConfigured                                       // neither an org consent in the policy nor ASR_REMOTE_URL
        case relayDenied(Denial)
        case runtimeUntrusted(String)
        case pipelineTooOld(have: String?, required: String)
        case pythonMissing
        case busy                                                // an enrollment is running

        /// English, for app.log (no code, no host).
        var logText: String {
            switch self {
            case .notConfigured: return "no org consent in the policy and no ASR_REMOTE_URL"
            case .relayDenied(let why): return "the policy does not allow the company-server relay (\(why))"
            case .runtimeUntrusted(let why): return "runtime is not trusted (\(why))"
            case .pipelineTooOld(let have, let required): return "pipeline \(have ?? "of unknown version") is older than the required \(required)"
            case .pythonMissing: return "python or the pipeline package is missing"
            case .busy: return "an enrollment is already running"
            }
        }
    }

    /// The child ran (or could not be started) and the Mac is not enrolled.
    enum Failure: Equatable {
        case malformedCode, codeRefused, throttled, unreachable, notAllowed, noConsent, timedOut, couldNotStart, other
    }

    enum Outcome: Equatable {
        case connected
        case refused(Refusal)
        case failed(Failure)
    }

    struct RunResult: Equatable {
        var launched: Bool
        var status: Int32
        var timedOut: Bool
        var output: String          // stdout and stderr together, as the child printed them
    }

    /// Starts the child with `stdin` on its standard input and waits for it. The self test replaces it with a recorder; the default is `runChild`.
    typealias Runner = (_ python: URL, _ arguments: [String], _ environment: [String: String], _ cwd: URL, _ stdin: Data, _ timeout: TimeInterval) -> RunResult

    private let config: AppConfig
    private let logDir: URL
    private let readPolicy: () -> OrgPolicy
    private let readRemoteURL: (OrgPolicy) -> String?
    private let notifier: NotificationPosting?
    private let versionProbe: PipelineVersionProbe
    private let versionRunner: PipelineVersionProbe.Runner?
    private let fileInfo: (URL) -> OrgPolicy.FileInfo?
    private let runner: Runner
    private let timeout: TimeInterval
    private let baseEnvironment: [String: String]
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).company-connect", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var ownNotifier: Notifier?

    /// - policy: where the policy comes from (default: the files of this Mac, read lazily by `SystemPolicyReader`).
    /// - remoteURL: ASR_REMOTE_URL for a policy (default: config.env with the policy layers; the policy decides what layers apply).
    /// - notifier: the app's notifier (default: one of its own, made when the first notification is posted).
    /// - versionProbe / versionRunner / fileInfo / runner / environment: only the self test replaces them (no real python is asked or started, no
    ///   real file owner is needed, the child sees a fixed parent environment).
    init(config: AppConfig, logDir: URL? = nil, policy: (() -> OrgPolicy)? = nil, remoteURL: ((OrgPolicy) -> String?)? = nil,
         notifier: NotificationPosting? = nil, versionProbe: PipelineVersionProbe = PipelineVersionProbe.shared,
         versionRunner: PipelineVersionProbe.Runner? = nil, fileInfo: @escaping (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile,
         runner: Runner? = nil, timeout: TimeInterval = CompanyServerConnect.timeoutSeconds,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.config = config
        self.logDir = logDir ?? config.logDir
        if let policy = policy {
            self.readPolicy = policy
        } else {
            let reader = SystemPolicyReader()
            self.readPolicy = { reader.current() }
        }
        self.readRemoteURL = remoteURL ?? { CompanyServerConnect.configuredRemoteURL(policy: $0) }
        self.notifier = notifier
        self.versionProbe = versionProbe
        self.versionRunner = versionRunner
        self.fileInfo = fileInfo
        self.runner = runner ?? CompanyServerConnect.runChild
        self.timeout = timeout
        self.baseEnvironment = environment
    }

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: What the menu shows

    /// The verdict for the menu item. The item is there only when this Mac is set up for a company server (an org consent in the policy, or
    /// ASR_REMOTE_URL set); it works only while the policy lets this Mac use the relay at all: the lane, the engine list, the local-only lock
    /// and the host list (policy.py `decide_asr`, A2). Pure.
    static func availability(policy: OrgPolicy, remoteURL: String?) -> Availability {
        let url = (remoteURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = !policy.orgConsentHosts.isEmpty || !url.isEmpty
        guard configured else { return .hidden }
        if policy.isLocked { return .denied(.policyLocked) }
        if !policy.laneAllowed("asr_remote") { return .denied(.laneDenied) }
        if !(policy.allowedEngines?.contains("remote") ?? true) { return .denied(.engineNotAllowed) }
        if policy.forcesLocalOnly { return .denied(.localOnlyLocked) }
        // nil = this policy does not restrict hosts; a company policy that omits the list has an EMPTY one (nothing is allowed). The host the
        // pipeline would talk to is the one of ASR_REMOTE_URL; without a URL the hosts of the org consents are all there is to look at.
        if let allowed = policy.allowedHosts {
            let permitted = Set(allowed.map { $0.lowercased() })
            let hosts: [String] = url.isEmpty ? policy.orgConsentHosts.map { $0.lowercased() } : (remoteHost(of: url).map { [$0] } ?? [])
            if !hosts.contains(where: { permitted.contains($0) }) { return .denied(.hostNotAllowed) }
        }
        return .ready
    }

    /// The host of ASR_REMOTE_URL as the pipeline reads it (policy.py `_remote_target`): https, no credentials, a name and not an address, no
    /// trailing dot, lower case. nil = the pipeline would not use that URL at all.
    static func remoteHost(of url: String) -> String? {
        guard let parts = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, var host = parts.host?.lowercased() else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var v4 = in_addr(), v6 = in6_addr()
        if host.isEmpty || host.hasSuffix(".") || inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { return nil }
        return host
    }

    /// ASR_REMOTE_URL as the app sees it: config.env with the policy layers (`PolicyLayers.apply`), nil when it is not set.
    static func configuredRemoteURL(policy: OrgPolicy, file: URL = AppConfig.configFilePath) -> String? {
        var values: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) { values = AppConfig.parseEnvText(text) }
        PolicyLayers.apply(&values, policy: policy)
        let url = (values["ASR_REMOTE_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Reads the policy and config.env: call off the main thread.
    func availability() -> Availability {
        let policy = readPolicy()
        return Self.availability(policy: policy, remoteURL: readRemoteURL(policy))
    }

    // MARK: Connecting

    /// Everything that can be known before the person types the code, with the policy as of now; nil = go on. Starts nothing except, once, a
    /// `python -m mcap --version` of a trusted python (cached by the probe) when the pipeline version is not known yet.
    func precheck() -> Refusal? {
        return check(policy: readPolicy())
    }

    private func check(policy: OrgPolicy) -> Refusal? {
        switch Self.availability(policy: policy, remoteURL: readRemoteURL(policy)) {
        case .hidden: return .notConfigured
        case .denied(let why): return .relayDenied(why)
        case .ready: break
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.pythonBin.path),
              fm.fileExists(atPath: config.projectDir.appendingPathComponent("pipeline/mcap", isDirectory: true).path) else { return .pythonMissing }
        // SPEC 18, in the order of the launcher: the runtime first (an untrusted python is not even asked for its version), then the contract.
        // The enroll command exists from the pipeline that has the lane gates on (0.2.0), so the contract applies without a policy too.
        if case .untrusted(let why) = RuntimeTrust.verify(pythonBin: config.pythonBin, projectDir: config.projectDir, policy: policy, fileInfo: fileInfo) {
            return .runtimeUntrusted(why)
        }
        if let required = PipelineContract.required(policy: policy, sessionLocalOnly: true) {
            let have = versionProbe.version(pythonBin: config.pythonBin, projectDir: config.projectDir, runner: versionRunner)
            guard let seen = have, PipelineContract.satisfied(version: seen, required: required) else { return .pipelineTooOld(have: have, required: required) }
        }
        return nil
    }

    /// One enrollment with `code` as the person typed it. Returns at once; `completion` (on a background queue) hears the outcome after the
    /// notification was posted. A second call while one runs is refused (`.busy`). The code is checked for its shape first (printable ASCII,
    /// 1 to 64 characters, like the pipeline's own check), so that nothing but one line can reach the child's stdin.
    func connect(code raw: String, completion: ((Outcome) -> Void)? = nil) {
        lock.lock()
        let already = running
        if !already { running = true }
        lock.unlock()
        if already {
            // Not on `queue`: that one is busy with the running enrollment, and the answer is wanted now.
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Outcome.refused(.busy)
                self.report(outcome)
                completion?(outcome)
            }
            return
        }
        queue.async {
            let outcome = self.perform(code: raw)
            self.lock.lock(); self.running = false; self.lock.unlock()
            self.report(outcome)
            completion?(outcome)
        }
    }

    private func perform(code raw: String) -> Outcome {
        let policy = readPolicy()
        if let refusal = check(policy: policy) { return .refused(refusal) }
        guard let code = Self.normalizedCode(raw) else { return .failed(.malformedCode) }
        let pipelineDir = config.projectDir.appendingPathComponent("pipeline", isDirectory: true)
        let environment = PipelineLauncher.sanitizedEnvironment(from: baseEnvironment, policy: policy)
        Log.info("company server: enrollment started")
        let result = runner(config.pythonBin, Self.arguments, environment, pipelineDir, Data((code + "\n").utf8), timeout)
        let printed = Self.scrubbed(result.output, code: code)
        saveLog(result, printed: printed)
        return Self.classify(result, printed: printed)
    }

    /// app.log and the notification for an outcome (the one place that does both).
    func report(_ outcome: Outcome) {
        let policy = readPolicy()
        switch outcome {
        case .connected: Log.info("company server: enrollment finished (exit 0); this app never sees the token, the pipeline stored it")
        case .refused(let why): Log.warn("company server: not started: \(why.logText)")
        case .failed(let why): Log.warn("company server: enrollment failed (\(why)); see \(Self.logFileName)")
        }
        let log = logDir.appendingPathComponent(Self.logFileName)
        poster().post(Self.notification(for: outcome, contact: policy.supportContact, logFile: FileManager.default.fileExists(atPath: log.path) ? log : nil))
    }

    private func poster() -> NotificationPosting {
        if let notifier = notifier { return notifier }
        lock.lock(); defer { lock.unlock() }
        // The app's own notifier owns the click handler: this one has no router, so it posts and installs nothing.
        if ownNotifier == nil { ownNotifier = Notifier(router: nil) }
        return ownNotifier!
    }

    private func saveLog(_ result: RunResult, printed: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let header = "===== \(ShellUtil.iso8601(Date())) \(config.pythonBin.path) \(Self.arguments.joined(separator: " ")) =====\n"
        let tail = result.launched ? "exit status \(result.status)\(result.timedOut ? " (stopped after \(Int(timeout)) s)" : "")\n" : "could not be started\n"
        try? Data((header + printed + (printed.hasSuffix("\n") || printed.isEmpty ? "" : "\n") + tail).utf8).write(to: logDir.appendingPathComponent(Self.logFileName), options: .atomic)
    }

    // MARK: Pure helpers

    /// The code as the pipeline accepts it (`_CODE_SHAPE`): surrounding whitespace removed, then printable ASCII, 1 to 64 characters. nil = malformed.
    static func normalizedCode(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(text.utf8)
        guard (1...64).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return text
    }

    /// `text` without the code and without anything shaped like a token (`mcap1_...`) or an API key, cut to `limit` characters: the only form in
    /// which the output of the child is kept. The child never prints either, so this is the last line of defence, not the plan.
    static func scrubbed(_ text: String, code: String, limit: Int = 8_000) -> String {
        var out = text
        if !code.isEmpty { out = out.replacingOccurrences(of: code, with: "***") }
        out = out.replacingOccurrences(of: #"mcap1_[A-Za-z0-9_\-]+"#, with: "mcap1_\u{2026}", options: .regularExpression)
        return String(NotificationText.redact(out).prefix(limit))
    }

    /// The outcome of a child that ran: exit 0 is connected; otherwise the kind of failure from the child's fixed English messages
    /// (pipeline/mcap/cli.py `_asr_enroll`, asr_remote.py `enroll`), anything else is `.other`. Pure.
    static func classify(_ result: RunResult, printed: String) -> Outcome {
        guard result.launched else { return .failed(.couldNotStart) }
        if result.timedOut { return .failed(.timedOut) }
        if result.status == 0 { return .connected }
        let text = printed.lowercased()
        if text.contains("empty or malformed") { return .failed(.malformedCode) }
        if text.contains("code was refused") { return .failed(.codeRefused) }
        if text.contains("too many enrollment attempts") { return .failed(.throttled) }
        if text.contains("could not be reached") { return .failed(.unreachable) }
        if text.contains("not allowed for this server") {
            // "FAILED: enrollment is not allowed for this server (<reason>)": the reason of the decision table. A missing, mismatching, expired
            // or tampered CONSENT is the person's to fix (a Mac without a managed policy never had an organisation to point at).
            let reason = text.components(separatedBy: "not allowed for this server (").last?.components(separatedBy: ")").first ?? ""
            return .failed(reason.hasPrefix("no-consent") || reason.hasPrefix("consent-") ? .noConsent : .notAllowed)
        }
        if text.contains("private ca") { return .failed(.notAllowed) }
        return .failed(.other)
    }

    /// The notification of an outcome: fixed sentences in the UI language (the title 40, the subtitle 60 and the body 100 characters are never exceeded),
    /// the support contact only where the administrator can help. `kind` is the existing server-status kind (a kind of its own needs
    /// Notifier.swift); nothing of the child's output, the host or the code is in the text.
    static func notification(for outcome: Outcome, contact: String?, logFile: URL? = nil) -> AppNotification {
        var title = tr("Company server connection failed", ko: "회사 서버 연결 실패")
        let subtitle: String
        let lead: String
        var withContact = false
        var withLog = false
        var sound = true
        var summary = "company server enrollment: "
        switch outcome {
        case .connected:
            title = tr("Connected to the company server", ko: "회사 서버에 연결했어요")
            subtitle = tr("Enrollment is done", ko: "등록이 끝났어요")
            lead = tr("The credentials are stored only in this Mac's keychain. The app does not read them", ko: "인증 정보는 이 Mac의 키체인에만 저장돼요. 앱은 그 값을 읽지 않아요")
            sound = false
            summary += "connected"
        case .refused(let why):
            summary += "not started"
            switch why {
            case .notConfigured:
                subtitle = tr("No connection settings", ko: "연결 설정이 없어요")
                lead = tr("A company server address (ASR_REMOTE_URL) or a server consent in the organisation policy is needed", ko: "회사 서버 주소(ASR_REMOTE_URL)나 조직 정책의 서버 동의가 필요해요")
                withContact = true
            case .relayDenied(let denial):
                subtitle = tr("Blocked by organisation policy", ko: "조직 정책으로 막혀 있어요")
                lead = denial.reasonText
                withContact = true
            case .runtimeUntrusted:
                subtitle = tr("Untrusted runtime", ko: "신뢰할 수 없는 실행 환경이에요")
                lead = tr("It is not the install location the organisation set, so it did not connect", ko: "조직이 지정한 설치 위치가 아니라서 연결하지 않았어요")
                withContact = true
            case .pipelineTooOld:
                subtitle = tr("Pipeline update needed", ko: "파이프라인 업데이트가 필요해요")
                lead = tr("This feature needs a newer pipeline, so it did not connect", ko: "이 기능에는 새 파이프라인이 필요해서 연결하지 않았어요")
                withContact = true
            case .pythonMissing:
                subtitle = tr("Python or the pipeline is missing", ko: "Python 또는 파이프라인이 없어요")
                lead = tr("Check the installation (mcap doctor)", ko: "설치를 확인해 주세요 (mcap doctor)")
            case .busy:
                title = tr("Already connecting", ko: "이미 연결 중이에요")
                subtitle = tr("Please wait a moment", ko: "잠시 기다려 주세요")
                lead = tr("The company server connection is still in progress", ko: "회사 서버 연결이 아직 진행 중이에요")
                sound = false
            }
        case .failed(let why):
            summary += "failed (\(why))"
            switch why {
            case .malformedCode:
                subtitle = tr("The enrollment code has the wrong format", ko: "등록 코드 형식이 맞지 않아요")
                lead = tr("Paste the code from your administrator as it is (no spaces, 64 characters at most)", ko: "관리자가 준 코드를 그대로 붙여 넣어 주세요 (공백 없이 64자 이하)")
            case .codeRefused:
                subtitle = tr("Check the enrollment code", ko: "등록 코드를 확인하세요")
                lead = tr("The code is wrong, already used or expired. Ask your administrator for a new one", ko: "코드가 맞지 않거나 이미 썼거나 만료됐어요. 관리자에게 새 코드를 요청하세요")
            case .throttled:
                subtitle = tr("Too many attempts", ko: "시도가 너무 많아요")
                lead = tr("Try again in a moment. If the code was used, ask your administrator for a new one", ko: "잠시 뒤에 다시 시도하세요. 코드가 쓰였다면 관리자에게 새 코드를 요청하세요")
            case .unreachable:
                subtitle = tr("Cannot reach the server", ko: "서버에 연결할 수 없어요")
                lead = tr("Check the network and VPN. If the code was used, ask your administrator for a new one", ko: "네트워크와 VPN을 확인하세요. 코드가 쓰였다면 관리자에게 새 코드를 요청하세요")
            case .notAllowed:
                subtitle = tr("This server is not allowed", ko: "이 서버는 허용되지 않았어요")
                lead = tr("Check the organisation policy, the server consent or the server certificate (CA) setting", ko: "조직 정책, 서버 동의 또는 서버 인증서(CA) 설정을 확인하세요")
                withContact = true
            case .noConsent:
                subtitle = tr("No consent for this server", ko: "이 서버에 대한 동의가 없어요")
                lead = tr("The consent is missing or expired. Give it in Terminal with mcap asr-engines consent remote, or ask your administrator", ko: "동의가 없거나 만료됐어요. 터미널에서 mcap asr-engines consent remote 로 동의하거나 관리자에게 물어보세요")
                withContact = true
            case .timedOut:
                subtitle = tr("The server did not answer", ko: "서버가 응답하지 않아요")
                lead = tr("Stopped after the time limit. If the code was used, ask your administrator for a new one", ko: "시간이 지나 중단했어요. 코드가 쓰였다면 관리자에게 새 코드를 요청하세요")
                withLog = true
            case .couldNotStart:
                subtitle = tr("Could not start Python", ko: "Python을 시작하지 못했어요")
                lead = tr("Check the installation (mcap doctor)", ko: "설치를 확인해 주세요 (mcap doctor)")
                withLog = true
            case .other:
                subtitle = tr("Could not connect", ko: "연결하지 못했어요")
                lead = tr("Cause unknown · log: \(logFileName)", ko: "원인을 알 수 없어요 · 로그: \(logFileName)")
                withLog = true
            }
        }
        let action: NotificationClickAction = (withLog ? logFile.map { NotificationClickAction.openLog($0.path) } : nil) ?? NotificationClickAction.none
        return AppNotification(kind: .waitingForServer, title: title, subtitle: subtitle,
                               body: NotificationText.fit(lead, tail: withContact ? contact.map(NotificationText.contactTail) : nil),
                               identifier: notificationIdentifier, sound: sound, level: .active, action: action, summary: summary)
    }

    // MARK: The child

    /// The real runner: the child with a pipe for stdin (the code and a newline, then closed), stdout and stderr in one pipe read to its end
    /// (at most `maxOutputBytes` kept), stopped after `timeout` seconds (SIGTERM, SIGKILL five seconds later).
    static func runChild(_ python: URL, _ arguments: [String], _ environment: [String: String], _ cwd: URL, _ stdin: Data, _ timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.qualityOfService = .userInitiated
        let input = Pipe(), output = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)      // a child that exits without reading must not kill the app
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return RunResult(launched: false, status: -1, timedOut: false, output: "") }
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()

        final class Box {
            private let lock = NSLock()
            private var data = Data()
            private var stopped = false
            func add(_ chunk: Data) {
                lock.lock(); defer { lock.unlock() }
                if data.count < CompanyServerConnect.maxOutputBytes { data.append(chunk.prefix(CompanyServerConnect.maxOutputBytes - data.count)) }
            }
            var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
            func markStopped() { lock.lock(); stopped = true; lock.unlock() }
            var wasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        }
        let box = Box()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                box.add(chunk)
            }
            reading.leave()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            box.markStopped()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        process.waitUntilExit()
        _ = reading.wait(timeout: .now() + 5)                 // a grandchild that keeps the pipe open must not hold the menu
        return RunResult(launched: true, status: process.terminationStatus, timedOut: box.wasStopped, output: box.text)
    }
}

// MARK: - The calendar command (gcal upcoming)

/// What one `python -m mcap gcal upcoming ...` run left behind. Only stdout counts (the contract: exactly one JSON object, exit status 0 even
/// for an error answer); stderr is dropped so that nothing a library prints can ever mix into the JSON.
struct CalendarCommandResult: Equatable {
    var launched: Bool
    var status: Int32
    var timedOut: Bool
    var output: String
    /// Nothing was started and why (no path, no meeting content): python or the pipeline is missing, or the runtime is not the trusted one.
    var refusal: String? = nil
}

extension PipelineLauncher {
    /// The hard limit of one run (then SIGTERM, SIGKILL five seconds later): the Google call has its own shorter timeouts, this is the net.
    static let calendarCommandTimeout: TimeInterval = 20
    /// stdout beyond this is read and thrown away (a child that floods the pipe must not stall, and must not fill memory either).
    static let calendarOutputLimit = 262_144

    /// The contract of the calendar package: `--from-minutes` = how far back, `--to-minutes` = how far ahead.
    static func calendarCommandArguments(fromMinutes: Int, toMinutes: Int) -> [String] {
        return ["-m", "mcap", "gcal", "upcoming", "--from-minutes", String(fromMinutes), "--to-minutes", String(toMinutes)]
    }

    /// Runs the calendar command with the same python, the same working directory and the same clean environment as every pipeline job
    /// (`sanitizedEnvironment`: nothing is inherited), after the same runtime-trust check. BLOCKS until the child ended or `timeout` passed: call it
    /// from a background queue, one run at a time (the CalendarWatcher does). The command reads and writes the Google token in the Keychain
    /// itself; this app never sees it.
    static func runCalendarCommand(config: AppConfig, policy: OrgPolicy, fromMinutes: Int, toMinutes: Int,
                                   timeout: TimeInterval = calendarCommandTimeout,
                                   environment base: [String: String] = ProcessInfo.processInfo.environment,
                                   fileInfo: (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile) -> CalendarCommandResult {
        func refused(_ why: String) -> CalendarCommandResult { CalendarCommandResult(launched: false, status: -1, timedOut: false, output: "", refusal: why) }
        let fm = FileManager.default
        let pipelineDir = config.projectDir.appendingPathComponent("pipeline", isDirectory: true)
        guard fm.isExecutableFile(atPath: config.pythonBin.path) else { return refused("python is missing") }
        guard fm.fileExists(atPath: pipelineDir.appendingPathComponent("mcap").path) else { return refused("the pipeline package is missing") }
        if case .untrusted(let why) = RuntimeTrust.verify(pythonBin: config.pythonBin, projectDir: config.projectDir, policy: policy, fileInfo: fileInfo) {
            return refused("the runtime is not trusted (\(why))")
        }

        let process = Process()
        process.executableURL = config.pythonBin
        process.arguments = calendarCommandArguments(fromMinutes: fromMinutes, toMinutes: toMinutes)
        process.currentDirectoryURL = pipelineDir
        process.environment = sanitizedEnvironment(from: base, policy: policy)
        process.qualityOfService = .utility
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return CalendarCommandResult(launched: false, status: -1, timedOut: false, output: "", refusal: "python could not be started") }

        final class Box {
            private let lock = NSLock()
            private var data = Data()
            private var stopped = false
            func add(_ chunk: Data) {
                lock.lock(); defer { lock.unlock() }
                if data.count < PipelineLauncher.calendarOutputLimit { data.append(chunk.prefix(PipelineLauncher.calendarOutputLimit - data.count)) }
            }
            var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
            func markStopped() { lock.lock(); stopped = true; lock.unlock() }
            var wasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        }
        let box = Box()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                box.add(chunk)
            }
            reading.leave()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            box.markStopped()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        process.waitUntilExit()
        _ = reading.wait(timeout: .now() + 5)                 // a grandchild that keeps the pipe open must not hold the watcher
        return CalendarCommandResult(launched: true, status: process.terminationStatus, timedOut: box.wasStopped, output: box.text)
    }
}

// MARK: - What a session left behind (read-only)

/// Pure readers of the two files the notification texts need. state.json is written only by Python and session.json only by the
/// recorder; nothing here writes.
enum PipelineFacts {
    /// "platform" and the length (end_time - start_time) of a recording from its session.json; nil without a readable session.json.
    static func recording(in dir: URL) -> (platform: Platform?, durationSeconds: Double?)? {
        guard let json = ShellUtil.readJSON(dir.appendingPathComponent("session.json")) else { return nil }
        let platform = (json["platform"] as? String).flatMap { Platform(rawValue: $0) }
        var seconds: Double?
        if let start = (json["start_time"] as? String).flatMap(ShellUtil.parseISO8601),
           let end = (json["end_time"] as? String).flatMap(ShellUtil.parseISO8601), end >= start {
            seconds = end.timeIntervalSince(start)
        }
        return (platform, seconds)
    }

    private static func folderExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Facts about `session` (a staging folder name, or the name of a job such as "retry-sweep"):
    ///  * the staging folder `sessionsDir/<session>` and its state.json (a live staging state, or the tombstone left after publish),
    ///  * `finalDir` (what the success event carries) or state.json's final_dir: the published folder, when it exists,
    ///  * session.json of the published folder, else of the staging folder (platform, length),
    ///  * error_kind / retryable / resets_at from state.json (the staging copy, else the one inside the published folder).
    /// `folder` is where a click should lead: the published folder, else the staging folder, else nil.
    static func outcome(session: String, sessionsDir: URL, finalDir: URL?, logDir: URL) -> PipelineOutcome {
        var o = PipelineOutcome()
        let staging = sessionsDir.appendingPathComponent(session, isDirectory: true)
        let hasStaging = !session.isEmpty && !session.contains("/") && folderExists(staging)
        let stagingState = hasStaging ? ShellUtil.readJSON(staging.appendingPathComponent("state.json")) : nil
        let stateFinal = (stagingState?["final_dir"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let published = [finalDir, stateFinal].compactMap { $0 }.first { folderExists($0) }
        o.folder = published ?? (hasStaging ? staging : nil)
        if let rec = published.flatMap({ recording(in: $0) }) ?? (hasStaging ? recording(in: staging) : nil) {
            o.platform = rec.platform
            o.durationSeconds = rec.durationSeconds
        }
        let state = stagingState ?? published.flatMap { ShellUtil.readJSON($0.appendingPathComponent("state.json")) }
        if let kind = state?["error_kind"] as? String, !kind.isEmpty { o.errorKind = kind }
        o.retryable = state?["retryable"] as? Bool
        o.resetsAt = (state?["resets_at"] as? String).flatMap(ShellUtil.parseISO8601)
        // SPEC 18: state.json `local_only` and `lanes` ({"llm": "skipped:local_only", ...}); only read here, Python writes them.
        o.localOnly = PipelineLauncher.booleanValue(state?["local_only"])
        if let lanes = state?["lanes"] as? [String: Any] {
            o.lanesSkipped = lanes.compactMap { lane, value in (value as? String)?.hasPrefix("skipped") == true ? lane : nil }.sorted()
        }
        if let name = PipelineLauncher.logFileName(forSession: session) { o.logFile = logDir.appendingPathComponent(name) }
        return o
    }
}
