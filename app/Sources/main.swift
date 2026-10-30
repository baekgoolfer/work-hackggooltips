import Foundation
import Darwin

// =====================================================================================
// Entry point and CLI dispatch (SPEC 6).
//
//   <short name>                       menu-bar app (what the LaunchAgent runs)
//   <short name> probe [--watch] [--json] [--all-platforms]
//   <short name> selftest-detector
//   <short name> selftest-capture --seconds N --out DIR (--synthetic | --live)
//   <short name> selftest-session      device-free SessionController scenarios (PASS/FAIL exit code)
//   <short name> selftest-policy       device-free organisation-policy self test (the shared config/policy-fixtures corpus, PASS/FAIL exit code)
//   <short name> selftest-firstrun --components FILE [--installed FILE]   reads the app installer's two records with the app's own parser (scripts/test_scripts.sh)
//   <short name> policy-status [--json] [--console-user]   policy state, local-only start value, lanes, contract (content-free, for MDM and support)
//   <short name> selftest-notify [--wait N]   posts one REAL sample notification of every kind (signed app only, see below)
//   <short name> setup                 first-install checklist, triggers the permission prompts
//   <short name> --version
//
// `setup`, `selftest-notify` and `selftest-capture --live` refuse (exit 2) unless the signed app was started by launchd / LaunchServices
// (LaunchGuard.isSignedAppLaunch, Types.swift): `open -n -W -a ~/Applications/<short name>.app --stdout "$(tty)" --stderr
// "$(tty)" --args <subcommand>`. Executing the in-bundle binary from a shell is refused, whatever its bundle id says.
//
// Test hooks (environment): MCAP_CONFIG=<config.env path>, MCAP_LOG_DIR=<dir for app.log/pipeline logs>,
// MC_LOG_STDERR=1 (echo log lines to stderr in app mode). On a policy-managed Mac (SPEC 18) MCAP_CONFIG and MCAP_LOG_DIR are ignored.
//
// System launch arguments ("-psn_...", leading "-NS*" / "-Apple*" pairs that AppKit adds after a crash restart) are
// ignored, see LaunchArguments.strip.
//
// <short name> is AppInfo.shortName (CATE unless the app was built with another MCAP_APP_SHORT_NAME); every message below is built from AppInfo.
// =====================================================================================

private func finish(_ code: Int32) -> Never {
    Log.flush()
    fflush(stdout)
    fflush(stderr)
    exit(code)
}

private func printUsage() {
    let text = """
    \(AppInfo.displayName) \(AppInfo.version)

    usage: \(AppInfo.shortName) [command]

      (no command)                       run the menu-bar app
      probe [--watch] [--json] [--all-platforms]
                                         print the current meeting-detection signals of the ENABLED_PLATFORMS
                                         (default zoom,teams); --all-platforms also shows the platforms that are off
      selftest-detector                  run the detection state-machine self test
      selftest-capture --seconds N --out DIR (--synthetic | --live)
                                         record both tracks for N seconds into DIR. One of the two flags is required:
                                         --synthetic = generated audio, no devices, no permissions (safe from a shell);
                                         --live = real microphone + system audio, shows permission prompts, only works
                                         when the signed app was started by LaunchServices (never from a shell exec):
                                         \(CapturePermissionGuard.openAppPrefix) ...
      selftest-session                   run the session-controller scenario self test (no devices needed)
      selftest-policy                    run the organisation-policy self test (no devices needed): reads config/policy-fixtures of the
                                         repository (run it from the repo root, or set MC_POLICY_FIXTURES=<dir>)
      selftest-firstrun --components FILE [--installed FILE]
                                         read components.json (and the helper's components-installed.json) with the app's own parser: exit 0
                                         when understood (and equal); used by scripts/test_scripts.sh against what the scripts write
      policy-status [--json] [--console-user]
                                         print the organisation policy state, the local-only start value, the lanes and the pipeline
                                         contract (no meeting titles or session ids). --console-user reads the HOME and config.env of
                                         the user logged in at the console (for MDM, which runs it as root)
      selftest-notify [--wait N]         post one real sample notification of every kind and wait N seconds (default 60) for clicks;
                                         same rule as setup (it shows real notifications): signed app started by LaunchServices only:
                                         \(CapturePermissionGuard.openAppPrefix) selftest-notify
      setup                              first-install checklist (triggers permission prompts); same rule as --live:
                                         \(CapturePermissionGuard.openAppPrefix) setup
      --version                          print the version

    """
    print(text, terminator: "")
}

/// Value of `--flag value` or `--flag=value`.
private func optionValue(_ flag: String, in args: [String]) -> String? {
    for (i, a) in args.enumerated() {
        if a == flag, i + 1 < args.count { return args[i + 1] }
        if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
    }
    return nil
}

private func mcapMain() -> Never {
    // Drop what the system adds on its own (Finder "-psn_", AppKit "-NSxxx YES" / "-ApplePersistenceIgnoreState YES"
    // after a crash restart): they must not turn a normal launch into "unknown command".
    let args = LaunchArguments.strip(Array(CommandLine.arguments.dropFirst()))

    // Optional log redirection for tests; the default (LOG_DIR/app.log) is set up in Types.swift.
    let env = ProcessInfo.processInfo.environment
    if let d = OrgPolicy.testHookValue("MCAP_LOG_DIR", env: env) {
        Log.fileURL = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true).appendingPathComponent("app.log")
    }

    guard let command = args.first else {
        // Menu-bar app.
        let config = AppConfig.load()
        runMenuBarApp(config: config, logDir: ShellUtil.logDir(for: config))
    }
    let rest = Array(args.dropFirst())

    switch command {
    case "--version", "-v", "version":
        print("\(AppInfo.displayName) \(AppInfo.version)")
        finish(0)

    case "--help", "-h", "help":
        printUsage()
        finish(0)

    case "probe":
        Log.echoToStderr = true
        let config = AppConfig.load()
        finish(runProbe(config: config, watch: rest.contains("--watch"), json: rest.contains("--json")))

    case "selftest-detector":
        Log.echoToStderr = true
        finish(runSelftestDetector())

    case "selftest-capture":
        Log.echoToStderr = true
        // Fail closed: the mode must be chosen explicitly, never default to live (live opens the microphone and the
        // system-audio tap and pops macOS permission dialogs).
        let synthetic = rest.contains("--synthetic"), live = rest.contains("--live")
        if synthetic == live {
            let why = synthetic ? "choose either --synthetic or --live, not both"
                                : "pass --synthetic (no devices, no permissions) or --live (real devices, signed app only)"
            FileHandle.standardError.write(Data("selftest-capture: \(why)\n\n".utf8))
            printUsage()
            finish(2)
        }
        // Live mode raises permission prompts: refuse right here, before any directory or config is touched, unless the signed
        // app was started by launchd / LaunchServices (the in-bundle binary exec'd from a shell has the right bundle id but
        // would get the prompts attributed to the terminal). runLive checks again.
        if live, let refusal = CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: LaunchGuard.isSignedAppLaunch,
                                                                          env: [CapturePermissionGuard.liveSelfTestEnv: "1"]) {
            FileHandle.standardError.write(Data((refusal + "\n").utf8))
            finish(2)
        }
        let config = AppConfig.load()
        var seconds = 5
        if let s = optionValue("--seconds", in: rest) {
            guard let n = Int(s), n > 0 else {
                FileHandle.standardError.write(Data("selftest-capture: --seconds must be a positive integer\n".utf8))
                finish(2)
            }
            seconds = n
        }
        let outPath = optionValue("--out", in: rest) ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("mcap-selftest-capture")
        let outDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath, isDirectory: true)
        // The SPEC signature of runSelftestCapture has no mode parameter; the capture implementation reads
        // MC_SELFTEST_SYNTHETIC=1 / MC_SELFTEST_LIVE=1 instead (CaptureSelfTest.swift; it refuses live unless it runs
        // from the signed app). Set exactly one, so an inherited variable cannot flip the explicit flag.
        if synthetic {
            setenv("MC_SELFTEST_SYNTHETIC", "1", 1)
            unsetenv("MC_SELFTEST_LIVE")
        } else {
            setenv("MC_SELFTEST_LIVE", "1", 1)
            unsetenv("MC_SELFTEST_SYNTHETIC")
        }
        finish(runSelftestCapture(config: config, seconds: seconds, outDir: outDir))

    case "selftest-session":
        // The test prints its own PASS/FAIL lines and redirects app.log to its temp dir; MC_LOG_STDERR=1 still echoes it.
        finish(runSelftestSession())

    case "selftest-policy":
        // Prints its own ok / FAIL lines and a final PASS/FAIL; app.log goes to its temp dir.
        finish(runSelftestPolicy())

    case "selftest-firstrun":
        Log.echoToStderr = false
        Log.fileURL = URL(fileURLWithPath: "/dev/null")
        finish(runSelftestFirstRun(arguments: rest))

    case "policy-status":
        // A status query leaves no trace: no app.log line (MDM runs it as root, and a root-owned log in a user's folder is a bug).
        Log.echoToStderr = false
        Log.fileURL = URL(fileURLWithPath: "/dev/null")
        finish(runPolicyStatus(arguments: rest))

    case "selftest-notify":
        Log.echoToStderr = true
        // Real notifications: from a shell they would belong to the terminal / agent app (or trap): refuse before anything is touched.
        if let refusal = notifySelftestRefusal(signedAppLaunch: LaunchGuard.isSignedAppLaunch) {
            FileHandle.standardError.write(Data(refusal.utf8))
            finish(2)
        }
        var waitSeconds: TimeInterval = 60
        if let w = optionValue("--wait", in: rest) {
            guard let n = Double(w), n >= 0, n <= 600 else {
                FileHandle.standardError.write(Data("selftest-notify: --wait must be a number of seconds between 0 and 600\n".utf8))
                finish(2)
            }
            waitSeconds = n
        }
        let config = AppConfig.load()
        // The main run loop must stay alive (notification callbacks, clicks, the permission prompt): the work runs on a background thread.
        runWithMainRunLoop { runSelftestNotify(config: config, logDir: ShellUtil.logDir(for: config), waitSeconds: waitSeconds) }

    case "setup":
        Log.echoToStderr = true
        // From a shell every prompt would belong to the terminal: refuse before anything is touched (runSetup checks again).
        if let refusal = setupRefusal(signedAppLaunch: LaunchGuard.isSignedAppLaunch, env: env) {
            FileHandle.standardError.write(Data(refusal.utf8))
            finish(2)
        }
        let config = AppConfig.load()
        // The permission helpers may wait for a prompt and may hop to the main queue: keep the main run loop
        // alive (NSApplication, accessory) and run the checklist on a background thread.
        runWithMainRunLoop { runSetup(config: config) }

    default:
        FileHandle.standardError.write(Data("unknown command '\(command)'\n\n".utf8))
        printUsage()
        finish(2)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)      // line-buffer stdout so output is ordered when piped or redirected by `open`
mcapMain()
