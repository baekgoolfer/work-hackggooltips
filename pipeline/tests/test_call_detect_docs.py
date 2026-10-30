"""Calls of other apps (docs/DETECTION.md section 3b): the documentation, the example config and the Swift sources must say the same.

Nothing here runs the app: it reads the Swift sources as text. It guards the places where a bundle id, a name or a default is written twice
(CallApps.swift <-> DETECTION.md, Config.swift <-> CONFIGURATION.md <-> config.env.example <-> README.md / README.ko.md), and the honest-status wording.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def read(rel: str) -> str:
    return (REPO / rel).read_text(encoding="utf-8")


KEYS = {"CALL_DETECT": "known", "CALL_GENERIC_SECONDS": "45", "EXTRA_MEETING_APPS": "<none>", "CALL_BROWSER_URLS": "off"}


class KnownAppTableTests(unittest.TestCase):
    def setUp(self):
        self.swift = read("app/Sources/CallApps.swift")
        self.known = re.findall(r'KnownCallApp\(id: "([^"]+)", name: "([^"]+)", source: \.(installed|listing)\)', self.swift)

    def test_the_table_has_the_apps_of_the_task_and_no_unverified_id(self):
        self.assertEqual(len(self.known), 14)
        names = {n for _i, n, _s in self.known}
        for wanted in ("Cisco Webex", "Slack huddle", "Discord", "FaceTime", "Skype", "GoTo", "Amazon Chime", "BlueJeans", "KakaoTalk", "JANDI"):
            self.assertIn(wanted, names)
        self.assertFalse(any("naver" in i.lower() for i, _n, _s in self.known), "Naver Works has no verifiable bundle id: it is reachable through EXTRA_MEETING_APPS only")
        self.assertEqual(sorted(i for i, _n, s in self.known if s == "installed"),
                         ["com.apple.FaceTime", "com.kakao.KakaoTalkMac", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp"])

    def test_detection_md_lists_every_known_app_with_its_id_and_name(self):
        doc = read("docs/DETECTION.md")
        for bundle_id, name, _source in self.known:
            self.assertRegex(doc, rf"(?m)^\| [^|]+ \| {re.escape(name)} \| `{re.escape(bundle_id)}` \|", f"{name} / {bundle_id} is not in the table of docs/DETECTION.md 3b.2")
        rows = re.findall(r"(?m)^\| [^|]+ \| [^|]+ \| `([A-Za-z0-9._-]+\.[A-Za-z0-9._-]+)` \| ", doc.split("### 3b.2", 1)[1].split("### 3b.3", 1)[0])
        self.assertEqual(sorted(rows), sorted(i for i, _n, _s in self.known), "the table of 3b.2 has an id that the code does not")

    def test_readme_names_the_apps_of_the_table(self):
        readme = read("README.md")
        for name in ("Slack huddles", "Cisco Webex", "Discord", "FaceTime", "Skype", "GoTo", "Amazon Chime", "BlueJeans", "Lark", "KakaoTalk", "WhatsApp", "JANDI"):
            self.assertIn(name, readme)


class ConfigKeyTests(unittest.TestCase):
    def test_every_key_is_parsed_documented_and_in_the_example_with_the_same_default(self):
        config_swift = read("app/Sources/Config.swift")
        config_doc = read("docs/CONFIGURATION.md")
        example = read("config/config.env.example")
        readme, readme_ko = read("README.md"), read("README.ko.md")
        for key, default in KEYS.items():
            self.assertIn(f'"{key}"', config_swift, f"{key} is not parsed by Config.swift")
            self.assertRegex(config_doc, rf"(?m)^\| `{key}` \| `{re.escape(default)}` \|", f"{key} has no row (or another default) in docs/CONFIGURATION.md")
            self.assertRegex(readme, rf"(?m)^\| `{key}` \|", f"{key} has no row in README.md")
            self.assertRegex(readme_ko, rf"(?m)^\| `{key}` \| `{re.escape(default)}` \|", f"{key} has no row (or another default) in README.ko.md")
            m = re.search(rf"(?m)^#? ?{key}=(.*?)(?:[ \t]+#.*)?$", example)
            self.assertIsNotNone(m, f"{key} is not in config/config.env.example")
            if not default.startswith("<"):
                self.assertEqual(m.group(1).strip(), default, f"{key}: the example's value is not the documented default")

    def test_the_defaults_in_the_code_are_the_documented_ones(self):
        config_swift = read("app/Sources/Config.swift")
        self.assertIn("var mode: Mode = .known", config_swift)
        self.assertNotIn("var mode: Mode = .generic", config_swift, "guessing is opt-in: an update without CALL_DETECT must not record apps nobody named")
        self.assertIn("static let defaultGenericSeconds: TimeInterval = 45", config_swift)
        self.assertIn("var browserURLs = false", config_swift)
        self.assertIn("static let genericSecondsRange: ClosedRange<Double> = 10...600", config_swift)
        self.assertIn("10 to 600", read("docs/CONFIGURATION.md"))

    def test_the_example_does_not_enable_meet_or_the_browser_addresses(self):
        example = read("config/config.env.example")
        self.assertRegex(example, r"(?m)^ENABLED_PLATFORMS=zoom,teams\b")
        self.assertNotRegex(example, r"(?m)^CALL_BROWSER_URLS=\s*(1|on|true|yes)")


class PolicyAndScopeTests(unittest.TestCase):
    """The review findings of the platform-detect work: ENABLED_PLATFORMS does not bound calls of other apps, a policy can restrict them, an upgrade says what it records."""

    CALL_KEYS = ("CALL_DETECT", "CALL_GENERIC_SECONDS", "EXTRA_MEETING_APPS", "CALL_BROWSER_URLS")

    def test_the_call_keys_are_on_both_policy_whitelists(self):
        swift = read("app/Sources/Policy.swift")
        whitelist = swift.split("static let whitelist: Set<String> = [", 1)[1].split("]", 1)[0]
        python = read("pipeline/mcap/policy.py").split("DEFAULTS_WHITELIST = frozenset(", 1)[1].split(".split())", 1)[0]
        for key in self.CALL_KEYS:
            self.assertIn(f'"{key}"', whitelist, f"{key} is not on PolicyLayers.whitelist")
            self.assertIn(key, python.split(), f"{key} is not on DEFAULTS_WHITELIST")

    def test_a_managed_mac_without_the_key_is_off_and_a_personal_one_is_known(self):
        config_swift = read("app/Sources/Config.swift")
        self.assertIn("unsetMode: policy.isEnforced ? .off : .known", config_swift)
        self.assertIn("static func build(from values: [String: String], source: String, unsetMode: Mode = .known)", config_swift)
        self.assertRegex(read("docs/DETECTION.md"), r"On a Mac with a policy a `CALL_DETECT` that neither `config.env` nor the policy sets is `off`")
        self.assertRegex(read("docs/CONFIGURATION.md"), r"On a Mac with a policy a `CALL_DETECT` that neither `config.env` nor the policy sets means `off`")

    def test_the_company_template_leaves_the_call_keys_to_the_policy(self):
        template = read("config/config.env.company.template")
        for key in self.CALL_KEYS:
            self.assertNotRegex(template, rf"(?m)^{key}=", f"the template must not set {key}: it would hide the policy's own value")
        self.assertIn("CALL_DETECT", template)

    def test_enabled_platforms_is_documented_as_not_bounding_the_calls_of_other_apps(self):
        for rel, needle in (("README.md", "It does not limit the calls of other apps"),
                            ("docs/CONFIGURATION.md", "does **not** limit the calls of other apps"),
                            ("docs/DETECTION.md", "`ENABLED_PLATFORMS` is the list of Zoom, Teams and Meet only"),
                            ("config/config.env.example", "does NOT limit the calls of other apps")):
            self.assertIn(needle, read(rel), rel)
        for rel in ("README.md", "docs/CONFIGURATION.md"):
            self.assertNotRegex(read(rel), r"\| `ENABLED_PLATFORMS` \| (which platforms start recordings|`zoom,teams` \| Platforms detected automatically)", f"{rel} still has the old contract of ENABLED_PLATFORMS")

    def test_every_text_that_gates_the_login_agent_names_the_other_call_apps(self):
        for rel in ("scripts/make_launchagent.sh", "scripts/install.sh", "docs/INSTALL.md"):
            self.assertIn("the other call apps of the built-in table", read(rel), rel)
        self.assertNotRegex(read("scripts/make_launchagent.sh"), r'echo "Loading the LaunchAgent makes the app record every Zoom / Teams call from every login on \(Google Meet only')

    def test_the_changelog_and_the_privacy_documents_say_that_personal_messengers_are_recorded(self):
        unreleased = read("CHANGELOG.md").split("## [Unreleased]", 1)[1].split("\n## [", 1)[0]
        for needle in ("CALL_DETECT", "personal messengers", "after the update", "Call Apps", "opt-in"):
            self.assertIn(needle, unreleased, f"CHANGELOG [Unreleased] must mention {needle}")
        for rel in ("docs/PRIVACY_AND_CONSENT.md", "SECURITY.md"):
            text = read(rel)
            self.assertIn("CALL_DETECT", text, rel)
            self.assertIn("call-apps.json", text, rel)
        self.assertIn("personal messengers", read("docs/PRIVACY_AND_CONSENT.md"))
        self.assertIn("fails closed", read("SECURITY.md"))

    def test_the_menu_can_reach_every_kind_of_call_app(self):
        controller = read("app/Sources/SessionController.swift")
        menu = read("app/Sources/StatusMenu.swift")
        self.assertNotRegex(controller, r"if signal\.callKind == \.generic, let id = signal\.bundleID \{ callApps\?\.noteRecorded", "only generic recordings are listed")
        self.assertIn("callApps?.noteRecorded(call.decisionKey", controller)
        self.assertNotRegex(menu, r"state\.callApp, call\.generic else", "'Never record <App>' is only offered for generic recordings")
        self.assertIn("static func callAppRows(entries: [CallAppEntry], settings: CallDetectSettings)", menu)
        detection = read("docs/DETECTION.md")
        self.assertIn("**every** recording lists its app as `allowed`", detection)
        self.assertIn("**also before the app's first call**", detection)

    def test_the_documents_describe_the_fail_closed_list_and_the_takeover(self):
        detection = read("docs/DETECTION.md")
        for needle in ("fails closed", "**every call of another app is paused**", "reload()", "A call of another app never blocks Zoom, Teams or Meet", "`CallTracker.genericOutputKeepSeconds`"):
            self.assertIn(needle, detection, needle)
        self.assertNotIn("Known apps and extra apps keep working while the file is unreadable", detection)
        self.assertNotIn("A file that cannot be read pauses the generic rule and is never overwritten", read("docs/CONFIGURATION.md"))
        self.assertIn("One recording at a time", read("docs/CONFIGURATION.md"))


class HonestStatusTests(unittest.TestCase):
    def test_every_document_says_that_only_zoom_is_verified_in_real_calls(self):
        for rel, needles in (("README.md", ("Only Zoom detection was verified in real calls", "only Zoom has been verified in real calls")),
                             ("README.ko.md", ("실제 통화로 확인한 것은 Zoom 감지뿐", "실제 통화로 확인한 것은 Zoom뿐")),
                             ("docs/DETECTION.md", ("Only Zoom has been verified in real",)),
                             ("docs/CONFIGURATION.md", ("Only Zoom has been verified in real calls",)),
                             ("config/config.env.example", ("Only Zoom has been verified in real calls", "검증된 것은 Zoom뿐"))):
            text = read(rel)
            for needle in needles:
                self.assertIn(needle, text, f"{rel} must say: {needle}")

    def test_no_stronger_claim_about_teams_or_the_other_platforms(self):
        for rel in ("README.md", "README.ko.md", "docs/DETECTION.md", "docs/CONFIGURATION.md"):
            text = read(rel)
            self.assertNotIn("Zoom and Teams detection was verified", text, rel)
            self.assertNotIn("Zoom and Teams detection is verified", text, rel)
            self.assertNotIn("Zoom과 Teams 감지는", text, rel)
        status = read("docs/DETECTION.md").split("### 3b.1", 1)[1].split("### 3b.2", 1)[0]
        rows = {m.group(1): m.group(0) for m in re.finditer(r"(?m)^\| ([^|]+?) \|.*$", status)}
        self.assertIn("verified in real calls", rows["Zoom"])
        self.assertIn("not verified in a real call yet", rows["Microsoft Teams"])
        for name in ("Google Meet", "Known call apps (3b.2)", "`EXTRA_MEETING_APPS` apps", "Meeting page in Chrome (3b.5)", "Generic app (3b.3)"):
            self.assertIn("not verified", rows[name], name)
        self.assertIn("unit-tested with fakes", status)

    def test_the_install_texts_for_anybody_who_gets_a_copy_say_which_calls_are_recorded(self):
        # the guide in each language, the note in the disk image and the end of the helper: all say the same honest thing
        for rel, needles in (("docs/USER_GUIDE.md", ("personal messengers", "Google Meet is off by default", "Call Apps", "only Zoom calls")),
                             ("docs/USER_GUIDE.ko.md", ("개인 메신저", "Google Meet는 기본으로 꺼져", "Call Apps", "Zoom 통화뿐")),
                             ("dmg/README-install.txt", ("Zoom, Teams and other call apps", "not Google Meet by default", "KakaoTalk")),
                             ("scripts/first_run_install.sh", ("Google Meet is not by default", "Call Apps", "Only Zoom calls have been verified"))):
            text = read(rel)
            for needle in needles:
                self.assertIn(needle, text, f"{rel} must say: {needle}")


class ProductNameTests(unittest.TestCase):
    """The product is Catch Everything (short name CATE): the documents say so, and the defaults they name are the ones of the code."""

    def test_the_documented_defaults_are_the_ones_of_the_code(self):
        from mcap import appinfo
        library = read("scripts/bundle_id.sh")
        self.assertIn(f'MCAP_DEFAULT_APP_NAME="{appinfo.DEFAULT_APP_NAME}"', library)
        self.assertIn(f'MCAP_DEFAULT_APP_SHORT_NAME="{appinfo.DEFAULT_APP_SHORT_NAME}"', library)
        config = read("docs/CONFIGURATION.md")
        self.assertRegex(config, rf"(?m)^\| `MCAP_APP_NAME` \| `{re.escape(appinfo.DEFAULT_APP_NAME)}` \|")
        self.assertRegex(config, rf"(?m)^\| `MCAP_APP_SHORT_NAME` \| `{re.escape(appinfo.DEFAULT_APP_SHORT_NAME)}` \|")
        self.assertRegex(config, r"(?m)^\| `MCAP_BUNDLE_ID` \| `org\.meetingcapture\.app` \|")

    def test_the_entry_documents_name_the_product_the_short_name_and_the_files_of_the_default_build(self):
        for rel in ("README.md", "README.ko.md", "docs/USER_GUIDE.md", "docs/USER_GUIDE.ko.md", "docs/DISTRIBUTE.md"):
            text = read(rel)
            self.assertIn("Catch Everything", text, rel)
            self.assertRegex(text, r"\bCATE\b", rel)
            self.assertIn("CATE.app", text, rel)
            self.assertRegex(text, r"CATE-<(version|버전)>\.dmg", rel)
        for rel in ("README.md", "README.ko.md"):
            self.assertTrue(read(rel).startswith("# Catch Everything (CATE)\n"), f"{rel}: the title is the product name")

    def test_the_old_name_is_not_the_title_of_any_document(self):
        for rel in ("README.md", "README.ko.md", "CONTRIBUTING.md", "SPEC.md", "docs/USER_GUIDE.md", "docs/USER_GUIDE.ko.md", "NOTICE"):
            first = read(rel).splitlines()[0]
            self.assertNotRegex(first, r"(?i)meeting ?capture", f"{rel}: {first}")

    def test_the_documents_that_give_a_command_name_the_app_file_of_the_default_build(self):
        for rel, command in (("README.md", "open -n -W -a ~/Applications/CATE.app"), ("README.ko.md", "open -n -W -a ~/Applications/CATE.app"), ("docs/INSTALL.md", "open -n -W -a ~/Applications/CATE.app"),
                             ("docs/LIVE_TEST.en.md", "APP=~/Applications/CATE.app"), ("docs/LIVE_TEST.md", "APP=~/Applications/CATE.app")):
            text = read(rel)
            self.assertIn(command, text, rel)
            self.assertNotIn("MeetingCapture.app", text.replace("have the app file `MeetingCapture.app`", ""), rel)


if __name__ == "__main__":
    unittest.main()
