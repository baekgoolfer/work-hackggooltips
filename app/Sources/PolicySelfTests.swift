import Foundation
import Darwin

// =====================================================================================
// `<short name> selftest-policy`: device-free tests of the organisation-policy core (Policy.swift, LogRotation.swift, the policy
// parts of Config.swift and Setup.swift). W6a hooks `runPolicySelfTests()` into selftest-session as well.
//
// No microphone, no Keychain, no network, no real policy folder: file info is injected, everything else happens in a temp directory
// (honours $TMPDIR). The shared corpus config/policy-fixtures is read from $MC_POLICY_FIXTURES or ./config/policy-fixtures (the repo
// root; or, when the binary sits in <repo>/build, from the repo it was built in). A missing corpus is a FAIL, never a skip: a test
// that cannot find its fixtures proves nothing. The same corpus is read by pipeline/tests/test_policy.py, so the Python and the Swift
// reader cannot drift apart without one of the two failing.
// =====================================================================================

private var passed = 0
private var failed = 0

private func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(name)\(d.isEmpty ? "" : "  -> \(d)")")
    }
}

private func section(_ title: String) { print("\n== \(title)") }

// MARK: - Entry points

/// The command: runs everything and answers with an exit code (0 only if every check passed). app.log of the run goes to the temp dir.
func runSelftestPolicy() -> Int32 {
    let savedLog = Log.fileURL
    let savedEcho = Log.echoToStderr
    let tmpRoot = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
    let logDir = URL(fileURLWithPath: tmpRoot, isDirectory: true).standardizedFileURL.appendingPathComponent("mcap-selftest-policy-log-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    Log.fileURL = logDir.appendingPathComponent("app.log")
    Log.echoToStderr = false
    defer { Log.flush(); Log.fileURL = savedLog; Log.echoToStderr = savedEcho; try? FileManager.default.removeItem(at: logDir) }
    let result = runPolicySelfTests()
    print("")
    if result.fail == 0 {
        print("selftest-policy: PASS (\(result.pass) checks)")
        return 0
    }
    print("selftest-policy: FAIL (\(result.fail) failed, \(result.pass) passed)")
    return 1
}

/// Runs every check of this file and returns the counts. Self-contained: it makes and removes its own temp directory and leaves no
/// environment variable or global changed, so selftest-session can call it in the middle of its own run.
func runPolicySelfTests() -> (pass: Int, fail: Int) {
    L10n.current = .ko                      // the texts asserted here are the Korean ones (UI_LANGUAGE=ko)
    passed = 0
    failed = 0
    let tmpRoot = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
    let base = URL(fileURLWithPath: tmpRoot, isDirectory: true).standardizedFileURL.appendingPathComponent("mcap-selftest-policy-\(getpid())", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: base)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    print("selftest-policy: temp dir \(base.path)")

    section("this Mac")
    check(!OrgPolicy.systemPolicyPresent(), "no system policy on this Mac (the self test assumes the personal install; its env hooks must be honoured)")

    testStrictJSON()
    let fixtures = loadFixtures()
    check(fixtures != nil, "the shared corpus config/policy-fixtures is found (MC_POLICY_FIXTURES or ./config/policy-fixtures)",
          "cwd \(fm.currentDirectoryPath), MC_POLICY_FIXTURES=\(ProcessInfo.processInfo.environment["MC_POLICY_FIXTURES"] ?? "(unset)")")
    if let fx = fixtures {
        testPolicyCorpus(fx, base: base)
        testArchiveRootCorpus(fx, base: base)
        testDriftGuards(fx)
    }
    testPolicyReading(base)
    testPolicyLayers(base)
    testPrivacySettings()
    testArchiveAndLocalArchive(base)
    testLocalOnlyResolver()
    testEffectiveLanes()
    testPipelineContract(base)
    testRuntimeTrust(base)
    testSessionJSONPatch(base)
    testSessionPrivateLog(base)
    testLogRotation(base)
    testSetupLaneAware(base)
    testPolicyStatus(base)

    Log.flush()
    if failed == 0 { try? fm.removeItem(at: base) } else { print("selftest-policy: files kept in \(base.path)") }
    return (passed, failed)
}

// MARK: - Helpers

private func pol(_ json: String, version: String? = nil) -> OrgPolicy { OrgPolicy.parse(Data(json.utf8), pipelineVersion: version) }

private func hexData(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
        data.append(UInt8(s[i..<j], radix: 16) ?? 0)
        i = j
    }
    return data
}

private func readJSONObject(_ url: URL) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func makeDir(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

private func write(_ text: String, to url: URL, mode: Int = 0o644) {
    makeDir(url.deletingLastPathComponent())
    try? text.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// Runs `body` with an environment variable set, then puts the old value back.
private func withEnv(_ name: String, _ value: String, _ body: () -> Void) {
    let old = getenv(name).map { String(cString: $0) }
    setenv(name, value, 1)
    body()
    if let o = old { setenv(name, o, 1) } else { unsetenv(name) }
}

private let rootFile = OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: 0, mode: 0o644, size: 100)
private let rootDirectory = OrgPolicy.FileInfo(isRegular: false, isSymlink: false, uid: 0, mode: 0o755, size: 0)

// MARK: - Strict JSON

private func testStrictJSON() {
    section("strict JSON reader (the policy is not read through JSONSerialization)")
    func parse(_ text: String) -> (PolicyJSON.Value?, String?) {
        do { return (try PolicyJSON.parse(text), nil) } catch let f as PolicyJSON.Failure { return (nil, f.code) } catch { return (nil, "other") }
    }
    func code(_ text: String) -> String? { parse(text).1 }

    check(code("{\"a\":1,\"a\":2}") == "duplicate-key", "a duplicate key is rejected (JSONSerialization would keep the last)")
    check(code("{\"ext\":{\"x\":{\"k\":1,\"k\":2}}}") == "duplicate-key", "... at any depth, also inside ext")
    check(code("{\"ext\":{\"\\u00e9\":1,\"e\\u0301\":2}}") == nil, "keys that differ only in Unicode normalisation are two keys (Python compares code points)")
    check(code("{\"a\":1,\"a\":2,") == "bad-json", "a syntax error further on wins over a duplicate (Python judges a duplicate when the object closes)")
    for bad in ["NaN", "Infinity", "-Infinity", "{\"x\":NaN}", "[1e999]", "{\"x\":-1e999}", "01", "1.", ".5", "+1", "[1,]", "{\"a\":1,}", "{'a':1}", "\"\u{01}\"", "[", "{\"a\"}", "tru", "nul",
                "\"\\x41\"", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "1 2", "[] []", ""] {
        check(code(bad) == "bad-json", "bad JSON refused: \(bad.debugDescription)", "\(parse(bad))")
    }
    check(code(" \t\r\n{\"a\":[1,2.5,-0,1e3,true,false,null,\"x\"]}\n ") == nil, "JSON whitespace around and inside is fine")
    check(code("\u{00A0}{}") == "bad-json", "a no-break space is not JSON whitespace")
    check(code(String(repeating: "[", count: 200) + String(repeating: "]", count: 200)) == "bad-json", "nesting deeper than the limit is refused (closed direction)")
    check(code(String(repeating: "[", count: 100) + String(repeating: "]", count: 100)) == nil, "... 100 levels are fine")

    func value(_ text: String) -> PolicyJSON.Value? { parse(text).0 }
    if case .int(let n)? = value("1") { check(n == 1, "1 is an integer") } else { check(false, "1 is an integer") }
    if case .double(let d)? = value("1.0") { check(d == 1.0, "1.0 is a float (not the integer 1)") } else { check(false, "1.0 is a float") }
    if case .double? = value("1e2") { check(true, "1e2 is a float") } else { check(false, "1e2 is a float") }
    if case .bool(true)? = value("true") { check(true, "true is a bool (not the number 1)") } else { check(false, "true is a bool") }
    if case .int(let n)? = value("-0") { check(n == 0, "-0 is the integer 0") } else { check(false, "-0 is the integer 0") }
    if case .bigInt(let negative)? = value("99999999999999999999") { check(!negative, "a huge integer keeps its sign") } else { check(false, "a huge integer is a bigInt") }
    if case .bigInt(let negative)? = value("-99999999999999999999") { check(negative, "a huge negative integer keeps its sign") } else { check(false, "a huge negative integer is a bigInt") }
    if case .string(let s)? = value("\"a\\u00e9\\ud83d\\ude00\\n\\/\"") { check(s == "aé😀\n/", "escapes, a surrogate pair and \\/ decode", s) } else { check(false, "escapes decode") }
    if case .object(let members)? = value("{\"b\":1,\"a\":2}") { check(members.map { $0.key } == ["b", "a"], "members keep the document order") } else { check(false, "object order") }
}

// MARK: - Fixtures

private struct Fixtures {
    let dir: URL
    let index: [String: Any]
}

private func loadFixtures() -> Fixtures? {
    let env = ProcessInfo.processInfo.environment
    var candidates: [URL] = []
    if let explicit = env["MC_POLICY_FIXTURES"], !explicit.isEmpty {
        candidates.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true))
    } else {
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("config/policy-fixtures", isDirectory: true))
        // <repo>/build/MeetingCapture.app/Contents/MacOS/MeetingCapture -> <repo>
        var exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<5 { exe.deleteLastPathComponent() }
        candidates.append(exe.appendingPathComponent("config/policy-fixtures", isDirectory: true))
    }
    for dir in candidates {
        if let data = FileManager.default.contents(atPath: dir.appendingPathComponent("index.json").path),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return Fixtures(dir: dir, index: object)
        }
    }
    return nil
}

/// Every case of config/policy-fixtures/index.json: the verdict pipeline/tests/test_policy.py reaches too.
private func testPolicyCorpus(_ fx: Fixtures, base: URL) {
    section("shared policy corpus (config/policy-fixtures/index.json): the same verdicts as the Python reader")
    guard let defaults = fx.index["defaults"] as? [String: Any], let cases = fx.index["cases"] as? [[String: Any]],
          let reasonCodes = fx.index["reason_codes"] as? [String] else {
        check(false, "index.json has defaults, cases and reason_codes")
        return
    }
    check(fx.index["schema"] as? Int == 1 && cases.count >= 80, "index.json: schema 1 and at least 80 cases", "\(cases.count) cases")
    let baseline = defaults["company_baseline_enforced"] as? [String: String] ?? [:]
    check(baseline == OrgPolicy.companyBaselineEnforced, "the company baseline of the corpus is the one in the code")
    let invalidExpect = defaults["invalid_expect"] as? [String: Any] ?? [:]
    let defaultFileInfo = defaults["file_info"] as? [String: Any] ?? [:]
    let defaultAncestor = defaults["ancestor_info"] as? [String: Any] ?? [:]
    let work = base.appendingPathComponent("corpus", isDirectory: true)
    var seen = Set<String>()
    var bad = 0
    func octal(_ any: Any?) -> UInt16 { UInt16((any as? String) ?? "0", radix: 8) ?? 0 }

    for row in cases {
        let id = row["id"] as? String ?? "?"
        var problems: [String] = []
        if !seen.insert(id).inserted { problems.append("duplicate case id") }
        let expect = row["expect"] as? [String: Any] ?? [:]
        let wantState = expect["state"] as? String ?? "?"

        // the exact bytes of policy.json
        var data: Data? = nil
        var hasFile = true
        if let content = row["content"] as? String {
            data = Data(content.utf8)
        } else if let hex = row["content_hex"] as? String {
            data = hexData(hex)
        } else if let file = row["file"] as? String {
            data = FileManager.default.contents(atPath: fx.dir.appendingPathComponent(file).path)
            if data == nil { problems.append("fixture file \(file) is missing") }
        } else {
            hasFile = false                                         // "file": null = no policy.json
        }
        if var bytes = data {
            if let strip = row["strip_prefix_hex"] as? String {
                let lead = hexData(strip)
                if bytes.starts(with: lead) { bytes.removeFirst(lead.count) } else { problems.append("strip_prefix_hex is not at the start") }
            }
            if let prefix = row["prefix_hex"] as? String { bytes = hexData(prefix) + bytes }
            if let append = row["append_hex"] as? String { bytes.append(hexData(append)) }
            if let cut = row["truncate_to"] as? Int { bytes = bytes.prefix(cut) }
            data = bytes
        }
        let dir = work.appendingPathComponent(id, isDirectory: true)
        makeDir(dir)
        let policyURL = dir.appendingPathComponent("policy.json")
        let markerURL = dir.appendingPathComponent("policy.required")
        if hasFile, let bytes = data { try? bytes.write(to: policyURL) }

        // what lstat reports
        let fileSpec = (defaultFileInfo).merging(row["file_info"] as? [String: Any] ?? [:]) { _, new in new }
        let ancestorSpec = (defaultAncestor).merging(row["ancestor_info"] as? [String: Any] ?? [:]) { _, new in new }
        let type = fileSpec["type"] as? String ?? "file"
        let fileInfo = OrgPolicy.FileInfo(isRegular: type == "file", isSymlink: type == "symlink", uid: UInt32(fileSpec["uid"] as? Int ?? 0), mode: octal(fileSpec["mode"]),
                                          size: fileSpec["size"] as? Int ?? data?.count ?? 0, statError: type == "error")
        let ancestorType = ancestorSpec["type"] as? String ?? "directory"
        let ancestorInfo = OrgPolicy.FileInfo(isRegular: ancestorType == "file", isSymlink: ancestorType == "symlink", uid: UInt32(ancestorSpec["uid"] as? Int ?? 0),
                                              mode: octal(ancestorSpec["mode"]), size: 0)
        let marker = row["marker"] as? Bool ?? (defaults["marker"] as? Bool ?? false)
        let version = row["pipeline_version"] as? String ?? defaults["pipeline_version"] as? String
        let policy = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { url in
            if url.path == policyURL.path { return hasFile ? fileInfo : nil }
            if url.path == markerURL.path { return marker ? rootFile : nil }
            return ancestorInfo
        }, retryAfterMs: 0, pipelineVersion: version)

        // the verdict
        let gotState: String
        switch policy.state { case .absent: gotState = "absent"; case .valid: gotState = "valid"; case .invalid: gotState = "invalid" }
        if gotState != wantState { problems.append("state \(gotState) (\(policy.lockedReason ?? "-")), expected \(wantState)") }
        var want = expect
        if wantState == "invalid" { want = invalidExpect.merging(expect) { _, new in new } }
        if wantState == "invalid", let reason = expect["reason"] as? String {
            if !(policy.lockedReason ?? "").contains(reason) { problems.append("reason '\(policy.lockedReason ?? "-")' lacks '\(reason)'") }
            if !reasonCodes.contains(reason) { problems.append("reason \(reason) is not in reason_codes") }
        } else if wantState != "invalid", policy.lockedReason != nil {
            problems.append("a lock reason on a policy that is not locked")
        }
        if let lanes = want["lanes"] as? [String: String], policy.lanes != lanes { problems.append("lanes \(policy.lanes)") }
        if let v = want["local_only_default"] as? Bool, policy.localOnlyDefault != v { problems.append("local_only_default \(policy.localOnlyDefault)") }
        if let v = want["local_only_locked"] as? Bool, policy.localOnlyLocked != v { problems.append("local_only_locked \(policy.localOnlyLocked)") }
        if let v = want["recording_enabled"] as? Bool, policy.recordingEnabled != v { problems.append("recording_enabled \(policy.recordingEnabled)") }
        if let v = want["profile"] as? String, policy.profile != v { problems.append("profile \(policy.profile)") }
        if let v = want["revision"] as? Int, policy.revision != v { problems.append("revision \(String(describing: policy.revision))") }
        for (key, got) in [("allowed_engines", policy.allowedEngines), ("allowed_hosts", policy.allowedHosts), ("archive_allowed_roots", policy.archiveAllowedRoots)] where expect.keys.contains(key) {
            let wanted = expect[key] as? [String]            // NSNull = nil = no restriction
            if got != wanted { problems.append("\(key) \(String(describing: got))") }
        }
        if expect.keys.contains("local_roots"), policy.localRoots != (expect["local_roots"] as? [String] ?? []) { problems.append("local_roots \(policy.localRoots)") }
        for (lane, reason) in expect["lane_reasons"] as? [String: String] ?? [:] where policy.laneReasons[lane] != reason {
            problems.append("lane_reasons[\(lane)] \(policy.laneReasons[lane] ?? "nil")")
        }
        if let enforced = expect["enforced"] as? [String: String] {
            if policy.enforced != enforced { problems.append("enforced \(policy.enforced)") }
        } else if wantState == "absent" {
            if !policy.enforced.isEmpty { problems.append("enforced \(policy.enforced)") }
        } else if wantState == "invalid" {
            if policy.enforced != baseline { problems.append("enforced \(policy.enforced): a lock keeps the company baseline") }
        }
        if wantState == "invalid" && (policy.lanes.values.contains("allow") || !policy.defaults.isEmpty) { problems.append("a locked policy opens a lane or carries defaults") }
        if !problems.isEmpty {
            bad += 1
            check(false, "corpus case \(id)", problems.joined(separator: "; "))
        }
    }
    check(bad == 0, "all \(cases.count) corpus cases give the expected verdict", "\(bad) differ")
    let expectedCodes = Set(cases.compactMap { ($0["expect"] as? [String: Any]).flatMap { $0["state"] as? String == "invalid" ? $0["reason"] as? String : nil } })
    let uncovered = Set(fx.index["reason_codes_without_a_case"] as? [String] ?? [])
    check(Set(reasonCodes).subtracting(expectedCodes) == uncovered, "every reason code has a case except the ones the index says have none",
          "\(Set(reasonCodes).subtracting(expectedCodes).subtracting(uncovered))")
    var longest = 0
    for code in reasonCodes { longest = max(longest, OrgPolicy.reasonText(forCode: code).count) }
    check(longest <= 20 && longest > 0, "the Korean short reason of every code has at most 20 characters", "\(longest)")
    check(OrgPolicy.reasonText(forCode: "unknown-key") == pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1}").lockedReasonText, "lockedReasonText maps the code of the lock reason")
}

private func testArchiveRootCorpus(_ fx: Fixtures, base: URL) {
    section("shared archive-root cases (config/policy-fixtures/archive_roots_cases.json), also from another working directory")
    guard let data = FileManager.default.contents(atPath: fx.dir.appendingPathComponent("archive_roots_cases.json").path),
          let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let cases = doc["cases"] as? [[String: Any]],
          let home = doc["home"] as? String else {
        check(false, "archive_roots_cases.json is readable")
        return
    }
    // A working directory that looks like the relative roots and paths of the cases: they must STILL match nothing.
    let cwd = base.appendingPathComponent("cwd-trap", isDirectory: true)
    for sub in ["Library/CloudStorage/GoogleDrive-user@example.com/Shared drives/Meetings", "Meetings", "Library/CloudStorage/x", "alice/x"] { makeDir(cwd.appendingPathComponent(sub)) }
    let savedCwd = FileManager.default.currentDirectoryPath
    var bad = 0
    for run in 0..<2 {
        if run == 1 { _ = FileManager.default.changeCurrentDirectoryPath(cwd.path) }
        for row in cases {
            let id = row["id"] as? String ?? "?"
            let path = row["path"] as? String ?? ""
            let expected = row["expect"] as? Bool ?? false
            let got: Bool
            if let roots = row["roots"] as? [String] { got = ArchiveRootMatcher.matches(path: path, roots: roots, home: home) }
            else { got = ArchiveRootMatcher.allows(path: path, roots: nil, home: home) }
            if got != expected {
                bad += 1
                check(false, "archive root case \(id) (cwd run \(run))", "got \(got), expected \(expected)")
            }
        }
    }
    _ = FileManager.default.changeCurrentDirectoryPath(savedCwd)
    check(bad == 0, "all \(cases.count) archive-root cases agree with Python, from two working directories", "\(bad) differ")
    check(!ArchiveRootMatcher.matches(path: "/Users/alice/Meetings", roots: ["~/Meetings"], home: "relative-home"), "a relative HOME makes a ~ root match nothing")
}

/// The Swift constants that mirror Python lists are compared with the Python source: a list that drifted would let one reader lock a
/// policy the other reads as valid (or the other way round).
private func testDriftGuards(_ fx: Fixtures) {
    section("Swift constants against pipeline/mcap/policy.py and config.py")
    let repo = fx.dir.deletingLastPathComponent().deletingLastPathComponent()
    let policyPy = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/policy.py"), encoding: .utf8)) ?? ""
    let configPy = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/config.py"), encoding: .utf8)) ?? ""
    check(!policyPy.isEmpty && !configPy.isEmpty, "pipeline/mcap/policy.py and config.py are readable next to the corpus", repo.path)
    func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    func quoted(_ text: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "\"([A-Za-z0-9_]+)\"") else { return [] }
        return Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
    }
    if let block = firstMatch("DEFAULTS_WHITELIST = frozenset\\(\"\"\"(.*?)\"\"\"", in: policyPy) {
        let python = Set(block.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        check(python == PolicyLayers.whitelist, "PolicyLayers.whitelist is DEFAULTS_WHITELIST of policy.py",
              "only Python: \(python.subtracting(PolicyLayers.whitelist).sorted()), only Swift: \(PolicyLayers.whitelist.subtracting(python).sorted())")
    } else { check(false, "DEFAULTS_WHITELIST is found in policy.py") }
    if let block = firstMatch("FORBIDDEN_LAYER_KEYS = frozenset\\(\\[(.*?)\\]\\)", in: policyPy) {
        check(quoted(block) == PolicyLayers.forbiddenKeys, "PolicyLayers.forbiddenKeys is FORBIDDEN_LAYER_KEYS of policy.py")
    } else { check(false, "FORBIDDEN_LAYER_KEYS is found in policy.py") }
    if let block = firstMatch("CHILD_ENV_ALLOWED = \\((.*?)\\)\\n", in: policyPy) {
        check(quoted(block) == OrgPolicy.childEnvNames, "OrgPolicy.childEnvNames is CHILD_ENV_ALLOWED of policy.py")
    } else { check(false, "CHILD_ENV_ALLOWED is found in policy.py") }
    if let block = firstMatch("TEST_HOOK_ENV = \\((.*?)\\)\\n", in: configPy) {
        check(quoted(block) == Set(OrgPolicy.testHookNames), "OrgPolicy.testHookNames is TEST_HOOK_ENV of config.py")
    } else { check(false, "TEST_HOOK_ENV is found in config.py") }
    if let block = firstMatch("POLICY_IGNORED_KEYS = \\((.*?)\\)\\n", in: configPy) {
        check(quoted(block) == Set(OrgPolicy.ignoredConfigKeys), "OrgPolicy.ignoredConfigKeys is POLICY_IGNORED_KEYS of config.py")
    } else { check(false, "POLICY_IGNORED_KEYS is found in config.py") }
    check(Set(OrgPolicy.lanesInOrder) == Set(["asr_remote", "asr_cloud", "llm", "calendar", "drive"]) && (firstMatch("\\nLANES = \\((.*?)\\)\\n", in: policyPy).map(quoted) ?? []) == Set(OrgPolicy.lanesInOrder),
          "the five lanes are those of policy.py")

    // ASR_ENGINE / ASR_FALLBACK words: the tuples of policy.py, with the providers of asr_providers.py where policy.py splices in *asr_providers.PROVIDERS.
    // A word the app does not know is read as whisper, and the menu would say that nothing leaves this Mac while the pipeline sends audio.
    let providersPy = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/asr_providers.py"), encoding: .utf8)) ?? ""
    var providerNames: [String] = []
    if let re = try? NSRegularExpression(pattern: "\\bProvider\\(\\s*name=\"([a-z0-9-]+)\"", options: [.dotMatchesLineSeparators]) {
        providerNames = re.matches(in: providersPy, range: NSRange(providersPy.startIndex..., in: providersPy)).compactMap { m in Range(m.range(at: 1), in: providersPy).map { String(providersPy[$0]) } }
    }
    check(providerNames.count >= 2 && providerNames.contains("clova") && providerNames.contains("openai-compat"), "the providers of asr_providers.py are found", "\(providerNames)")
    func choiceWords(_ name: String) -> [String]? {
        guard let block = firstMatch("\\n\(name) = \\(([^)\\n]*)\\)", in: policyPy) else { return nil }
        return block.split(separator: ",").flatMap { part -> [String] in
            let token = part.trimmingCharacters(in: .whitespaces)
            return token.hasPrefix("*asr_providers.PROVIDERS") ? providerNames : [token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))]
        }
    }
    for (name, swiftWords) in [("ASR_ENGINE_CHOICES", PrivacySettings.engineWords), ("ASR_FALLBACK_CHOICES", PrivacySettings.fallbackWords)] {
        let python = choiceWords(name) ?? []
        check(!python.isEmpty && Set(python) == Set(swiftWords) && python.count == swiftWords.count,
              "PrivacySettings.\(name == "ASR_ENGINE_CHOICES" ? "engineWords" : "fallbackWords") is \(name) of policy.py",
              "only Python: \(Set(python).subtracting(swiftWords).sorted()), only Swift: \(Set(swiftWords).subtracting(python).sorted())")
    }

    // Number rules of the layer values: every whitelisted key that config.py casts with int / float / _number(...) has the same rule here.
    guard let re = try? NSRegularExpression(pattern: "\"([A-Z_]+)\": \\(\"[a-z_]+\", (_number\\((int|float)(?:, ([0-9.]+))?(, exclusive=True)?(?:, maximum=([0-9.]+))?\\)|int|float)\\)") else { return }
    var pythonRules: [String: LayerValue.Rule] = [:]
    for m in re.matches(in: configPy, range: NSRange(configPy.startIndex..., in: configPy)) {
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: configPy).map { String(configPy[$0]) } }
        guard let key = group(1), PolicyLayers.whitelist.contains(key), let caster = group(2) else { continue }
        let isInt = caster == "int" || group(3) == "int"
        pythonRules[key] = LayerValue.Rule(isInt: isInt, minimum: group(4).flatMap { Double($0) }, exclusiveMinimum: group(5) != nil,
                                           maximum: group(6).flatMap { Double($0) }, finite: caster.hasPrefix("_number"))
    }
    let sameKeys = Set(pythonRules.keys) == Set(LayerValue.rules.keys)
    check(sameKeys, "LayerValue has a number rule for exactly the numeric whitelisted keys of config._KEYS",
          "only Python: \(Set(pythonRules.keys).subtracting(LayerValue.rules.keys).sorted()), only Swift: \(Set(LayerValue.rules.keys).subtracting(pythonRules.keys).sorted())")
    var differing: [String] = []
    for (key, rule) in pythonRules {
        guard let mine = LayerValue.rules[key] else { continue }
        if mine.isInt != rule.isInt || mine.minimum != rule.minimum || mine.exclusiveMinimum != rule.exclusiveMinimum || mine.maximum != rule.maximum || (!rule.isInt && mine.finite != rule.finite) { differing.append(key) }
    }
    check(differing.isEmpty, "... and the same type and range for each", "\(differing.sorted())")
}

// MARK: - Policy reading beyond the corpus

private func testPolicyReading(_ base: URL) {
    section("policy reading: values, layers of trust, re-read, test hooks")
    let company = "{\"schema\":1,\"profile\":\"company\",\"revision\":2,\"lanes\":{\"asr_remote\":\"allow\",\"llm\":\"allow\",\"calendar\":\"allow\",\"drive\":\"allow\"},\"approvals\":{\"llm\":\" L-1 \",\"calendar\":\"C-1\",\"drive\":\"D-1\"},\"llm\":{\"claude_bin_pin\":{\"team_id\":\"ABCDE12345\"}}}"
    let p = pol(company)
    check(p.isCompany && p.lanes["llm"] == "allow" && p.lanes["drive"] == "allow" && p.claudeBinPinned, "company with approvals and a pin opens llm, calendar and drive", "\(p.lanes)")
    check(pol(company.replacingOccurrences(of: ",\"llm\":{\"claude_bin_pin\":{\"team_id\":\"ABCDE12345\"}}", with: "")).laneReasons["llm"] == "policy-claude-unpinned", "llm=allow without a signature pin is deny (policy-claude-unpinned)")
    check(pol(company.replacingOccurrences(of: "\"ABCDE12345\"", with: "\"abcde12345\"")).lockedCode == "bad-value", "a Team ID must be 10 upper-case letters or digits")
    check(pol(company.replacingOccurrences(of: "{\"team_id\":\"ABCDE12345\"}", with: "{\"sha256\":\"" + String(repeating: "A", count: 64) + "\"}")).claudeBinPinned, "a sha256 pin is a pin")
    check(pol(company.replacingOccurrences(of: "{\"team_id\":\"ABCDE12345\"}", with: "{\"team_id\":\"ABCDE12345\",\"sha256\":\"" + String(repeating: "a", count: 64) + "\"}")).lockedCode == "bad-value", "a pin with both team_id and sha256 locks")
    check(pol(company.replacingOccurrences(of: "{\"team_id\":\"ABCDE12345\"}", with: "{}")).lockedCode == "bad-value", "an empty pin locks")
    check(pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"lanes\":{\"llm\":\"deny\"}}").lanes["llm"] == "deny" && pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1}").lanes.values.allSatisfy { $0 == "allow" },
          "personal: an omitted lane is allow, a denied one stays denied")
    check(pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"}}").runtimeRoot == nil && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"}}").runtimeRoot == "/opt/x",
          "runtime.root only counts for company")
    // a lock keeps the runtime requirement: the root the file named (when it is sane), else the package's fixed one; never for personal
    let lockedRoot = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"},\"typo\":1}")
    check(lockedRoot.isLocked && lockedRoot.runtimeRoot == "/opt/x" && lockedRoot.pinnedRuntimeRoot == "/opt/x", "a locked company policy still names the runtime root of its file", "\(String(describing: lockedRoot.runtimeRoot))")
    check(pol("{\"typo\":1,\"runtime\":{\"root\":\"/opt/x\"}}").pinnedRuntimeRoot == "/opt/x", "... also when the file does not say its profile")
    for (name, text) in [("no runtime.root in the file", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1}"),
                         ("a runtime.root with a .. component", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/Library/../tmp\"}}"),
                         ("a relative runtime.root", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"releases\"}}"),
                         ("a runtime.root that is a number", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":5}}"),
                         ("a runtime that is a string", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":\"x\"}"),
                         ("a file that is not JSON", "nope"), ("a file without a profile", "{\"typo\":1}"), ("a bad profile", "{\"schema\":1,\"profile\":\"team\",\"revision\":1}")] {
        let locked = pol(text)
        check(locked.isLocked && locked.runtimeRoot == nil && locked.pinnedRuntimeRoot == OrgPolicy.defaultRuntimeRoot, "a locked policy with \(name) requires the package runtime", "\(String(describing: locked.pinnedRuntimeRoot))")
    }
    check(pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"},\"typo\":1}").pinnedRuntimeRoot == nil && pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":1}").pinnedRuntimeRoot == nil
          && OrgPolicy.absent().pinnedRuntimeRoot == nil && pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"}}").pinnedRuntimeRoot == nil
          && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}").pinnedRuntimeRoot == nil && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"}}").pinnedRuntimeRoot == "/opt/x",
          "no requirement for a personal profile (locked or not), no policy, or a valid company policy without a root; a valid company root is pinned")
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"support\":{\"contact\":\"IT 헬프데스크\"}}").supportContact == "IT 헬프데스크", "support.contact is kept")
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"support\":{\"contact\":\"" + String(repeating: "a", count: 61) + "\"}}").lockedCode == "bad-value", "support.contact is at most 60 characters")
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":99999999999999999999}").isValid, "a revision beyond Int64 is valid (Python has big integers)")
    let sha = pol("abc")
    check(sha.sha256Prefix == "ba7816bf" && sha.lockedCode == "bad-json", "sha256Prefix is the first 8 hex digits of the SHA-256 of the bytes", "\(String(describing: sha.sha256Prefix))")
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}").sha256Prefix?.count == 8, "a valid policy has the 8 digit prefix too")
    check(OrgPolicy.parse(Data(count: OrgPolicy.maxBytes + 1)).lockedCode == "too-large", "parse refuses more than 256 KiB")
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"min_pipeline_version\":\"0.10.0\"}", version: "0.2.0").lockedCode == "pipeline-too-old"
          && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"min_pipeline_version\":\"0.2.0\"}", version: "0.10.0").isValid
          && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"min_pipeline_version\":\"0.2.0\"}", version: "garbage").lockedCode == "pipeline-too-old"
          && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"min_pipeline_version\":\"9.0.0\"}").isValid,
          "pipeline-too-old: tuple of integers, an unreadable pipeline version is too old, no version given = not checked")

    // org consents
    let consent = "{\"engine\":\"remote\",\"host\":\"ASR.Example.Test\",\"port\":443,\"protocol\":\"mcap-asr/1\",\"backend_kind\":\"server\",\"ca_sha256\":\"" + String(repeating: "a", count: 64)
        + "\",\"attest_build_sha256\":[\"" + String(repeating: "b", count: 64) + "\"],\"use\":\"both\",\"expires\":\"2027-10-14\"}"
    func withConsent(_ entry: String) -> OrgPolicy { pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"asr\":{\"org_consents\":[\(entry)]}}") }
    check(withConsent(consent).orgConsentHosts == ["asr.example.test"], "an org consent is read (host lower-cased)", "\(withConsent(consent).orgConsentHosts)")
    for (name, entry) in [("backend_kind cloud", consent.replacingOccurrences(of: "\"server\"", with: "\"cloud\"")),
                          ("a 2027-02-30 date", consent.replacingOccurrences(of: "2027-10-14", with: "2027-02-30")),
                          ("use fallback2", consent.replacingOccurrences(of: "\"both\"", with: "\"fallback2\"")),
                          ("a short CA hash", consent.replacingOccurrences(of: String(repeating: "a", count: 64), with: "abcd")),
                          ("port 0", consent.replacingOccurrences(of: "\"port\":443", with: "\"port\":0")),
                          ("port 70000", consent.replacingOccurrences(of: "\"port\":443", with: "\"port\":70000")),
                          ("a host with a blank", consent.replacingOccurrences(of: "ASR.Example.Test", with: "asr example")),
                          ("a missing key", consent.replacingOccurrences(of: "\"use\":\"both\",", with: "")),
                          ("an unknown key", consent.replacingOccurrences(of: "\"port\":443,", with: "\"port\":443,\"extra\":1,"))] {
        check(!withConsent(entry).isValid, "an org consent with \(name) locks the policy", "\(withConsent(entry).lockedReason ?? "valid")")
    }
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"asr\":{\"org_consents\":{}}}").lockedCode == "bad-type", "org_consents must be a list")

    // layer values: the numeric rules of the config parser
    func layer(_ key: String, _ value: String, enforced: Bool = true) -> OrgPolicy {
        pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"\(enforced ? "enforced" : "defaults")\":{\"\(key)\":\"\(value)\"}}")
    }
    for (key, value) in [("AUDIO_RETENTION_DAYS", "30"), ("AUDIO_RETENTION_DAYS", "-1"), ("AUDIO_RETENTION_DAYS", " 7 "), ("AUDIO_RETENTION_DAYS", "1_0"), ("AUDIO_RETENTION_DAYS", "+5"),
                         ("AUDIO_RETENTION_DAYS", "99999999999999999999"), ("LOG_RETENTION_DAYS", "0"), ("LOG_RETENTION_DAYS", "9_9"), ("ASR_LOCAL_MAX_RTF", "0.5"), ("ASR_LOCAL_MAX_RTF", ".5"),
                         ("ASR_LOCAL_MAX_RTF", "1_0.5"), ("ASR_LOCAL_MAX_RTF", "5."), ("ASR_AZURE_BIAS", "1e0"), ("ASR_AZURE_USD_PER_HOUR", "-0"), ("ASR_AZURE_BIAS", "2"), ("ASR_CIRCUIT_FAILS", "3"), ("CLAUDE_DAILY_BUDGET_USD", "nan"), ("CLAUDE_DAILY_BUDGET_USD", "-inf"),
                         ("MIC_MUTE_GATE", "whatever"), ("LOG_CONTENT", "maybe"), ("ENABLED_PLATFORMS", "zoom,teams")] {
        check(layer(key, value).isValid, "layer value \(key)=\(value.debugDescription) is accepted")
    }
    for (key, value) in [("AUDIO_RETENTION_DAYS", "abc"), ("AUDIO_RETENTION_DAYS", "1.5"), ("AUDIO_RETENTION_DAYS", "1__0"), ("AUDIO_RETENTION_DAYS", "_1"), ("AUDIO_RETENTION_DAYS", "1_"),
                         ("LOG_RETENTION_DAYS", "-1"), ("LOG_RETENTION_DAYS", "-99999999999999999999"), ("ASR_LOCAL_MAX_RTF", "0"), ("ASR_LOCAL_MAX_RTF", "nan"),
                         ("ASR_LOCAL_MAX_RTF", "1_.5"), ("ASR_LOCAL_MAX_RTF", "infinity"),
                         ("ASR_AZURE_BIAS", "2.5"), ("ASR_AZURE_BIAS", "0x1p0"), ("ASR_CIRCUIT_FAILS", "0"), ("APP_LOG_MAX_MB", "five"), ("ASR_RETRY_MAX", ""), ("ASR_CLOUD_DAILY_MINUTES", "inf")] {
        check(layer(key, value).lockedCode == "bad-value", "layer value \(key)=\(value.debugDescription) locks the policy (bad-value)", "\(layer(key, value).lockedReason ?? "valid")")
    }
    check(layer("AUDIO_RETENTION_DAYS", "\u{0663}").lockedCode == "bad-value", "a non-ASCII digit is refused (Python's int() would read it: the one place the Swift reader is stricter, the closed direction)")
    check(layer("NOT_A_KEY", "1").lockedCode == "unknown-key" && layer("ARCHIVE_DIR", "/x", enforced: false).lockedCode == "forbidden-key" && layer("SELF_NAME", "x").lockedCode == "forbidden-key",
          "an unknown or forbidden key in a layer locks")
    check(pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"llm\":{\"child_env\":{\"DISABLE_TELEMETRY\":\"1\"}}}").isValid
          && pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"llm\":{\"child_env\":{\"PATH\":\"/evil\"}}}").lockedCode == "unknown-key",
          "llm.child_env takes only the names fixed in code")

    // load(): trust checks, re-read, marker, real lstat
    let dir = base.appendingPathComponent("reading", isDirectory: true)
    makeDir(dir)
    let policyURL = dir.appendingPathComponent("policy.json")
    let markerURL = dir.appendingPathComponent("policy.required")
    let valid = Data("{\"schema\":1,\"profile\":\"company\",\"revision\":7}".utf8)
    var reads = 0
    let flaky = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { url in url.path == policyURL.path ? rootFile : rootDirectory }, retryAfterMs: 1,
                               readFile: { _ in reads += 1; return reads == 1 ? Data("{\"schema\":".utf8) : valid })
    check(flaky.isValid && flaky.revision == 7 && reads == 2, "a locked first read is confirmed by ONE more read (MDM writes the file): valid on the second", "reads \(reads), \(flaky.state)")
    reads = 0
    let hopeless = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { url in url.path == policyURL.path ? rootFile : rootDirectory }, retryAfterMs: 1,
                                  readFile: { _ in reads += 1; return Data("nope".utf8) })
    check(hopeless.isLocked && reads == 2, "two bad reads stay locked (exactly two reads)", "reads \(reads)")
    reads = 0
    let none = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { _ in nil }, retryAfterMs: 1, readFile: { _ in reads += 1; return nil })
    check(none.state == .absent && reads == 0 && none.lanes.values.allSatisfy { $0 == "allow" } && none.enforced.isEmpty, "no file and no marker: absent, nothing read, nothing restricted")
    let markerOnly = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { url in url.path == markerURL.path ? rootFile : nil }, retryAfterMs: 0)
    check(markerOnly.lockedCode == "required-missing" && markerOnly.localOnlyLocked && markerOnly.recordingEnabled, "policy.required without policy.json locks, recording stays allowed")
    let unreadable = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { url in url.path == policyURL.path ? rootFile : rootDirectory }, retryAfterMs: 0, readFile: { _ in nil })
    check(unreadable.lockedReason == "unreadable: read", "a file that cannot be read locks (unreadable: read)", "\(unreadable.lockedReason ?? "-")")
    let huge = OrgPolicy.load(path: policyURL, marker: markerURL, fileInfo: { url in url.path == policyURL.path ? rootFile : rootDirectory }, retryAfterMs: 0,
                              readFile: { _ in Data(count: OrgPolicy.maxBytes + 1) })
    check(huge.lockedCode == "too-large", "a file that grew beyond the limit after the stat locks (too-large)")
    check(OrgPolicy.systemPolicyPresent(path: policyURL, marker: markerURL, fileInfo: { _ in nil }) == false
          && OrgPolicy.systemPolicyPresent(path: policyURL, marker: markerURL, fileInfo: { $0.path == markerURL.path ? rootFile : nil })
          && OrgPolicy.systemPolicyPresent(path: policyURL, marker: markerURL, fileInfo: { $0.path == policyURL.path ? OrgPolicy.FileInfo(isRegular: false, isSymlink: false, uid: 0, mode: 0, size: 0, statError: true) : nil }),
          "a Mac is policy-managed when either file is there, also when it cannot be inspected")

    // the real lstat and the real read (not root-owned: a policy in a user's folder is never trusted)
    write("{\"schema\":1,\"profile\":\"personal\",\"revision\":1}", to: policyURL)
    let real = OrgPolicy.statFile(policyURL)
    check(real?.isRegular == true && real?.isSymlink == false && real?.uid == UInt32(getuid()) && (real?.mode ?? 0) & 0o777 == 0o644, "statFile reports a regular file with its owner and mode", "\(String(describing: real))")
    let link = dir.appendingPathComponent("link.json")
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: policyURL)
    check(OrgPolicy.statFile(link)?.isSymlink == true && OrgPolicy.statFile(dir.appendingPathComponent("missing.json")) == nil, "statFile sees a symlink as a symlink (lstat) and a missing file as nil")
    check(OrgPolicy.readPolicyFile(link) == nil && OrgPolicy.readPolicyFile(policyURL) == Data("{\"schema\":1,\"profile\":\"personal\",\"revision\":1}".utf8), "the real reader reads the file and does not follow a symlink (O_NOFOLLOW)")
    if getuid() != 0 {
        let untrusted = OrgPolicy.load(path: policyURL, marker: markerURL, retryAfterMs: 0)
        check(untrusted.lockedCode == "bad-owner", "a policy file owned by a normal user locks with the production lstat (bad-owner)", "\(untrusted.lockedReason ?? "-")")
    }

    // test hooks
    check(OrgPolicy.testHookValue("MCAP_CONFIG", env: ["MCAP_CONFIG": "/x/config.env"], policyPresent: false) == "/x/config.env"
          && OrgPolicy.testHookValue("MCAP_CONFIG", env: ["MCAP_CONFIG": "/x/config.env"], policyPresent: true) == nil
          && OrgPolicy.testHookValue("MCAP_CONFIG", env: ["MCAP_CONFIG": ""], policyPresent: false) == nil
          && OrgPolicy.testHookValue("MCAP_CONFIG", env: [:], policyPresent: false) == nil,
          "test hooks are honoured only without a policy, and an empty or unset one is nothing")
    check(ApiKeyItem.securityBinary(env: ["MCAP_SECURITY_BIN": "/tmp/shim"], policyPresent: false).path == "/tmp/shim"
          && ApiKeyItem.securityBinary(env: ["MCAP_SECURITY_BIN": "/tmp/shim"], policyPresent: true).path == "/usr/bin/security"
          && ApiKeyItem.securityBinary(env: [:], policyPresent: false).path == "/usr/bin/security",
          "MCAP_SECURITY_BIN is ignored on a policy-managed Mac: only /usr/bin/security")
}

// MARK: - Layers

private func testPolicyLayers(_ base: URL) {
    section("PolicyLayers: defaults beneath, enforced over, whitelist, ignored keys, company runtime paths; AppConfig.load")
    let company = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"defaults\":{\"ASR_ENGINE\":\"auto\",\"NOTE_MODEL\":\"sonnet\",\"ENABLED_PLATFORMS\":\"zoom\"},"
                      + "\"enforced\":{\"AUDIO_RETENTION_DAYS\":\"30\",\"MIC_MUTE_GATE\":\"off\"},\"runtime\":{\"root\":\"/opt/mcap/releases/\"}}")
    var v: [String: String] = ["ASR_ENGINE": "remote", "AUDIO_RETENTION_DAYS": "0", "SUPPORT_DIR": "/x", "PYTHON_BIN": "/y", "PROJECT_DIR": "/z", "CLAUDE_BIN": "/c", "ARCHIVE_DIR": "/a",
                               "LOG_CONTENT": "1", "SELF_NAME": "Q", "ENABLED_PLATFORMS": ""]
    PolicyLayers.apply(&v, policy: company)
    check(v["ASR_ENGINE"] == "remote" && v["NOTE_MODEL"] == "sonnet", "a default applies only where config.env has no value (config.env wins)", "\(v)")
    check(v["ENABLED_PLATFORMS"] == "zoom", "an EMPTY config.env value counts as unset for a default (Python: empty = unset)")
    check(v["AUDIO_RETENTION_DAYS"] == "30" && v["MIC_MUTE_GATE"] == "off", "enforced beats config.env, and an explicit enforced key beats the company baseline")
    check(v["LOG_CONTENT"] == "0" && v["ASR_ALLOW_DOWNLOAD"] == "0" && v["NOTIFY_RECORDING"] == "1", "the company baseline is enforced (LOG_CONTENT=0, ASR_ALLOW_DOWNLOAD=0, NOTIFY_RECORDING=1)")
    check(v["SUPPORT_DIR"] == nil && v["CLAUDE_BIN"] == nil, "SUPPORT_DIR and CLAUDE_BIN of config.env are ignored on a managed Mac")
    check(v["PROJECT_DIR"] == "/opt/mcap/releases/current" && v["PYTHON_BIN"] == "/opt/mcap/releases/current/venv/bin/python", "company with runtime.root: PROJECT_DIR and PYTHON_BIN are <root>/current", "\(v["PROJECT_DIR"] ?? "-")")
    check(v["ARCHIVE_DIR"] == "/a" && v["SELF_NAME"] == "Q", "keys no layer may change are left as the user wrote them")

    var hostile = company
    hostile.enforced["ARCHIVE_DIR"] = "/evil"; hostile.defaults["PYTHON_BIN"] = "/evil"; hostile.enforced["NOT_ON_THE_LIST"] = "1"
    var h: [String: String] = [:]
    PolicyLayers.apply(&h, policy: hostile)
    check(h["ARCHIVE_DIR"] == nil && h["NOT_ON_THE_LIST"] == nil && h["PYTHON_BIN"] == "/opt/mcap/releases/current/venv/bin/python", "defence in depth: only whitelisted keys are applied even from a hand-built policy", "\(h)")

    var personal: [String: String] = ["PYTHON_BIN": "/y", "NOTIFY_RECORDING": "0"]
    PolicyLayers.apply(&personal, policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"enforced\":{\"LOG_RETENTION_DAYS\":\"30\"},\"runtime\":{\"root\":\"/opt/x\"}}"))
    check(personal == ["NOTIFY_RECORDING": "0", "LOG_RETENTION_DAYS": "30"], "personal: no baseline, no runtime paths, the ignored keys are still dropped", "\(personal)")

    var locked: [String: String] = ["SUPPORT_DIR": "/x", "LOG_CONTENT": "1", "ASR_ENGINE": "remote"]
    PolicyLayers.apply(&locked, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1,\"defaults\":{\"ASR_ENGINE\":\"auto\"}}"))
    check(locked["LOG_CONTENT"] == "0" && locked["SUPPORT_DIR"] == nil && locked["ASR_ENGINE"] == "remote" && locked["ASR_ALLOW_DOWNLOAD"] == "0", "a locked policy keeps the company baseline, applies no defaults and drops the ignored keys", "\(locked)")
    var lockedPersonal: [String: String] = ["LOG_CONTENT": "1"]
    PolicyLayers.apply(&lockedPersonal, policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":1}"))
    check(lockedPersonal == ["LOG_CONTENT": "1"], "a file that positively says personal gets no baseline when it is locked")

    // a lock keeps the runtime: PYTHON_BIN and PROJECT_DIR are pinned (a typo in the policy must not hand the launcher back to the user's
    // folders, and on a package-installed Mac must not stop the local transcription either)
    var lockedRuntime: [String: String] = ["PYTHON_BIN": "/Users/alice/venv/bin/python", "PROJECT_DIR": "/Users/alice/project", "SUPPORT_DIR": "/x"]
    PolicyLayers.apply(&lockedRuntime, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/mcap/releases/\"},\"typo\":1}"))
    check(lockedRuntime["PROJECT_DIR"] == "/opt/mcap/releases/current" && lockedRuntime["PYTHON_BIN"] == "/opt/mcap/releases/current/venv/bin/python" && lockedRuntime["SUPPORT_DIR"] == nil,
          "a locked company policy pins PYTHON_BIN and PROJECT_DIR to the runtime root its file named", "\(lockedRuntime)")
    for text in ["{\"typo\":1}", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1}", "nope", "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/a/../b\"}}"] {
        var packaged: [String: String] = ["PYTHON_BIN": "/Users/alice/venv/bin/python", "PROJECT_DIR": "/Users/alice/project"]
        PolicyLayers.apply(&packaged, policy: pol(text))
        check(packaged["PROJECT_DIR"] == OrgPolicy.defaultRuntimeRoot + "/current" && packaged["PYTHON_BIN"] == OrgPolicy.defaultRuntimeRoot + "/current/venv/bin/python",
              "a locked policy that names no usable runtime root pins the package one (\(text.prefix(30)))", "\(packaged)")
    }
    var lockedOwnerPaths: [String: String] = ["PYTHON_BIN": "/y", "PROJECT_DIR": "/z"]
    PolicyLayers.apply(&lockedOwnerPaths, policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":1}"))
    check(lockedOwnerPaths["PYTHON_BIN"] == nil && lockedOwnerPaths["PROJECT_DIR"] == nil, "a locked personal policy pins nothing: the ignored keys are dropped and the app's own defaults apply")

    var untouched: [String: String] = ["SUPPORT_DIR": "/x", "PYTHON_BIN": "/y", "LOG_CONTENT": "1", "ENABLED_PLATFORMS": ""]
    PolicyLayers.apply(&untouched, policy: .absent())
    check(untouched == ["SUPPORT_DIR": "/x", "PYTHON_BIN": "/y", "LOG_CONTENT": "1", "ENABLED_PLATFORMS": ""], "no policy: the values are exactly what config.env said (the personal install does not change)")

    // AppConfig.load end to end
    let dir = base.appendingPathComponent("layers", isDirectory: true)
    makeDir(dir)
    let configFile = dir.appendingPathComponent("config.env")
    write("SUPPORT_DIR=/tmp/elsewhere\nPYTHON_BIN=/tmp/py\nSELF_NAME=Tester\nNOTIFY_RECORDING=0\nENABLED_PLATFORMS=\nZOOM_STRONG_SOCKETS=9\n", to: configFile)
    let plain = AppConfig.load(from: configFile, policy: .absent())
    check(plain.supportDir.path == "/tmp/elsewhere" && plain.pythonBin.path == "/tmp/py" && plain.selfName == "Tester" && !plain.notifyRecording && plain.enabledPlatforms.isEmpty,
          "AppConfig.load without a policy reads config.env as before (SUPPORT_DIR and PYTHON_BIN hooks work, empty ENABLED_PLATFORMS = none)")
    let managed = AppConfig.load(from: configFile, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/mcap/releases\"},\"enforced\":{\"ZOOM_STRONG_SOCKETS\":\"3\"}}"))
    check(managed.supportDir.path == AppConfig.defaults().supportDir.path && managed.pythonBin.path == "/opt/mcap/releases/current/venv/bin/python"
          && managed.projectDir.path == "/opt/mcap/releases/current" && managed.notifyRecording && managed.selfName == "Tester",
          "AppConfig.load on a managed Mac: SUPPORT_DIR ignored, runtime paths from the policy, NOTIFY_RECORDING enforced to 1", "\(managed.supportDir.path) \(managed.pythonBin.path) \(managed.notifyRecording)")
    let managedLock = AppConfig.load(from: configFile, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/mcap/releases\"},\"typo\":1}"))
    check(managedLock.pythonBin.path == "/opt/mcap/releases/current/venv/bin/python" && managedLock.projectDir.path == "/opt/mcap/releases/current" && managedLock.supportDir.path == AppConfig.defaults().supportDir.path,
          "AppConfig.load under a locked company policy still starts python from the runtime root", "\(managedLock.pythonBin.path) \(managedLock.projectDir.path)")
    let missing = AppConfig.load(from: dir.appendingPathComponent("absent.env"), policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"enforced\":{\"NOTIFY_RECORDING\":\"0\"}}"))
    check(!missing.notifyRecording, "a missing config.env still gets the enforced layer on a managed Mac")
    let noFile = AppConfig.load(from: dir.appendingPathComponent("absent.env"), policy: .absent())
    check(noFile.notifyRecording && noFile.selfName == AppConfig.defaults().selfName, "a missing config.env without a policy is the built-in defaults")
    check(ZoomTierSettings.load(from: configFile, policy: .absent()).strongSockets == 9 && ZoomTierSettings.load(from: configFile, policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"enforced\":{\"ZOOM_STRONG_SOCKETS\":\"3\"}}")).strongSockets == 3,
          "ZoomTierSettings sees the enforced layer too")

    // Calls of other apps (CALL_DETECT and friends): on the whitelist, so a policy can switch them off or lock them; a managed Mac that sets nothing gets `off`.
    for key in ["CALL_DETECT", "CALL_GENERIC_SECONDS", "EXTRA_MEETING_APPS", "CALL_BROWSER_URLS"] {
        check(PolicyLayers.whitelist.contains(key), "\(key) is a key a policy layer may carry")
    }
    let callFile = dir.appendingPathComponent("call.env")
    write("CALL_DETECT=generic\nCALL_GENERIC_SECONDS=30\nEXTRA_MEETING_APPS=com.example.talk=Talk\nCALL_BROWSER_URLS=1\n", to: callFile)
    let callOwn = CallDetectSettings.load(from: callFile, policy: .absent())
    check(callOwn.mode == .generic && callOwn.genericSeconds == 30 && callOwn.browserURLs && callOwn.extraApps.count == 1, "no policy: config.env decides (generic, 30 s, browser pages, one extra app)")
    let callEnforced = CallDetectSettings.load(from: callFile, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"enforced\":{\"CALL_DETECT\":\"off\"}}"))
    check(callEnforced.mode == .off, "an enforced CALL_DETECT=off beats config.env (the user cannot switch the guessing on)", "\(callEnforced.mode)")
    let callEnforcedWeb = CallDetectSettings.load(from: callFile, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"enforced\":{\"CALL_DETECT\":\"known\",\"CALL_BROWSER_URLS\":\"0\",\"EXTRA_MEETING_APPS\":\"com.example.other\"}}"))
    check(callEnforcedWeb.mode == .known && !callEnforcedWeb.browserURLs && callEnforcedWeb.extraApps.map { $0.id } == ["com.example.other"], "enforced CALL_DETECT, CALL_BROWSER_URLS and EXTRA_MEETING_APPS beat config.env", "\(callEnforcedWeb)")
    let callDefault = CallDetectSettings.load(from: callFile, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"defaults\":{\"CALL_DETECT\":\"known\",\"CALL_GENERIC_SECONDS\":\"90\"}}"))
    check(callDefault.mode == .generic && callDefault.genericSeconds == 30, "a policy default never beats what config.env says")
    let emptyEnv = dir.appendingPathComponent("empty-call.env")
    write("ENABLED_PLATFORMS=zoom,teams\n", to: emptyEnv)
    check(CallDetectSettings.load(from: emptyEnv, policy: .absent()).mode == .known, "a personal Mac that sets nothing: known (the named apps, no guessing)")
    check(CallDetectSettings.load(from: emptyEnv, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}")).mode == .off, "a managed Mac that sets nothing: off (ENABLED_PLATFORMS=zoom,teams is the whole story)")
    check(CallDetectSettings.load(from: emptyEnv, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1}")).mode == .off, "... also under a locked policy")
    check(CallDetectSettings.load(from: dir.appendingPathComponent("absent.env"), policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1}")).mode == .off && CallDetectSettings.load(from: dir.appendingPathComponent("absent.env"), policy: .absent()).mode == .known,
          "... and without a config.env: off under a policy, known without")
    check(CallDetectSettings.load(from: emptyEnv, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"defaults\":{\"CALL_DETECT\":\"known\"}}")).mode == .known, "a managed Mac whose policy default says known: known")

    withEnv("MCAP_CONFIG", configFile.path) {
        check(AppConfig.configFilePath.path == configFile.path, "MCAP_CONFIG names the config file (no policy on this Mac)")
    }
}

// MARK: - Privacy settings

private func testPrivacySettings() {
    section("PrivacySettings: every key parsed to its own restrictive value")
    let support = URL(fileURLWithPath: "/tmp/mcap-test-support", isDirectory: true)
    func build(_ v: [String: String]) -> PrivacySettings { PrivacySettings.build(from: v, supportDir: support, source: "selftest") }
    let d = build([:])
    check(d == PrivacySettings(localOnlyDefault: false, asrEngine: "whisper", micMuteGate: "off", localArchiveDir: support.appendingPathComponent("local-meetings", isDirectory: true), archiveDirExplicit: false)
          && d.asrFallback == "none" && d.logContent && d.logRetentionDays == 0 && d.appLogMaxMB == 0 && d.calendarLookup && d.warnings.isEmpty,
          "no keys: today's behaviour (local-only off, whisper, no mute gate, local-meetings under SUPPORT_DIR, log content on, no rotation, calendar on)")
    for (text, want) in [("1", true), ("true", true), ("YES", true), (" on ", true), ("0", false), ("False", false), ("no", false), ("OFF", false)] {
        check(build(["LOCAL_ONLY_DEFAULT": text]).localOnlyDefault == want && build(["LOCAL_ONLY_DEFAULT": text]).warnings.isEmpty, "LOCAL_ONLY_DEFAULT=\(text.debugDescription) -> \(want)")
    }
    for text in ["maybe", "2", "enabled", "tru", "y"] {
        let s = build(["LOCAL_ONLY_DEFAULT": text])
        check(s.localOnlyDefault && s.warnings.count == 1, "LOCAL_ONLY_DEFAULT=\(text.debugDescription) is read as ON (fail closed) with a warning", "\(s.warnings)")
    }
    check(build(["LOCAL_ONLY_DEFAULT": ""]).localOnlyDefault == false, "an empty LOCAL_ONLY_DEFAULT is unset")
    check(build(["LOG_CONTENT": "weird"]).logContent == false && build(["LOG_CONTENT": "weird"]).warnings.count == 1 && build(["LOG_CONTENT": "1"]).logContent && build(["LOG_CONTENT": "0"]).logContent == false,
          "LOG_CONTENT unknown text = 0 (the content stays out of the log)")
    for (text, want) in [("on", "on"), ("1", "on"), ("TRUE", "on"), ("yes", "on"), ("off", "off"), ("0", "off"), ("False", "off"), ("no", "off"), ("weird", "on")] {
        check(build(["MIC_MUTE_GATE": text]).micMuteGate == want, "MIC_MUTE_GATE=\(text.debugDescription) -> \(want)")
    }
    check(build(["MIC_MUTE_GATE": "weird"]).warnings.count == 1 && build(["MIC_MUTE_GATE": "off"]).warnings.isEmpty, "only an unrecognised MIC_MUTE_GATE is warned about")
    for (text, want) in [("remote", "remote"), ("Azure", "azure"), (" auto ", "auto"), ("whisper", "whisper"), ("gemini", "whisper"),
                         ("CLOVA", "clova"), (" openai-compat ", "openai-compat")] {
        check(build(["ASR_ENGINE": text]).asrEngine == want, "ASR_ENGINE=\(text.debugDescription) -> \(want)")
    }
    check(build(["ASR_ENGINE": "gemini"]).warnings.count == 1 && build(["ASR_FALLBACK": "remote"]).asrFallback == "remote" && build(["ASR_FALLBACK": "auto"]).asrFallback == "none",
          "an unknown engine word is whisper / none with a warning (auto is not a fallback)")
    for word in ["clova", "openai-compat"] {
        check(build(["ASR_ENGINE": word]).warnings.isEmpty && build(["ASR_FALLBACK": word]).asrFallback == word && build(["ASR_FALLBACK": word]).warnings.isEmpty,
              "\(word) is an engine and a fallback the app understands (no warning, not read as whisper)")
    }
    let home = NSHomeDirectory()
    check(build(["LOCAL_ARCHIVE_DIR": "~/x/y"]).localArchiveDir.path == home + "/x/y" && build(["LOCAL_ARCHIVE_DIR": "/abs/p"]).localArchiveDir.path == "/abs/p",
          "LOCAL_ARCHIVE_DIR: ~ is expanded, an absolute path is taken")
    let relative = build(["LOCAL_ARCHIVE_DIR": "rel/dir"])
    check(relative.localArchiveDir == d.localArchiveDir && relative.warnings.count == 1, "a relative LOCAL_ARCHIVE_DIR keeps the default with a warning")
    check(build(["ARCHIVE_DIR": "/x"]).archiveDirExplicit && !build(["ARCHIVE_DIR": ""]).archiveDirExplicit && !build([:]).archiveDirExplicit, "ARCHIVE_DIR is 'explicit' only when written and not empty")
    check(build(["LOG_RETENTION_DAYS": "30", "APP_LOG_MAX_MB": "5"]).logRetentionDays == 30 && build(["LOG_RETENTION_DAYS": "30", "APP_LOG_MAX_MB": "5"]).appLogMaxMB == 5
          && build(["LOG_RETENTION_DAYS": "-1"]).logRetentionDays == 0 && build(["APP_LOG_MAX_MB": "five"]).warnings.count == 1, "LOG_RETENTION_DAYS and APP_LOG_MAX_MB: whole numbers, a bad one keeps 0 with a warning")
    check(!build(["CALENDAR_LOOKUP": "0"]).calendarLookup && !build(["CALENDAR_LOOKUP": "OFF"]).calendarLookup && build(["CALENDAR_LOOKUP": "auto"]).calendarLookup, "CALENDAR_LOOKUP off words")
}

// MARK: - Archive roots, local archive

private func testArchiveAndLocalArchive(_ base: URL) {
    section("realpath, the local archive allow-list")
    let dir = base.appendingPathComponent("archive", isDirectory: true)
    let support = dir.appendingPathComponent("support", isDirectory: true)
    makeDir(support.appendingPathComponent("local-meetings"))
    let target = dir.appendingPathComponent("real-target", isDirectory: true)
    makeDir(target)
    try? FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: target)
    let loop = dir.appendingPathComponent("loop")
    try? FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
    let realBase = RealPath.resolve(dir.path)
    check(RealPath.resolve(dir.path + "/link/x/../y") == RealPath.resolve(target.path) + "/y", "realpath follows a symlink and folds .. lexically after the existing part", RealPath.resolve(dir.path + "/link/x/../y"))
    check(RealPath.resolve(dir.path + "/nothing/../here") == realBase + "/here", "a path that does not exist is normalised without failing")
    check(RealPath.resolve(dir.path + "/loop/x") == RealPath.lexical(dir.path + "/loop/x"), "a symlink loop leaves the path as it is")
    check(RealPath.lexical("/a//b/./c/../d/") == "/a/b/d" && RealPath.lexical("/../..") == "/", "lexical folding (os.path.abspath)")
    check(ArchiveRootMatcher.componentMatches("googledrive-x@example.com", pattern: "googledrive-*@example.com") && ArchiveRootMatcher.componentMatches("ab", pattern: "a*b") && !ArchiveRootMatcher.componentMatches("a", pattern: "a*a")
          && ArchiveRootMatcher.componentMatches("aaa", pattern: "a*a") && ArchiveRootMatcher.componentMatches("xay", pattern: "*a*") && !ArchiveRootMatcher.componentMatches("x", pattern: "*a*")
          && ArchiveRootMatcher.componentMatches("", pattern: "*") && ArchiveRootMatcher.componentMatches("abcabc", pattern: "a*c*c"), "the component glob: only * is a wildcard, pieces may not overlap")
    check(ArchiveRootMatcher.fold("Straße") == "strasse" && ArchiveRootMatcher.fold("\u{AC00}") == ArchiveRootMatcher.fold("\u{1100}\u{1161}") && ArchiveRootMatcher.fold("ǅ") == "ǆ", "casefold folds ß like Python and NFC joins a decomposed Hangul syllable")

    let local = support.appendingPathComponent("local-meetings")
    func verdict(_ path: String, roots: [String] = [], device: @escaping (String) -> UInt64? = { _ in 1 }) -> String {
        LocalArchiveCheck.verdict(path: path, supportDir: support.path, extraRoots: roots, home: NSHomeDirectory(), device: device).reason
    }
    check(verdict(local.path) == "ok", "LOCAL_ARCHIVE_DIR under SUPPORT_DIR is allowed", verdict(local.path))
    check(verdict(local.path + "/2026-10/sub") == "ok", "... also a folder below it that does not exist yet")
    check(verdict("") == "empty-path" && verdict("relative/dir") == "bad-path", "an empty or relative path is refused")
    check(verdict(dir.path + "/elsewhere") == "outside-allowed-roots", "outside SUPPORT_DIR is refused")
    check(verdict(dir.path + "/elsewhere", roots: [dir.path + "/elsewhere"]) == "ok", "... unless a policy local_roots entry covers it")
    check(verdict(dir.path + "/elsewhere/x", roots: [dir.path + "/else*"]) == "ok" && verdict(dir.path + "/elsewhere-evil", roots: [dir.path + "/elsewhere"]) == "outside-allowed-roots",
          "local_roots match by whole components with * inside one component")
    try? FileManager.default.createSymbolicLink(at: support.appendingPathComponent("sneaky"), withDestinationURL: target)
    check(verdict(support.path + "/sneaky/x") == "symlink-in-path", "a symlink inside the path is refused", verdict(support.path + "/sneaky/x"))
    check(verdict(support.path + "/../support/local-meetings") == "ok" && verdict(local.path, device: { $0 == NSHomeDirectory() ? 1 : 2 }) == "different-device", "'..' that stays inside is fine, another device is refused")
    check(verdict(local.path, device: { _ in nil }) == "different-device", "a device that cannot be read is refused")
}

// MARK: - Local-only flag

private func testLocalOnlyResolver() {
    section("LocalOnlyResolver: start value and toggle")
    let support = URL(fileURLWithPath: "/tmp/mcap-test-support", isDirectory: true)
    func settings(_ on: Bool) -> PrivacySettings { PrivacySettings.build(from: on ? ["LOCAL_ONLY_DEFAULT": "1"] : [:], supportDir: support, source: "selftest") }
    let open = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}")
    let policyDefault = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"local_only\":{\"default\":true}}")
    let policyLocked = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"local_only\":{\"default\":false,\"locked\":true}}")
    let bad = pol("{\"typo\":1}")
    check(bad.isLocked, "(the invalid policy of this test is locked)")
    typealias V = LocalOnlyValue
    let table: [(String, OrgPolicy, Bool, V)] = [
        ("no policy, no config key", .absent(), false, V(value: false, source: "default", locked: false)),
        ("no policy, LOCAL_ONLY_DEFAULT=1", .absent(), true, V(value: true, source: "config-default", locked: false)),
        ("company without local_only, config off", open, false, V(value: false, source: "default", locked: false)),
        ("company without local_only, config on", open, true, V(value: true, source: "config-default", locked: false)),
        ("policy default true, config off", policyDefault, false, V(value: true, source: "policy-default", locked: false)),
        ("policy default true, config on (the policy is named first)", policyDefault, true, V(value: true, source: "policy-default", locked: false)),
        ("policy locked, config off", policyLocked, false, V(value: true, source: "policy-lock", locked: true)),
        ("policy locked, config on", policyLocked, true, V(value: true, source: "policy-lock", locked: true)),
        ("invalid policy, config off", bad, false, V(value: true, source: "policy-invalid", locked: true)),
        ("invalid policy, config on", bad, true, V(value: true, source: "policy-invalid", locked: true)),
    ]
    for (name, policy, config, want) in table {
        let got = LocalOnlyResolver.initial(policy: policy, settings: settings(config))
        check(got == want, "initial: \(name)", "\(got)")
    }
    let off = V(value: false, source: "default", locked: false)
    let on = V(value: true, source: "policy-default", locked: false)
    check(LocalOnlyResolver.toggled(from: off, to: true, policy: open, source: "menu") == V(value: true, source: "menu", locked: false), "toggle ON from off")
    check(LocalOnlyResolver.toggled(from: on, to: false, policy: policyDefault, source: "menu-after-stop") == V(value: false, source: "menu-after-stop", locked: false),
          "toggle OFF from a policy default (the default only raises the start value; only `locked` pins it)")
    check(LocalOnlyResolver.toggled(from: on, to: true, policy: policyDefault, source: "menu") == on && LocalOnlyResolver.toggled(from: off, to: false, policy: open, source: "menu") == off, "asking for the value it already has changes nothing")
    let lockedValue = LocalOnlyResolver.initial(policy: policyLocked, settings: settings(false))
    check(LocalOnlyResolver.toggled(from: lockedValue, to: false, policy: policyLocked, source: "menu") == nil, "toggle OFF under a locked policy is refused (nil)")
    check(LocalOnlyResolver.toggled(from: lockedValue, to: true, policy: policyLocked, source: "menu") == lockedValue, "toggle ON under a locked policy keeps the lock source")
    check(LocalOnlyResolver.toggled(from: LocalOnlyResolver.initial(policy: bad, settings: settings(false)), to: false, policy: bad, source: "menu") == nil, "toggle OFF under an invalid policy is refused")
    check(LocalOnlyResolver.toggled(from: V(value: true, source: "menu", locked: false), to: false, policy: policyLocked, source: "menu") == nil, "even a stale unlocked value cannot be relaxed once the policy locks the flag")
    check(LocalOnlyResolver.toggled(from: off, to: true, policy: open, source: "") == V(value: true, source: "menu", locked: false), "an empty source becomes 'menu'")
}

// MARK: - Effective lanes

private func testEffectiveLanes() {
    section("EffectiveLanes: only what is true")
    let support = URL(fileURLWithPath: "/tmp/mcap-test-support", isDirectory: true)
    let home = "/Users/alice"
    let team = URL(fileURLWithPath: home + "/Library/CloudStorage/GoogleDrive-user@example.com/Shared drives/Meetings", isDirectory: true)
    let myDrive = URL(fileURLWithPath: home + "/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/Meetings", isDirectory: true)
    func settings(_ v: [String: String]) -> PrivacySettings { PrivacySettings.build(from: v, supportDir: support, source: "selftest") }
    let companyJSON = "{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"lanes\":{\"asr_remote\":\"allow\",\"asr_cloud\":\"allow\",\"llm\":\"allow\",\"calendar\":\"allow\",\"drive\":\"allow\"},"
        + "\"approvals\":{\"asr_cloud\":\"A\",\"llm\":\"L\",\"calendar\":\"C\",\"drive\":\"D\"},\"llm\":{\"claude_bin_pin\":{\"team_id\":\"ABCDE12345\"}},"
        + "\"asr\":{\"allowed_engines\":[\"whisper\",\"remote\",\"azure\"]},\"archive\":{\"allowed_roots\":[\"~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings\"]}}"
    let company = pol(companyJSON)
    check(company.isValid, "(the open company policy of this test is valid)", company.lockedReason ?? "")
    let explicit = settings(["ARCHIVE_DIR": team.path])

    let personal = EffectiveLanes.compute(policy: .absent(), localOnly: false, settings: settings([:]), archiveDir: myDrive, home: home)
    check(personal == EffectiveLanes(asr: "this-mac", note: true, calendar: true, archive: "org-folder", orgManaged: false), "the personal install: whisper here, note and calendar on, the Drive folder", "\(personal)")
    check(personal.idleLinesText == ["전사: 이 Mac에서 처리 (외부 전사 없음)", "보관: Google Drive(동기화)"], "idle lines of the personal install", "\(personal.idleLinesText)")
    check(personal.summaryText == "이 회의: 전사=이 Mac · 회의록=켜짐 · 보관=Google Drive", "summary of the personal install", personal.summaryText)
    let localOnly = EffectiveLanes.compute(policy: .absent(), localOnly: true, settings: settings([:]), archiveDir: myDrive, home: home)
    check(localOnly == EffectiveLanes(asr: "local-only", note: false, calendar: false, archive: "this-mac", orgManaged: false), "local-only: no note, no calendar, nothing to Drive", "\(localOnly)")
    check(localOnly.idleLinesText == ["전사: 로컬 전용", "보관: 이 Mac 전용"] && localOnly.summaryText == "이 회의: 전사=이 Mac · 회의록=꺼짐 · 보관=이 Mac", "local-only texts", "\(localOnly.idleLinesText) \(localOnly.summaryText)")
    let remote = EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["ASR_ENGINE": "remote", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home)
    check(remote == EffectiveLanes(asr: "company-server", note: true, calendar: true, archive: "org-folder", orgManaged: true), "company, ASR_ENGINE=remote: external engine possible, team drive", "\(remote)")
    check(remote.idleLinesText == ["전사: 외부 엔진 가능 (회사 서버)", "보관: 팀 드라이브(동기화)"] && remote.summaryText == "이 회의: 전사=회사 서버 · 회의록=켜짐 · 보관=팀 드라이브", "company texts", "\(remote.idleLinesText) \(remote.summaryText)")
    check(EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["ASR_ENGINE": "auto", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "company-server", "auto may choose the company server")
    check(EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["ASR_ENGINE": "whisper", "ASR_FALLBACK": "remote", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "company-server", "a remote FALLBACK makes external audio possible")
    check(EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["ASR_ENGINE": "azure", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "azure-kr", "azure is named 'Azure 한국'")
    check(EffectiveLanes.compute(policy: company, localOnly: false, settings: explicit, archiveDir: team, home: home).asr == "this-mac", "whisper stays this-mac whatever the policy allows")
    // CLOVA and an OpenAI-style server the user named are external engines: the menu and the notification must say so (they read as whisper before)
    let providersAllowed = pol(companyJSON.replacingOccurrences(of: "[\"whisper\",\"remote\",\"azure\"]", with: "[\"whisper\",\"remote\",\"azure\",\"clova\",\"openai-compat\"]"))
    check(providersAllowed.isValid, "(the company policy that allows both providers is valid)", providersAllowed.lockedReason ?? "")
    for (engine, state, idle, summary) in [("clova", "clova-kr", "전사: 외부 엔진 가능 (NAVER CLOVA)", "이 회의: 전사=CLOVA · 회의록=켜짐 · 보관=팀 드라이브"),
                                           ("openai-compat", "chosen-server", "전사: 외부 엔진 가능 (직접 정한 서버)", "이 회의: 전사=직접 정한 서버 · 회의록=켜짐 · 보관=팀 드라이브")] {
        for key in ["ASR_ENGINE", "ASR_FALLBACK"] {
            let lanes = EffectiveLanes.compute(policy: providersAllowed, localOnly: false, settings: settings([key: engine, "ARCHIVE_DIR": team.path]), archiveDir: team, home: home)
            check(lanes.asr == state && lanes.idleLinesText.first == idle && lanes.summaryText == summary, "\(key)=\(engine): the lane says an external engine is possible (\(state))", "\(lanes.asr) \(lanes.idleLinesText) \(lanes.summaryText)")
        }
        check(EffectiveLanes.compute(policy: .absent(), localOnly: false, settings: settings(["ASR_ENGINE": engine]), archiveDir: myDrive, home: home).asr == state, "the personal install: \(engine) is external too")
        check(EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["ASR_ENGINE": engine, "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "this-mac",
              "\(engine) outside allowed_engines is not possible")
        check(EffectiveLanes.compute(policy: pol(companyJSON.replacingOccurrences(of: "\"asr_cloud\":\"allow\"", with: "\"asr_cloud\":\"deny\"")), localOnly: false,
                                     settings: settings(["ASR_ENGINE": engine, "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "this-mac", "a denied asr_cloud lane: \(engine) is not possible")
        check(EffectiveLanes.compute(policy: providersAllowed, localOnly: true, settings: settings(["ASR_ENGINE": engine, "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "local-only",
              "a local-only meeting: \(engine) is not possible")
    }
    check(EffectiveLanes.compute(policy: providersAllowed, localOnly: false, settings: settings(["ASR_ENGINE": "clova", "ASR_FALLBACK": "openai-compat", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "chosen-server"
          && EffectiveLanes.compute(policy: providersAllowed, localOnly: false, settings: settings(["ASR_ENGINE": "openai-compat", "ASR_FALLBACK": "azure", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "chosen-server",
          "a server the user named wins over another external engine: it is the destination nobody can check")
    let noRemote = pol(companyJSON.replacingOccurrences(of: "\"asr_remote\":\"allow\"", with: "\"asr_remote\":\"deny\""))
    check(EffectiveLanes.compute(policy: noRemote, localOnly: false, settings: settings(["ASR_ENGINE": "remote", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "this-mac", "a denied asr_remote lane: this Mac")
    let engineList = pol(companyJSON.replacingOccurrences(of: "[\"whisper\",\"remote\",\"azure\"]", with: "[\"whisper\"]"))
    check(EffectiveLanes.compute(policy: engineList, localOnly: false, settings: settings(["ASR_ENGINE": "remote", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).asr == "this-mac", "an engine outside allowed_engines is not possible")
    check(EffectiveLanes.compute(policy: company, localOnly: false, settings: settings([:]), archiveDir: team, home: home).archive == "this-mac", "company without an explicit ARCHIVE_DIR: no Drive lane, this Mac")
    check(EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["ARCHIVE_DIR": myDrive.path]), archiveDir: myDrive, home: home).archive == "this-mac", "an ARCHIVE_DIR outside archive.allowed_roots: this Mac")
    let strict = EffectiveLanes.compute(policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}"), localOnly: false, settings: explicit, archiveDir: team, home: home)
    check(strict == EffectiveLanes(asr: "this-mac", note: false, calendar: false, archive: "this-mac", orgManaged: true) && strict.summaryText == "이 회의: 전사=이 Mac · 회의록=꺼짐 · 보관=이 Mac", "a company baseline policy: nothing leaves", "\(strict)")
    let invalid = EffectiveLanes.compute(policy: pol("{\"typo\":1}"), localOnly: false, settings: explicit, archiveDir: team, home: home)
    check(invalid.asr == "local-only" && !invalid.note && !invalid.calendar && invalid.archive == "this-mac", "a locked policy: local-only even if the caller passed false", "\(invalid)")
    let locked = EffectiveLanes.compute(policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"local_only\":{\"locked\":true}}"), localOnly: false, settings: explicit, archiveDir: team, home: home)
    check(locked.asr == "local-only", "local_only.locked forces local-only too")
    check(!EffectiveLanes.compute(policy: company, localOnly: false, settings: settings(["CALENDAR_LOOKUP": "0", "ARCHIVE_DIR": team.path]), archiveDir: team, home: home).calendar, "CALENDAR_LOOKUP=0 turns the calendar off")

    // no false claim, whatever the combination
    var texts: [String] = []
    for policy in [OrgPolicy.absent(), company, pol("{\"typo\":1}"), noRemote] {
        for localOnlyFlag in [false, true] {
            for engine in PrivacySettings.engineWords {
                let lanes = EffectiveLanes.compute(policy: policy, localOnly: localOnlyFlag, settings: settings(["ASR_ENGINE": engine, "ARCHIVE_DIR": team.path]), archiveDir: team, home: home)
                texts.append(contentsOf: lanes.idleLinesText + [lanes.summaryText])
            }
        }
    }
    let forbidden = ["떠나지", "나가지 않", "never leaves", "외부로 나가지"]
    check(!texts.contains(where: { text in forbidden.contains(where: { text.contains($0) }) }), "no text claims that the audio never leaves this Mac (Drive archives the m4a)")
    check(texts.allSatisfy { $0.count <= 45 }, "every line is short (the notification around it has 100 characters)", "\(texts.map { $0.count }.max() ?? 0)")
}

// MARK: - Pipeline contract and runtime trust

private func testPipelineContract(_ base: URL) {
    section("PipelineContract, PipelineVersionProbe")
    for (text, want) in [("0.2.0", [0, 2, 0]), ("0.10.0", [0, 10, 0]), (" 1.0 ", [1, 0]), ("1", [1]), ("1.2.3.4", [1, 2, 3, 4]), ("000001.2", [1, 2])] {
        check(PipelineContract.parseVersion(text) ?? [] == want, "parseVersion(\(text.debugDescription)) = \(want)")
    }
    for bad in ["", "x", "1..2", "1.2.3.4.5", "-1.0", "v1.0", "1.0-beta", "0.2.0\u{00A0}", "\u{FF10}.\u{FF12}.\u{FF10}", "\u{0660}.\u{0662}", "1.2.", ".1", "1234567.1", "0.2.0\n", "\t0.2.0"] {
        check(PipelineContract.parseVersion(bad) == nil, "parseVersion refuses \(bad.debugDescription)")
    }
    check(PipelineContract.versionLess([0, 9, 9], [0, 10]) && !PipelineContract.versionLess([0, 2], [0, 2, 0]) && !PipelineContract.versionLess([0, 2, 0], [0, 2]) && PipelineContract.versionLess([0, 2], [0, 2, 1]), "the shorter tuple is padded with zeros")
    let open = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}")
    check(PipelineContract.required(policy: .absent(), sessionLocalOnly: nil) == nil && PipelineContract.required(policy: .absent(), sessionLocalOnly: false) == nil, "the personal install without a policy needs nothing (an old pipeline keeps working)")
    check(PipelineContract.required(policy: .absent(), sessionLocalOnly: true) == "0.2.0", "a local-only session needs the contract even without a policy")
    check(PipelineContract.required(policy: open, sessionLocalOnly: false) == "0.2.0", "a policy needs 0.2.0")
    check(PipelineContract.required(policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"min_pipeline_version\":\"0.10.0\"}"), sessionLocalOnly: nil) == "0.10.0", "min_pipeline_version above 0.2.0 wins (as a tuple of integers)")
    check(PipelineContract.required(policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"min_pipeline_version\":\"0.1.0\"}"), sessionLocalOnly: nil) == "0.2.0", "min_pipeline_version below 0.2.0 does not lower the requirement")
    check(PipelineContract.required(policy: pol("{\"typo\":1}"), sessionLocalOnly: nil) == "0.2.0", "a locked policy needs the contract too")
    check(PipelineContract.satisfied(version: "0.2.0", required: "0.2.0") && PipelineContract.satisfied(version: "0.10.0", required: "0.2.0") && PipelineContract.satisfied(version: "0.2", required: "0.2.0")
          && !PipelineContract.satisfied(version: "0.1.9", required: "0.2.0") && !PipelineContract.satisfied(version: "garbage", required: "0.2.0") && !PipelineContract.satisfied(version: "0.2.0", required: "garbage"), "satisfied: tuple of integers, garbage is never satisfied")

    check(PipelineVersionProbe.parse("mcap 0.2.0\n") == "0.2.0" && PipelineVersionProbe.parse("usage: mcap [-h]") == nil && PipelineVersionProbe.parse("") == nil, "the --version output is parsed")
    let project = base.appendingPathComponent("probe-project", isDirectory: true)
    let marker = project.appendingPathComponent("pipeline/mcap/__init__.py")
    write("__version__ = \"0.2.0\"\n", to: marker)
    let python = URL(fileURLWithPath: "/tmp/fake-python")
    var runs = 0
    let probe = PipelineVersionProbe()
    let runner: PipelineVersionProbe.Runner = { _, dir in runs += 1; return dir.lastPathComponent == "pipeline" ? "mcap 0.2.0\n" : nil }
    check(probe.version(pythonBin: python, projectDir: project, runner: runner) == "0.2.0" && probe.version(pythonBin: python, projectDir: project, runner: runner) == "0.2.0" && runs == 1, "the version is cached per python and __init__.py (one process for two calls)", "runs \(runs)")
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: marker.path)
    _ = probe.version(pythonBin: python, projectDir: project, runner: runner)
    check(runs == 2, "a changed __init__.py (a new pipeline) is looked at again", "runs \(runs)")
    _ = probe.version(pythonBin: URL(fileURLWithPath: "/tmp/other-python"), projectDir: project, runner: runner)
    check(runs == 3, "another python is another cache entry")
    let bin = base.appendingPathComponent("probe-bin", isDirectory: true)
    let fake = bin.appendingPathComponent("python")
    write("#!/bin/sh\n[ \"$1 $2 $3\" = \"-m mcap --version\" ] || exit 9\ncase \"$PWD\" in */pipeline) ;; *) exit 8 ;; esac\necho \"mcap 0.3.1\"\n", to: fake, mode: 0o755)
    check(PipelineVersionProbe().version(pythonBin: fake, projectDir: project) == "0.3.1", "the real runner starts `python -m mcap --version` (a fake python script) and reads the version", "\(String(describing: PipelineVersionProbe.runPython(fake, project.appendingPathComponent("pipeline"))))")
    let failing = bin.appendingPathComponent("python-fails")
    write("#!/bin/sh\nexit 3\n", to: failing, mode: 0o755)
    check(PipelineVersionProbe().version(pythonBin: failing, projectDir: project) == nil && PipelineVersionProbe().version(pythonBin: bin.appendingPathComponent("missing"), projectDir: project) == nil, "a failing or missing python is no version (nil)")
}

private func testRuntimeTrust(_ base: URL) {
    section("RuntimeTrust: company runtime only from a root-owned release folder")
    let company = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/mcap/releases\"}}")
    let python = URL(fileURLWithPath: "/opt/mcap/releases/current/venv/bin/python")
    let project = URL(fileURLWithPath: "/opt/mcap/releases/current")
    let realpath: (String) -> String = { $0.replacingOccurrences(of: "/releases/current", with: "/releases/1.0.0") }     // current -> 1.0.0
    func rootOwned(_ extra: [String: OrgPolicy.FileInfo] = [:]) -> (URL) -> OrgPolicy.FileInfo? {
        return { url in extra[url.path] ?? rootDirectory }
    }
    check(RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: company, fileInfo: rootOwned(), realpath: realpath) == .ok, "everything root-owned and not writable: ok")
    let policyWithSlash = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/MCAP/releases/\"}}")
    check(RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: policyWithSlash, fileInfo: rootOwned(), realpath: realpath) == .ok, "the root is compared by components, case-folded, trailing slash ignored")
    let outside = RuntimeTrust.verify(pythonBin: URL(fileURLWithPath: "/Users/alice/venv/bin/python"), projectDir: project, policy: company, fileInfo: rootOwned(), realpath: realpath)
    check(outside == .untrusted("python: outside the runtime root"), "python outside the root is untrusted", "\(outside)")
    let evil = RuntimeTrust.verify(pythonBin: python, projectDir: URL(fileURLWithPath: "/opt/mcap/releases-evil/current"), policy: company, fileInfo: rootOwned(), realpath: realpath)
    check(evil == .untrusted("pipeline: outside the runtime root"), "'releases-evil' is not inside 'releases' (whole components)", "\(evil)")
    let userOwned = OrgPolicy.FileInfo(isRegular: false, isSymlink: false, uid: 501, mode: 0o755, size: 0)
    let notRoot = RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: company, fileInfo: rootOwned(["/opt/mcap/releases/1.0.0/venv": userOwned]), realpath: realpath)
    check(notRoot == .untrusted("python: not owned by root"), "one component owned by a user is untrusted", "\(notRoot)")
    let writable = OrgPolicy.FileInfo(isRegular: false, isSymlink: false, uid: 0, mode: 0o775, size: 0)
    let groupWritable = RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: company, fileInfo: rootOwned(["/opt/mcap": writable]), realpath: realpath)
    check(groupWritable == .untrusted("python: writable by group or others"), "one component writable by the group is untrusted (an ancestor too)", "\(groupWritable)")
    let rootDir = RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: company, fileInfo: rootOwned(["/": userOwned]), realpath: realpath)
    check(rootDir == .untrusted("python: not owned by root"), "even '/' is checked")
    let unreadable = RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: company, fileInfo: { $0.path == "/opt/mcap/releases/1.0.0/pipeline" ? nil : rootDirectory }, realpath: realpath)
    check(unreadable == .untrusted("pipeline: cannot be inspected"), "a component that cannot be inspected is untrusted", "\(unreadable)")
    let pythonOwned = OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: 501, mode: 0o755, size: 10)
    check(RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: company, fileInfo: rootOwned(["/opt/mcap/releases/1.0.0/venv/bin/python": pythonOwned]), realpath: realpath) == .untrusted("python: not owned by root"), "the python file itself must be root-owned")
    for (name, policy) in [("no policy", OrgPolicy.absent()), ("personal", pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"runtime\":{\"root\":\"/opt/x\"}}")),
                           ("company without runtime.root", pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}")),
                           ("a locked personal policy", pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":1}"))] {
        check(RuntimeTrust.verify(pythonBin: URL(fileURLWithPath: "/Users/alice/python"), projectDir: URL(fileURLWithPath: "/Users/alice/p"), policy: policy, fileInfo: { _ in nil }) == .ok, "\(name): nothing to verify (the personal install keeps PYTHON_BIN and PROJECT_DIR)")
    }

    // a LOCKED policy that does not say personal keeps the requirement (the strictest state is not the loosest runtime check)
    let userPython = URL(fileURLWithPath: "/Users/alice/venv/bin/python"), userProject = URL(fileURLWithPath: "/Users/alice/project")
    let packagePython = URL(fileURLWithPath: OrgPolicy.defaultRuntimeRoot + "/current/venv/bin/python"), packageProject = URL(fileURLWithPath: OrgPolicy.defaultRuntimeRoot + "/current")
    let identity: (String) -> String = { $0 }
    for (name, policy) in [("a policy that cannot be read at all", pol("{\"typo\":1}")), ("a locked company policy without a runtime.root", pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1}"))] {
        check(RuntimeTrust.verify(pythonBin: userPython, projectDir: userProject, policy: policy, fileInfo: rootOwned(), realpath: identity) == .untrusted("python: outside the runtime root"),
              "\(name): a python in the user's folders is untrusted (the package runtime is required)")
        check(RuntimeTrust.verify(pythonBin: packagePython, projectDir: packageProject, policy: policy, fileInfo: rootOwned(), realpath: identity) == .ok, "\(name): the root-owned package runtime is trusted")
        check(RuntimeTrust.verify(pythonBin: packagePython, projectDir: packageProject, policy: policy, fileInfo: rootOwned([packagePython.path: pythonOwned]), realpath: identity) == .untrusted("python: not owned by root"),
              "\(name): ... and its owner and mode are checked like a company runtime")
    }
    let lockedNamed = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"/opt/mcap/releases\"},\"typo\":1}")
    check(RuntimeTrust.verify(pythonBin: python, projectDir: project, policy: lockedNamed, fileInfo: rootOwned(), realpath: realpath) == .ok
          && RuntimeTrust.verify(pythonBin: packagePython, projectDir: packageProject, policy: lockedNamed, fileInfo: rootOwned(), realpath: identity) == .untrusted("python: outside the runtime root"),
          "a locked policy whose file named a runtime root is held to THAT root, not to the package default")

    // The DEFAULT symlink resolution (every check above injects its own): a link inside the root that leads out of it is outside.
    let tree = base.appendingPathComponent("trust-links", isDirectory: true)
    let releases = tree.appendingPathComponent("releases", isDirectory: true)
    let elsewhere = tree.appendingPathComponent("elsewhere", isDirectory: true)
    for dir in ["1.0.0/venv/bin", "1.0.0/pipeline", "2.0.0/venv/bin"] { makeDir(releases.appendingPathComponent(dir, isDirectory: true)) }
    for dir in ["venv/bin", "pipeline"] { makeDir(elsewhere.appendingPathComponent(dir, isDirectory: true)) }
    write("#!/bin/sh\n", to: releases.appendingPathComponent("1.0.0/venv/bin/python"), mode: 0o755)
    write("#!/bin/sh\n", to: releases.appendingPathComponent("2.0.0/venv/bin/python"), mode: 0o755)
    write("#!/bin/sh\n", to: elsewhere.appendingPathComponent("venv/bin/python"), mode: 0o755)
    let links = FileManager.default
    try? links.createSymbolicLink(at: releases.appendingPathComponent("current"), withDestinationURL: releases.appendingPathComponent("1.0.0"))           // in the root, to the root
    try? links.createSymbolicLink(at: releases.appendingPathComponent("escape"), withDestinationURL: elsewhere)                                        // in the root, out of it
    try? links.createSymbolicLink(at: releases.appendingPathComponent("2.0.0/pipeline"), withDestinationURL: elsewhere.appendingPathComponent("pipeline"))   // only the pipeline leaves
    try? links.createSymbolicLink(at: releases.appendingPathComponent("latest"), withDestinationURL: releases.appendingPathComponent("2.0.0"))
    let linkPolicy = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"runtime\":{\"root\":\"\(releases.path)\"}}")
    func viaLink(_ release: String) -> RuntimeTrust.Verdict {
        let folder = releases.appendingPathComponent(release, isDirectory: true)
        return RuntimeTrust.verify(pythonBin: folder.appendingPathComponent("venv/bin/python"), projectDir: folder, policy: linkPolicy, fileInfo: { _ in rootDirectory })     // the default realpath
    }
    check(linkPolicy.isCompany && linkPolicy.runtimeRoot == releases.path, "the symlink test policy carries the temp release folder", "\(linkPolicy.state) \(String(describing: linkPolicy.runtimeRoot))")
    check(viaLink("1.0.0") == .ok && viaLink("current") == .ok, "a release folder, and a link inside the root to another folder inside it, are trusted (default resolution)", "\(viaLink("current"))")
    check(viaLink("escape") == .untrusted("python: outside the runtime root"), "a link inside the root that leads out of it is outside (python)", "\(viaLink("escape"))")
    check(viaLink("latest") == .untrusted("pipeline: outside the runtime root"), "a pipeline folder that is a link out of the root is outside (python itself is inside)", "\(viaLink("latest"))")
}

// MARK: - session.json patch, private sidecar

private func testSessionJSONPatch(_ base: URL) {
    section("SessionJSONPatch: keeps every other key, atomic, read back")
    let dir = base.appendingPathComponent("patch", isDirectory: true)
    makeDir(dir)
    let session = dir.appendingPathComponent("2026-10-14_1400_zoom", isDirectory: true)
    makeDir(session)
    let original: [String: Any] = ["schema": 1, "session_id": "2026-10-14_1400_zoom", "end_time": NSNull(), "warnings": ["one", "two"], "sample_rate": 48000,
                                   "tracks": ["mic": ["file": "mic.wav", "seconds": 12.5, "ok": true], "remote": ["file": "remote.wav", "seconds": 0.1]], "title_hint": "Weekly sync 한글"]
    let file = session.appendingPathComponent("session.json")
    try? JSONSerialization.data(withJSONObject: original, options: SessionJSONPatch.options).write(to: file)
    func without(_ o: [String: Any]?) -> NSDictionary { var m = o ?? [:]; m.removeValue(forKey: "local_only"); m.removeValue(forKey: "local_only_source"); return NSDictionary(dictionary: m) }

    do { try SessionJSONPatch.apply(localOnly: true, source: "menu-after-stop", to: session, now: Date()) } catch { check(false, "patch ON", "\(error)") }
    var obj = readJSONObject(file)
    check((obj?["local_only"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true && obj?["local_only_source"] as? String == "menu-after-stop", "local_only is a real JSON boolean and the source is there", "\(String(describing: obj))")
    check(without(obj).isEqual(to: NSDictionary(dictionary: original)), "every other key is unchanged (nested objects, null, floats, non-ASCII)", "\(String(describing: obj))")
    do { try SessionJSONPatch.apply(localOnly: false, source: "menu", to: session) } catch { check(false, "patch OFF", "\(error)") }
    obj = readJSONObject(file)
    check((obj?["local_only"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } == true && obj?["local_only_source"] as? String == "menu" && without(obj).isEqual(to: NSDictionary(dictionary: original)), "patching again replaces the two keys and still keeps the rest")
    check(((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []) == ["session.json"], "no temp file is left behind (atomic write)", "\((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? [])")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(text.contains("\n  \"local_only\" : false") && text.range(of: "\"end_time\" : null") != nil, "the file keeps the sorted, pretty layout of the recorder", text)
    // Atomic means a NEW file renamed over the old one; a plain write would rewrite the same file in place (a reader could see half of it).
    func inode(_ url: URL) -> UInt64 { var st = stat(); return lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : 0 }
    let inodeBefore = inode(file)
    do { try SessionJSONPatch.apply(localOnly: true, source: "menu", to: session) } catch { check(false, "patch for the inode check", "\(error)") }
    check(inodeBefore != 0 && inode(file) != inodeBefore, "the default write replaces session.json atomically (a new file renamed over the old one), not in place", "\(inodeBefore) -> \(inode(file))")
    try? JSONSerialization.data(withJSONObject: original, options: SessionJSONPatch.options).write(to: file)        // back to the original for the seam tests below

    func fails(_ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) } catch { check(true, name) }
    }
    // The read-back is what stops a bad patch: writers that fail, stop half way, or put something else on disk.
    let pristine = (try? Data(contentsOf: file)) ?? Data()
    struct WriteFailed: Error {}
    func patchWith(_ writer: (Data, URL) throws -> Void) -> String? {
        do { try SessionJSONPatch.apply(localOnly: true, source: "menu", to: session, write: writer); return nil } catch { return "\(error)" }
    }
    func rewritten(_ change: @escaping (inout [String: Any]) -> Void) -> (Data, URL) throws -> Void {
        return { data, url in
            var object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            change(&object)
            try JSONSerialization.data(withJSONObject: object, options: SessionJSONPatch.options).write(to: url)
        }
    }
    var failure = patchWith { _, _ in throw WriteFailed() }
    check(failure != nil && (try? Data(contentsOf: file)) == pristine, "a write that fails makes apply throw and leaves session.json byte for byte as it was", "\(String(describing: failure))")
    failure = patchWith { data, url in try data.prefix(data.count / 2).write(to: url) }
    check(failure?.contains("does not hold the new local_only") == true, "a write that stops half way is caught by the read-back", "\(String(describing: failure))")
    try? pristine.write(to: file)
    failure = patchWith(rewritten { $0["local_only"] = false })
    check(failure?.contains("does not hold the new local_only") == true, "a flag that is not the one that was written (another writer was faster) is caught", "\(String(describing: failure))")
    failure = patchWith(rewritten { $0["local_only"] = 1 })
    check(failure?.contains("does not hold the new local_only") == true, "a flag that is a number, not a JSON boolean, is caught", "\(String(describing: failure))")
    failure = patchWith(rewritten { $0["local_only_source"] = "menu-after-stop" })
    check(failure?.contains("does not hold the new local_only") == true, "a source that is not the one that was written is caught", "\(String(describing: failure))")
    failure = patchWith(rewritten { $0.removeValue(forKey: "local_only") })
    check(failure?.contains("does not hold the new local_only") == true, "a lost flag is caught", "\(String(describing: failure))")
    failure = patchWith(rewritten { $0.removeValue(forKey: "warnings") })
    check(failure?.contains("changed in other keys") == true, "a key of the original that went missing is caught", "\(String(describing: failure))")
    failure = patchWith(rewritten { $0["sample_rate"] = 44100 })
    check(failure?.contains("changed in other keys") == true, "a key of the original that changed its value is caught", "\(String(describing: failure))")
    failure = patchWith(rewritten { $0["added_by_someone"] = true })
    check(failure?.contains("changed in other keys") == true, "a key that appeared is caught as well", "\(String(describing: failure))")
    try? pristine.write(to: file)
    check(patchWith(rewritten { _ in }) == nil, "control: another writer that stores exactly the patched object is accepted (the read-back is not just 'always throw')")
    try? JSONSerialization.data(withJSONObject: original, options: SessionJSONPatch.options).write(to: file)

    fails("a source with a blank or capital letters is refused") { try SessionJSONPatch.apply(localOnly: true, source: "Menu now", to: session) }
    fails("an empty source is refused") { try SessionJSONPatch.apply(localOnly: true, source: "", to: session) }
    fails("a missing session.json is an error") { try SessionJSONPatch.apply(localOnly: true, source: "menu", to: dir.appendingPathComponent("nothing")) }
    let broken = dir.appendingPathComponent("broken", isDirectory: true)
    write("{not json", to: broken.appendingPathComponent("session.json"))
    fails("a session.json that is not JSON is an error") { try SessionJSONPatch.apply(localOnly: true, source: "menu", to: broken) }
    check((try? String(contentsOf: broken.appendingPathComponent("session.json"), encoding: .utf8)) == "{not json", "... and it is left as it was")
    let array = dir.appendingPathComponent("array", isDirectory: true)
    write("[1,2]", to: array.appendingPathComponent("session.json"))
    fails("a session.json that is a JSON array is an error") { try SessionJSONPatch.apply(localOnly: true, source: "menu", to: array) }
    let linked = dir.appendingPathComponent("linked", isDirectory: true)
    makeDir(linked)
    try? FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("session.json"), withDestinationURL: file)
    fails("a session.json that is a symlink is refused") { try SessionJSONPatch.apply(localOnly: true, source: "menu", to: linked) }
}

private func testSessionPrivateLog(_ base: URL) {
    section("SessionPrivateLog: history in the private sidecar, capped at 20, never in the session folder")
    let support = base.appendingPathComponent("private-support", isDirectory: true)
    let id = "2026-10-14_1400_zoom"
    var appended = 0
    for i in 1...25 where SessionPrivateLog.append(session: id, supportDir: support, entry: ["n": i, "to": i % 2 == 0, "source": "menu"]) { appended += 1 }
    check(appended == 25, "25 appends succeed", "\(appended)")
    let object = SessionPrivateLog.read(session: id, supportDir: support)
    let history = object?[SessionPrivateLog.historyKey] as? [[String: Any]] ?? []
    check(history.count == 20 && history.first?["n"] as? Int == 6 && history.last?["n"] as? Int == 25, "25 entries keep the newest 20 in order", "\(history.map { $0["n"] ?? "?" })")
    let url = SessionPrivateLog.file(session: id, supportDir: support)!
    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let dirAttrs = (try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)) ?? [:]
    check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "the file is 0600 and its folder 0700", "\(String(describing: attrs[.posixPermissions])) \(String(describing: dirAttrs[.posixPermissions]))")
    check(url.path == support.path + "/session-private/\(id).json", "the sidecar lives in SUPPORT_DIR/session-private/<id>.json (not in the session folder that goes to Drive)", url.path)
    check(SessionPrivateLog.append(session: id, supportDir: support, entry: ["start": 1.5, "end": 2.5], key: "mute_spans", maxEntries: 3), "another list in the same file (mute spans)")
    for k in 0..<4 { _ = SessionPrivateLog.append(session: id, supportDir: support, entry: ["start": Double(k)], key: "mute_spans", maxEntries: 3) }
    let both = SessionPrivateLog.read(session: id, supportDir: support)
    check((both?["mute_spans"] as? [Any])?.count == 3 && (both?[SessionPrivateLog.historyKey] as? [Any])?.count == 20, "a second key has its own cap and leaves the history alone")
    for bad in ["", ".", "..", "../x", "a/b", "a b", String(repeating: "x", count: 201), "é"] {
        check(!SessionPrivateLog.append(session: bad, supportDir: support, entry: ["n": 1]) && SessionPrivateLog.file(session: bad, supportDir: support) == nil, "session id \(bad.prefix(12).debugDescription) is refused (no path escape)")
    }
    check(!SessionPrivateLog.append(session: id, supportDir: support, entry: ["when": Date()]), "an entry that is not JSON is refused")
    check(SessionPrivateLog.read(session: "never-written", supportDir: support) == nil, "nothing written, nothing read")

    // Two lists of one file are written from different threads (the history from the controller queue, the mute spans from the recorder):
    // every append survives (an unserialised read-modify-write lost half of them).
    let raceSupport = base.appendingPathComponent("private-race", isDirectory: true)
    let raceID = "2026-10-14_1500_teams"
    let keys = [SessionPrivateLog.historyKey, "mute_spans"]
    let finished = DispatchSemaphore(value: 0)
    for worker in 0..<4 {
        let thread = Thread {
            for n in 0..<60 { SessionPrivateLog.append(session: raceID, supportDir: raceSupport, entry: ["w": worker, "n": n], key: keys[worker % 2], maxEntries: 200) }
            finished.signal()
        }
        thread.start()
    }
    for _ in 0..<4 { finished.wait() }
    let raced = SessionPrivateLog.read(session: raceID, supportDir: raceSupport)
    for key in keys {
        let items = raced?[key] as? [[String: Any]] ?? []
        let ids = Set(items.map { "\($0["w"] ?? "?")-\($0["n"] ?? "?")" })
        check(items.count == 120 && ids.count == 120, "four threads, two lists, one file: all 120 entries of \(key) survive (none lost, none twice)", "\(items.count) entries, \(ids.count) distinct")
    }
}

// MARK: - LogRotation

private func testLogRotation(_ base: URL) {
    section("LogRotation: size, count, age")
    let fm = FileManager.default
    let dir = base.appendingPathComponent("rotation", isDirectory: true)
    makeDir(dir)
    let log = dir.appendingPathComponent("app.log")
    func put(_ marker: String, size: Int = 100, url: URL? = nil) { try? (marker + String(repeating: "x", count: size)).write(to: url ?? log, atomically: true, encoding: .utf8) }
    func body(_ url: URL) -> String { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").prefix(2).description }
    func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    put("A1")
    check(!LogRotation.rotateIfNeeded(file: log, maxBytes: 1000, keep: 3, maxAgeDays: 0), "below the size: nothing happens")
    check(!LogRotation.rotateIfNeeded(file: log, maxBytes: 0, keep: 3, maxAgeDays: 0) && names() == ["app.log"], "APP_LOG_MAX_MB=0 (maxBytes 0) never rotates (today's behaviour)")
    check(!LogRotation.rotateIfNeeded(file: dir.appendingPathComponent("nothing.log"), maxBytes: 10, keep: 3, maxAgeDays: 30), "a missing file is no error")
    check(LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 3, maxAgeDays: 0) && names() == ["app.log.1"] && body(LogRotation.archive(log, 1)) == "A1", "at the size: app.log becomes app.log.1", "\(names())")
    put("B2"); _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 3, maxAgeDays: 0)
    put("C3"); _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 3, maxAgeDays: 0)
    check(names() == ["app.log.1", "app.log.2", "app.log.3"] && body(LogRotation.archive(log, 1)) == "C3" && body(LogRotation.archive(log, 2)) == "B2" && body(LogRotation.archive(log, 3)) == "A1", "archives shift: newest is .1", "\(names())")
    put("D4"); _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 3, maxAgeDays: 0)
    check(names() == ["app.log.1", "app.log.2", "app.log.3"] && body(LogRotation.archive(log, 3)) == "B2" && body(LogRotation.archive(log, 1)) == "D4", "count: only `keep` archives stay, the oldest falls off", "\(names())")
    put("E5", size: 10)
    check(!LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 3, maxAgeDays: 0) && body(log) == "E5", "a small active file is kept")

    // count lowered: archives beyond keep are removed even without a rotation
    _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 1000, keep: 1, maxAgeDays: 0)
    check(names() == ["app.log", "app.log.1"], "keep=1: .2 and .3 are removed", "\(names())")
    // keep 1: the next rotation replaces .1
    put("F6"); _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 1, maxAgeDays: 0)
    check(names() == ["app.log.1"] && body(LogRotation.archive(log, 1)) == "F6", "keep=1: a rotation replaces the single archive", "\(names())")
    // keep 0: no archive at all
    put("G7"); _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 50, keep: 0, maxAgeDays: 0)
    check(names().isEmpty, "keep=0: the full file is removed and no archive is kept", "\(names())")

    // age
    let now = Date()
    put("H8", size: 10)
    put("O1", url: LogRotation.archive(log, 1)); put("O2", url: LogRotation.archive(log, 2)); put("O3", url: LogRotation.archive(log, 3))
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: LogRotation.archive(log, 1).path)
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-5 * 86_400)], ofItemAtPath: LogRotation.archive(log, 2).path)
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: LogRotation.archive(log, 3).path)
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: log.path)
    _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 1000, keep: 5, maxAgeDays: 30, now: now)
    check(names() == ["app.log", "app.log.2"], "age: archives older than 30 days go, a 5-day-old one stays, the ACTIVE file is never removed by age", "\(names())")
    _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 1000, keep: 5, maxAgeDays: 0, now: now.addingTimeInterval(400 * 86_400))
    check(names() == ["app.log", "app.log.2"], "maxAgeDays 0 never deletes by age")
    // files that only look like archives are not touched
    put("N1", url: dir.appendingPathComponent("app.log.old")); put("N2", url: dir.appendingPathComponent("app.logx.1")); put("N3", url: dir.appendingPathComponent("other.log.1"))
    _ = LogRotation.rotateIfNeeded(file: log, maxBytes: 1000, keep: 1, maxAgeDays: 1, now: now.addingTimeInterval(400 * 86_400))
    check(names() == ["app.log", "app.log.old", "app.logx.1", "other.log.1"], "only app.log.<number> files are archives of app.log", "\(names())")
}

// MARK: - setup, lane-aware

private func testSetupLaneAware(_ base: URL) {
    section("setup is lane-aware: a denied lane is `skipped`, not FAIL; local-only checks LOCAL_ARCHIVE_DIR")
    let fm = FileManager.default
    let root = base.appendingPathComponent("setup", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let configFile = root.appendingPathComponent("config.env")
    makeDir(bin)
    let claude = bin.appendingPathComponent("claude")
    write("#!/bin/sh\necho '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"pro\"}'\n", to: claude, mode: 0o755)
    write("SELF_NAME=Tester\n", to: configFile)

    func fresh(_ name: String) -> (config: AppConfig, support: URL, archive: URL) {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let support = dir.appendingPathComponent("support", isDirectory: true)
        let project = dir.appendingPathComponent("project", isDirectory: true)
        let python = dir.appendingPathComponent("python")
        makeDir(project.appendingPathComponent("pipeline/mcap"))
        for file in ["vocabulary.txt", "note_prompt.md"] { write("x", to: support.appendingPathComponent(file)) }
        write("#!/bin/sh\nexit 0\n", to: python, mode: 0o755)
        var config = AppConfig.defaults()
        config.supportDir = support; config.projectDir = project; config.pythonBin = python; config.claudeBin = claude
        config.archiveDir = dir.appendingPathComponent("archive/Meetings", isDirectory: true)
        config.enabledPlatforms = [.zoom, .teams]
        config.claudeAuth = .subscription          // these cases are about lanes; the billing mode is set explicitly where it matters (api is the default)
        return (config, support, config.archiveDir)
    }
    func run(_ config: AppConfig, policy: OrgPolicy?, version: String? = "0.2.0", info: @escaping (URL) -> OrgPolicy.FileInfo? = { _ in rootDirectory },
             securityExists: Bool = true) -> (code: Int32, report: String) {
        var result: (Int32, String) = (-1, "")
        let hooks = SetupHooks(signedAppLaunch: true, environment: [:], capturePermissions: { ["microphone": "authorized", "system_audio": "ok"] },
                               chromePermission: { "authorized" }, notificationAuthorization: { .authorized }, logDir: logs, echo: false,
                               securityBin: URL(fileURLWithPath: "/nonexistent/security"),
                               runSecurity: { _, _ -> ToolResult? in securityExists ? (0, "", "") : (44, "", "") },
                               policy: policy ?? OrgPolicy.absent(), pipelineVersion: { _ in version }, fileInfo: info, deviceOf: { _ in 7 })
        withEnv("MCAP_CONFIG", configFile.path) { result = (runSetup(config: config, hooks: hooks), (try? String(contentsOf: logs.appendingPathComponent("setup-report.txt"), encoding: .utf8)) ?? "") }
        return result
    }
    let baseline = "{\"schema\":1,\"profile\":\"company\",\"revision\":3,\"min_pipeline_version\":\"0.2.0\"}"       // every lane deny

    // 1. company baseline: no claude, no Drive. The claude binary does not even exist and the Drive folder must not be created.
    var t = fresh("baseline")
    t.config.claudeBin = URL(fileURLWithPath: "/nonexistent/claude")
    var r = run(t.config, policy: pol(baseline))
    check(r.code == 0 && !r.report.contains("[FAIL]") && !r.report.contains("[WARN]"), "company baseline (all lanes deny): setup passes with no claude CLI and no Drive folder", "exit \(r.code)\n\(r.report)")
    check(r.report.contains("[ -- ] claude CLI: skipped: lane denied (llm: policy-lane, calendar: policy-lane)") && r.report.contains("[ -- ] claude billing: skipped: lane denied"), "the claude checks say `skipped: lane denied`", r.report)
    check(r.report.contains("[ -- ] ARCHIVE_DIR writable: skipped: lane denied (drive: policy-lane)"), "the ARCHIVE_DIR check says `skipped: lane denied`", r.report)
    check(!fm.fileExists(atPath: t.archive.path) && !fm.fileExists(atPath: t.archive.deletingLastPathComponent().path), "ARCHIVE_DIR is never touched (no Google Drive prompt, nothing created)")
    check(r.report.contains("[ OK ] LOCAL_ARCHIVE_DIR writable: ") && fm.fileExists(atPath: t.support.appendingPathComponent("local-meetings").path), "LOCAL_ARCHIVE_DIR is checked and created instead", r.report)
    check(r.report.contains("[ -- ] organisation policy: company revision 3") && r.report.contains("[ OK ] pipeline version: 0.2.0"), "the policy and the pipeline contract are reported", r.report)

    // 2. a locked local-only flag: the Drive and llm lanes are closed whatever the lanes say
    t = fresh("lockedflag")
    let openButLocked = "{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"local_only\":{\"default\":true,\"locked\":true}}"
    r = run(t.config, policy: pol(openButLocked))
    check(r.code == 0 && r.report.contains("skipped: lane denied (drive: local_only)") && r.report.contains("skipped: lane denied (llm: local_only") && r.report.contains("[ OK ] LOCAL_ARCHIVE_DIR writable"),
          "a locked local_only: skipped with the reason local_only, LOCAL_ARCHIVE_DIR checked", "exit \(r.code)\n\(r.report)")

    // 3. a policy that opens everything behaves like no policy (plus the policy line)
    t = fresh("open")
    let openPolicy = "{\"schema\":1,\"profile\":\"personal\",\"revision\":4}"
    r = run(t.config, policy: pol(openPolicy))
    check(r.code == 0 && !r.report.contains("lane denied") && r.report.contains("[ OK ] claude billing: subscription via claude.ai login") && r.report.contains("[ OK ] ARCHIVE_DIR writable") && !r.report.contains("LOCAL_ARCHIVE_DIR"),
          "an open personal policy: claude and ARCHIVE_DIR are checked as before, no LOCAL_ARCHIVE_DIR line", "exit \(r.code)\n\(r.report)")
    check(fm.fileExists(atPath: t.archive.path), "... and ARCHIVE_DIR is created and probed")
    t.config.claudeBin = URL(fileURLWithPath: "/nonexistent/claude")
    r = run(t.config, policy: pol(openPolicy))
    check(r.code == 1 && r.report.contains("[WARN] claude CLI: not found") && !r.report.contains("[FAIL]"),
          "... and under a personal-profile policy a missing claude CLI is only a [WARN] (audio and transcripts do not need it)", "exit \(r.code)\n\(r.report)")

    // 4. no policy: the same, and no new line at all
    t = fresh("none")
    r = run(t.config, policy: nil)
    check(r.code == 0 && !r.report.contains("organisation policy") && !r.report.contains("lane denied") && !r.report.contains("LOCAL_ARCHIVE_DIR") && !r.report.contains("pipeline version") && !r.report.contains("runtime"),
          "no policy: the report has none of the new lines", "exit \(r.code)\n\(r.report)")
    // LOCAL_ONLY_DEFAULT=1 alone (no policy) adds the LOCAL_ARCHIVE_DIR check but keeps the Drive check
    let localDefault = root.appendingPathComponent("localdefault.env")
    write("SELF_NAME=Tester\nLOCAL_ONLY_DEFAULT=1\n", to: localDefault)
    t = fresh("localdefault")
    var localOut: (Int32, String) = (-1, "")
    withEnv("MCAP_CONFIG", localDefault.path) {
        let hooks = SetupHooks(signedAppLaunch: true, environment: [:], capturePermissions: { ["microphone": "authorized", "system_audio": "ok"] }, chromePermission: { "authorized" },
                               notificationAuthorization: { .authorized }, logDir: logs, echo: false, policy: OrgPolicy.absent(), pipelineVersion: { _ in nil }, deviceOf: { _ in 7 })
        localOut = (runSetup(config: t.config, hooks: hooks), (try? String(contentsOf: logs.appendingPathComponent("setup-report.txt"), encoding: .utf8)) ?? "")
    }
    check(localOut.0 == 0 && localOut.1.contains("[ OK ] ARCHIVE_DIR writable") && localOut.1.contains("[ OK ] LOCAL_ARCHIVE_DIR writable"),
          "LOCAL_ONLY_DEFAULT=1: both folders are checked (a meeting may go to either)", "exit \(localOut.0)\n\(localOut.1)")

    // 5. a locked policy is a FAIL
    t = fresh("invalid")
    r = run(t.config, policy: pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"support\":{\"contact\":\"IT #help\"},\"typo\":true}"))
    check(r.code == 1 && r.report.contains("[FAIL] organisation policy: LOCKED (unknown-key: typo)") && r.report.contains("contact: IT #help") && r.report.contains("skipped: lane denied (llm: policy-locked"),
          "a locked policy is a [FAIL] with the reason and the contact, and every lane is skipped", "exit \(r.code)\n\(r.report)")
    check(r.report.contains("[FAIL] runtime: python: outside the runtime root"), "a locked company policy still checks the runtime (the lock keeps the requirement)", r.report)
    r = run(t.config, policy: pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":true}"))
    check(r.code == 1 && r.report.contains("[FAIL] organisation policy: LOCKED (unknown-key: typo)") && !r.report.contains("runtime"), "a locked personal policy checks no runtime", "exit \(r.code)\n\(r.report)")

    // 6. company runtime trust
    t = fresh("runtime")
    let runtimeRoot = t.config.projectDir.deletingLastPathComponent().appendingPathComponent("releases", isDirectory: true)
    let current = runtimeRoot.appendingPathComponent("1.0.0", isDirectory: true)
    makeDir(current.appendingPathComponent("pipeline/mcap")); makeDir(current.appendingPathComponent("venv/bin"))
    write("#!/bin/sh\nexit 0\n", to: current.appendingPathComponent("venv/bin/python"), mode: 0o755)
    for file in ["vocabulary.txt", "note_prompt.md"] { write("x", to: t.support.appendingPathComponent(file)) }
    t.config.projectDir = current
    t.config.pythonBin = current.appendingPathComponent("venv/bin/python")
    let withRuntime = "{\"schema\":1,\"profile\":\"company\",\"revision\":5,\"runtime\":{\"root\":\"\(runtimeRoot.path)\"}}"
    r = run(t.config, policy: pol(withRuntime))
    check(r.code == 0 && r.report.contains("[ OK ] runtime: python and the pipeline are in the root-owned release folder"), "a root-owned runtime under runtime.root passes", "exit \(r.code)\n\(r.report)")
    r = run(t.config, policy: pol(withRuntime), info: { _ in OrgPolicy.FileInfo(isRegular: false, isSymlink: false, uid: 501, mode: 0o755, size: 0) })
    check(r.code == 1 && r.report.contains("[FAIL] runtime: python: not owned by root"), "a runtime a user owns is a [FAIL]", "exit \(r.code)\n\(r.report)")
    var outside = t.config
    outside.pythonBin = URL(fileURLWithPath: "/tmp/elsewhere/python")
    r = run(outside, policy: pol(withRuntime))
    check(r.code == 1 && r.report.contains("[FAIL] runtime: python: outside the runtime root"), "python outside runtime.root is a [FAIL]", "exit \(r.code)\n\(r.report)")

    // 7. pipeline contract
    t = fresh("contract")
    r = run(t.config, policy: pol(baseline), version: "0.1.0")
    check(r.code == 1 && r.report.contains("[FAIL] pipeline version: 0.1.0 is older than 0.2.0"), "a pipeline older than the contract is a [FAIL]", "exit \(r.code)\n\(r.report)")
    r = run(t.config, policy: pol(baseline), version: nil)
    check(r.code == 1 && r.report.contains("[WARN] pipeline version: could not read the version"), "an unreadable pipeline version is a [WARN]", "exit \(r.code)\n\(r.report)")
    r = run(t.config, policy: pol(baseline.replacingOccurrences(of: "\"0.2.0\"", with: "\"0.10.0\"")), version: "0.2.0")
    check(r.report.contains("[FAIL] pipeline version: 0.2.0 is older than 0.10.0"), "min_pipeline_version raises the bar (tuple of integers)", r.report)

    // 8. only the calendar lane is open: the CLI is still needed for it
    t = fresh("calendaronly")
    let calendarOnly = "{\"schema\":1,\"profile\":\"company\",\"revision\":6,\"lanes\":{\"calendar\":\"allow\"},\"approvals\":{\"calendar\":\"C-1\"}}"
    r = run(t.config, policy: pol(calendarOnly))
    check(r.code == 0 && r.report.contains("[ -- ] claude billing: skipped: lane denied (llm: policy-lane)") && r.report.contains("[ -- ] claude.ai login: logged in (pro), used for the Calendar title lookup only"),
          "llm denied but calendar allowed: billing skipped, the claude.ai login is still reported", "exit \(r.code)\n\(r.report)")
    t.config.claudeBin = URL(fileURLWithPath: "/nonexistent/claude")
    r = run(t.config, policy: pol(calendarOnly))
    check(r.code == 1 && r.report.contains("[FAIL] claude CLI: not found"), "... and a missing claude CLI is a [FAIL] there (the calendar lane needs it)", "exit \(r.code)\n\(r.report)")

    // 9. api billing with the calendar lane denied
    t = fresh("apicalendar")
    t.config.claudeAuth = .api
    let apiOnly = "{\"schema\":1,\"profile\":\"company\",\"revision\":7,\"lanes\":{\"llm\":\"allow\"},\"approvals\":{\"llm\":\"L-1\"},\"llm\":{\"claude_bin_pin\":{\"team_id\":\"ABCDE12345\"}}}"
    r = run(t.config, policy: pol(apiOnly))
    check(r.code == 0 && r.report.contains("[ OK ] claude billing: API key in the Keychain") && r.report.contains("[ -- ] calendar lookup: skipped: lane denied (calendar: policy-lane)") && !r.report.contains("claude.ai login"),
          "api billing is checked, the calendar notes are `skipped: lane denied` (the fake Keychain tool answers, the real one is never started)", "exit \(r.code)\n\(r.report)")

    t.config.claudeBin = URL(fileURLWithPath: "/nonexistent/claude")
    r = run(t.config, policy: pol(apiOnly))
    check(r.code == 1 && r.report.contains("[FAIL] claude CLI: not found") && !r.report.contains("[WARN] claude CLI"),
          "a company policy with the llm lane open keeps the [FAIL] for a missing claude CLI", "exit \(r.code)\n\(r.report)")

    // 10. a bad LOCAL_ARCHIVE_DIR is a FAIL (the allow-list)
    t = fresh("badlocal")
    let bad = root.appendingPathComponent("bad.env")
    write("SELF_NAME=Tester\nLOCAL_ARCHIVE_DIR=\(root.path)/outside-support\n", to: bad)
    var badOut: (Int32, String) = (-1, "")
    withEnv("MCAP_CONFIG", bad.path) {
        let hooks = SetupHooks(signedAppLaunch: true, environment: [:], capturePermissions: { ["microphone": "authorized", "system_audio": "ok"] }, chromePermission: { "authorized" },
                               notificationAuthorization: { .authorized }, logDir: logs, echo: false, policy: pol(baseline), pipelineVersion: { _ in "0.2.0" }, deviceOf: { _ in 7 })
        badOut = (runSetup(config: t.config, hooks: hooks), (try? String(contentsOf: logs.appendingPathComponent("setup-report.txt"), encoding: .utf8)) ?? "")
    }
    check(badOut.0 == 1 && badOut.1.contains("[FAIL] LOCAL_ARCHIVE_DIR:") && badOut.1.contains("outside-allowed-roots"), "a LOCAL_ARCHIVE_DIR outside SUPPORT_DIR is a [FAIL] (outside-allowed-roots)", "exit \(badOut.0)\n\(badOut.1)")
}

// MARK: - policy-status

private func testPolicyStatus(_ base: URL) {
    section("policy-status: content-free, --console-user reads the console user's config")
    let dir = base.appendingPathComponent("status", isDirectory: true)
    let home = dir.appendingPathComponent("console-home", isDirectory: true)
    let ownConfig = dir.appendingPathComponent("own.env")
    write("SELF_NAME=Tester\n", to: ownConfig)
    write("SELF_NAME=ConsoleUser\nLOCAL_ONLY_DEFAULT=1\nARCHIVE_DIR=~/Archive\nMIC_MUTE_GATE=weird\n", to: home.appendingPathComponent("Library/Application Support/MeetingCapture/config.env"))
    let company = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":12,\"min_pipeline_version\":\"0.2.0\",\"support\":{\"contact\":\"IT 헬프데스크\"},\"lanes\":{\"asr_remote\":\"allow\",\"drive\":\"allow\"},\"approvals\":{\"drive\":\"T-1\"},"
                      + "\"asr\":{\"allowed_engines\":[\"whisper\",\"remote\"]},\"archive\":{\"allowed_roots\":[\"~/Archive\"]},\"runtime\":{\"root\":\"/opt/mcap/releases\"}}")
    var probes = 0
    func hooks(_ policy: OrgPolicy, console: (name: String, home: String)? = nil, version: String? = "0.2.0", uid: uid_t = 501,
               info: @escaping (URL) -> OrgPolicy.FileInfo? = { _ in rootDirectory }) -> PolicyStatusHooks {
        return PolicyStatusHooks(loadPolicy: { policy }, consoleUser: { console }, pipelineVersion: { _ in probes += 1; return version }, fileInfo: info, currentHome: dir.path,
                                 configFile: ownConfig, effectiveUID: uid)
    }
    func run(_ args: [String], _ h: PolicyStatusHooks) -> (code: Int32, out: String, err: String) {
        var out = "", err = ""
        let code = runPolicyStatus(arguments: args, hooks: h, out: { out += $0 }, err: { err += $0 })
        return (code, out, err)
    }
    func json(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }

    var r = run(["--json"], hooks(company))
    var j = json(r.out)
    let policyBlock = j["policy"] as? [String: Any] ?? [:]
    check(r.code == 0 && j["schema"] as? Int == 1 && policyBlock["state"] as? String == "valid" && policyBlock["profile"] as? String == "company" && policyBlock["revision"] as? Int == 12 && (policyBlock["sha256_8"] as? String)?.count == 8,
          "--json: valid company policy, revision 12, the 8 digit hash", "exit \(r.code)\n\(r.out)")
    let lanes = j["lanes"] as? [String: String] ?? [:]
    check(lanes["asr_remote"] == "allow" && lanes["drive"] == "allow" && lanes["llm"] == "deny", "--json: the lanes", "\(lanes)")
    let start = j["local_only_start"] as? [String: Any] ?? [:]
    check(start["value"] as? Bool == false && start["source"] as? String == "default", "--json: the local-only start value", "\(start)")
    let contract = j["contract"] as? [String: Any] ?? [:]
    check(contract["required"] as? String == "0.2.0" && contract["pipeline_version"] as? String == "0.2.0" && contract["pipeline_too_old"] as? Bool == false && contract["satisfied"] as? Bool == true, "--json: the pipeline contract is met", "\(contract)")
    check((j["runtime"] as? [String: Any])?["verdict"] as? String == "ok", "--json: the company runtime under runtime.root, root-owned: ok", "\(String(describing: j["runtime"]))")
    let userOwned = OrgPolicy.FileInfo(isRegular: false, isSymlink: false, uid: 501, mode: 0o755, size: 0)
    let untrusted = json(run(["--json"], hooks(company, info: { _ in userOwned })).out)
    check((untrusted["runtime"] as? [String: Any])?["verdict"] as? String == "untrusted" && ((untrusted["runtime"] as? [String: Any])?["reason"] as? String)?.contains("not owned by root") == true,
          "--json: a runtime a user owns is untrusted, with the reason", "\(String(describing: untrusted["runtime"]))")
    let lowered = r.out.lowercased()
    check(!lowered.contains("title") && !lowered.contains("session") && !lowered.contains("slug") && !r.out.contains(dir.path) && !r.out.contains("Tester") && !r.out.contains("IT 헬프데스크"),
          "--json has no meeting title, no session id, no path, no user name and not even the support contact", r.out)

    r = run(["--json"], hooks(company, version: "0.1.0"))
    j = json(r.out)
    check((j["contract"] as? [String: Any])?["pipeline_too_old"] as? Bool == true && (j["contract"] as? [String: Any])?["satisfied"] as? Bool == false, "--json: an old pipeline is `pipeline_too_old`")
    r = run(["--json"], hooks(company, version: nil))
    j = json(r.out)
    check((j["contract"] as? [String: Any])?["pipeline_too_old"] is NSNull, "--json: an unreadable pipeline version is null, not a verdict")
    var asked = 0
    let counting = PolicyStatusHooks(loadPolicy: { .absent() }, consoleUser: { nil }, pipelineVersion: { _ in asked += 1; return "0.2.0" }, fileInfo: { _ in rootDirectory }, currentHome: dir.path, configFile: ownConfig)
    r = run(["--json"], counting)
    j = json(r.out)
    check(asked == 0 && (j["policy"] as? [String: Any])?["state"] as? String == "absent" && (j["contract"] as? [String: Any])?["required"] is NSNull && (j["contract"] as? [String: Any])?["pipeline_too_old"] as? Bool == false,
          "no policy: no python is started for the version, nothing is required", "asked \(asked)\n\(r.out)")

    r = run(["--json"], hooks(pol("{\"typo\":1}")))
    j = json(r.out)
    let lockedStart = j["local_only_start"] as? [String: Any] ?? [:]
    check((j["policy"] as? [String: Any])?["state"] as? String == "invalid" && ((j["policy"] as? [String: Any])?["locked_reason"] as? String)?.hasPrefix("unknown-key") == true && lockedStart["value"] as? Bool == true && lockedStart["locked"] as? Bool == true
          && (j["lanes"] as? [String: String])?.values.contains("allow") == false, "--json: a locked policy shows the reason, a forced start value and every lane deny", r.out)
    check((j["policy"] as? [String: Any])?["runtime_root_set"] as? Bool == true && (j["runtime"] as? [String: Any])?["verdict"] as? String == "ok",
          "--json: a locked policy that does not say personal still has a runtime root in force, and the package runtime is judged like a company one", r.out)
    let lockedUser = json(run(["--json"], hooks(pol("{\"typo\":1}"), info: { _ in userOwned })).out)
    check((lockedUser["runtime"] as? [String: Any])?["verdict"] as? String == "untrusted", "--json: under a lock a runtime a user owns is untrusted", "\(String(describing: lockedUser["runtime"]))")
    let lockedPersonalStatus = json(run(["--json"], hooks(pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":1}"), info: { _ in userOwned })).out)
    check((lockedPersonalStatus["policy"] as? [String: Any])?["runtime_root_set"] as? Bool == false && (lockedPersonalStatus["runtime"] as? [String: Any])?["verdict"] as? String == "ok",
          "--json: a locked personal policy has no runtime requirement")

    // MDM runs the command as root: a python a user can write must never be started with root's rights
    let personal = pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1}")
    let companyNoRoot = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1}")
    let lockedCompany = pol("{\"schema\":1,\"profile\":\"company\",\"revision\":1,\"typo\":1}")
    let lockedPersonal = pol("{\"schema\":1,\"profile\":\"personal\",\"revision\":1,\"typo\":1}")
    for (name, policy, uid, info, wantProbe) in [("a normal user, personal policy", personal, uid_t(501), rootDirectory, true), ("a normal user, company runtime", company, uid_t(501), rootDirectory, true),
                                                 ("root, company runtime verified root-owned", company, uid_t(0), rootDirectory, true), ("root, company runtime NOT root-owned", company, uid_t(0), userOwned, false),
                                                 ("root, personal policy (the python is the user's)", personal, uid_t(0), rootDirectory, false), ("root, company without runtime.root", companyNoRoot, uid_t(0), rootDirectory, false),
                                                 ("root, LOCKED company policy, the package runtime verified root-owned", lockedCompany, uid_t(0), rootDirectory, true),
                                                 ("root, LOCKED company policy, runtime NOT root-owned", lockedCompany, uid_t(0), userOwned, false),
                                                 ("root, locked personal policy (the python is the user's)", lockedPersonal, uid_t(0), rootDirectory, false)] {
        probes = 0
        let result = run(["--json"], hooks(policy, version: "0.2.0", uid: uid, info: { _ in info }))
        let contractBlock = json(result.out)["contract"] as? [String: Any] ?? [:]
        check((probes == 1) == wantProbe && (contractBlock["pipeline_version"] is NSNull) == !wantProbe, "\(name): python \(wantProbe ? "is" : "is NOT") started for the version", "probes \(probes) \(contractBlock)")
        if !wantProbe { check(contractBlock["satisfied"] is NSNull && contractBlock["pipeline_too_old"] is NSNull, "... and the verdict is null (unknown), not a guess") }
    }
    check(PolicyStatus.mayProbePipeline(effectiveUID: 0, policy: .absent(), trust: .ok) == false && PolicyStatus.mayProbePipeline(effectiveUID: 501, policy: .absent(), trust: .ok), "mayProbePipeline: absent policy, root: no; user: yes")

    // --console-user
    r = run(["--json", "--console-user"], hooks(.absent(), console: (name: "consoleuser", home: home.path)))
    j = json(r.out)
    let consoleStart = j["local_only_start"] as? [String: Any] ?? [:]
    check(r.code == 0 && consoleStart["value"] as? Bool == true && consoleStart["source"] as? String == "config-default" && (j["settings_warnings"] as? Int) == 1,
          "--console-user reads the console user's config.env (LOCAL_ONLY_DEFAULT=1, one warning for MIC_MUTE_GATE=weird), not the caller's", "exit \(r.code)\n\(r.out)")
    check(!r.out.contains("consoleuser") && !r.out.contains(home.path) && !r.out.contains("ConsoleUser"), "--console-user does not print the user's name or home")
    r = run(["--json"], hooks(.absent(), console: (name: "consoleuser", home: home.path)))
    j = json(r.out)
    check((j["local_only_start"] as? [String: Any])?["value"] as? Bool == false, "without --console-user the caller's own config is read")
    r = run(["--console-user"], hooks(.absent(), console: nil))
    check(r.code == 1 && r.out.isEmpty && r.err.contains("no user is logged in"), "--console-user without a console user: exit 1 and a message", "exit \(r.code) \(r.err)")
    r = run(["--bogus"], hooks(.absent()))
    check(r.code == 2 && r.err.contains("unknown option '--bogus'") && r.out.isEmpty, "an unknown option: exit 2")
    check(PolicyStatus.expandTilde(["A": "~", "B": "~/x", "C": "/y/~", "D": "~root/x"], home: "/Users/alice") == ["A": "/Users/alice", "B": "/Users/alice/x", "C": "/y/~", "D": "~root/x"], "~ of the console user's config means the console user's home")

    // the text form
    r = run([], hooks(company))
    check(r.code == 0 && r.out.hasPrefix("policy: valid (profile company, revision 12") && r.out.contains("lanes: asr_remote=allow asr_cloud=deny llm=deny calendar=deny drive=allow") && r.out.contains("pipeline: version 0.2.0, required 0.2.0")
          && r.out.contains("runtime: ok"), "the text form says the same in lines", r.out)
}
