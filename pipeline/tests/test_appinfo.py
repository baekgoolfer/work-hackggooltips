"""The names of the app (mcap/appinfo.py): the rules, the three-step lookup (the app that holds the package, the environment, the defaults), and the two places
the pipeline shows the human name. The same rules and defaults as scripts/bundle_id.sh and app/Sources/App.swift (AppInfo): the agreement is checked here and in
scripts/test_scripts.sh. Nothing here looks at ~/Applications or any real app: the apps are made in a temporary folder."""
from __future__ import annotations

import io
import os
import plistlib
import re
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from mcap import appinfo, cli, gcal

REPO = Path(__file__).resolve().parents[2]

# a neutral name that is not the default: used wherever a test needs "another build"
CUSTOM_NAME, CUSTOM_SHORT = "Example Recorder", "ExampleRecorder"


def make_app(root: Path, name: object = None, short: object = None, file_name: str = "ExampleRecorder.app") -> Path:
    """An app folder with an Info.plist that holds only the given names (None leaves the key out)."""
    app = root / file_name
    (app / "Contents").mkdir(parents=True)
    info = {}
    if name is not None:
        info["CFBundleDisplayName"] = name
    if short is not None:
        info["CFBundleName"] = short
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump(info, handle)
    return app


class RulesTest(unittest.TestCase):
    def test_a_name_follows_the_rules_of_the_build_scripts(self) -> None:
        good = [appinfo.DEFAULT_APP_NAME, CUSTOM_NAME, "a", "A-b.c 1", "7 Eleven", "x" * 40]
        bad = ["", " lead", "trail ", "-lead", ".lead", "a&b", "a<b>", 'a"b', "a'b", "a/b", "../x", "a\\b", "a\nb", "a\n", "a\tb", "50%", "é", "名前", "x" * 41, None, 7]
        self.assertEqual([v for v in good if not appinfo.valid_name(v)], [])
        self.assertEqual([v for v in bad if appinfo.valid_name(v)], [])

    def test_a_short_name_follows_the_rules_of_the_build_scripts(self) -> None:
        good = [appinfo.DEFAULT_APP_SHORT_NAME, CUSTOM_SHORT, "a", "A1", "x" * 32]
        bad = ["", "1x", "a b", "a-b", "a.b", "a/b", "../x", "a&b", "a\nb", "a\n", " a", "-a", "é", "x" * 33, None, 7]
        self.assertEqual([v for v in good if not appinfo.valid_short_name(v)], [])
        self.assertEqual([v for v in bad if appinfo.valid_short_name(v)], [])

    def test_the_defaults_are_the_ones_of_the_scripts_and_the_swift_app(self) -> None:
        script = (REPO / "scripts" / "bundle_id.sh").read_text(encoding="utf-8")
        swift = (REPO / "app" / "Sources" / "App.swift").read_text(encoding="utf-8")
        self.assertEqual(re.search(r'^MCAP_DEFAULT_APP_NAME="([^"]*)"$', script, re.M).group(1), appinfo.DEFAULT_APP_NAME)
        self.assertEqual(re.search(r'^MCAP_DEFAULT_APP_SHORT_NAME="([^"]*)"$', script, re.M).group(1), appinfo.DEFAULT_APP_SHORT_NAME)
        self.assertEqual(re.search(r'static let defaultDisplayName = "([^"]*)"', swift).group(1), appinfo.DEFAULT_APP_NAME)
        self.assertEqual(re.search(r'static let defaultShortName = "([^"]*)"', swift).group(1), appinfo.DEFAULT_APP_SHORT_NAME)
        self.assertTrue(appinfo.valid_name(appinfo.DEFAULT_APP_NAME) and appinfo.valid_short_name(appinfo.DEFAULT_APP_SHORT_NAME))


class LookupTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="mcap-appinfo-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        patcher = mock.patch.dict(os.environ)             # restores the whole environment afterwards
        patcher.start()
        self.addCleanup(patcher.stop)
        for key in ("MCAP_APP_NAME", "MCAP_APP_SHORT_NAME"):
            os.environ.pop(key, None)

    def test_without_an_app_and_without_environment_the_defaults(self) -> None:
        self.assertEqual(appinfo.resolve([]), (appinfo.DEFAULT_APP_NAME, appinfo.DEFAULT_APP_SHORT_NAME))
        self.assertEqual(appinfo.resolve([self.tmp / "no-such.app"]), (appinfo.DEFAULT_APP_NAME, appinfo.DEFAULT_APP_SHORT_NAME), "a missing app is not an error")

    def test_the_environment_comes_before_the_defaults(self) -> None:
        with mock.patch.dict(os.environ, {"MCAP_APP_NAME": CUSTOM_NAME, "MCAP_APP_SHORT_NAME": CUSTOM_SHORT}):
            self.assertEqual(appinfo.resolve([]), (CUSTOM_NAME, CUSTOM_SHORT))
            self.assertEqual((appinfo.display_name(), appinfo.short_name()), (CUSTOM_NAME, CUSTOM_SHORT))

    def test_an_empty_or_bad_environment_value_is_not_used(self) -> None:
        with mock.patch.dict(os.environ, {"MCAP_APP_NAME": "", "MCAP_APP_SHORT_NAME": ""}):
            self.assertEqual(appinfo.resolve([]), (appinfo.DEFAULT_APP_NAME, appinfo.DEFAULT_APP_SHORT_NAME), "an empty value counts as unset")
        with mock.patch.dict(os.environ, {"MCAP_APP_NAME": "a&b", "MCAP_APP_SHORT_NAME": "a b"}):
            self.assertEqual(appinfo.resolve([]), (appinfo.DEFAULT_APP_NAME, appinfo.DEFAULT_APP_SHORT_NAME), "the build scripts refuse these; here they are never shown")

    def test_the_app_comes_before_the_environment(self) -> None:
        app = make_app(self.tmp, "Plist Name", "PlistShort")
        with mock.patch.dict(os.environ, {"MCAP_APP_NAME": CUSTOM_NAME, "MCAP_APP_SHORT_NAME": CUSTOM_SHORT}):
            self.assertEqual(appinfo.resolve([app]), ("Plist Name", "PlistShort"))

    def test_each_name_falls_through_on_its_own(self) -> None:
        only_name = make_app(self.tmp, "Plist Name", None, "a.app")
        only_short = make_app(self.tmp, None, "PlistShort", "b.app")
        with mock.patch.dict(os.environ, {"MCAP_APP_NAME": CUSTOM_NAME, "MCAP_APP_SHORT_NAME": CUSTOM_SHORT}):
            self.assertEqual(appinfo.resolve([only_name]), ("Plist Name", CUSTOM_SHORT))
            self.assertEqual(appinfo.resolve([only_short]), (CUSTOM_NAME, "PlistShort"))
            self.assertEqual(appinfo.resolve([only_name, only_short]), ("Plist Name", "PlistShort"), "the first app that has a value wins, per name")

    def test_a_damaged_or_foreign_plist_is_ignored(self) -> None:
        bad_values = make_app(self.tmp, "bad & name\n", "9 bad", "c.app")
        wrong_types = make_app(self.tmp, 5, ["x"], "d.app")
        garbage = self.tmp / "e.app"
        (garbage / "Contents").mkdir(parents=True)
        (garbage / "Contents" / "Info.plist").write_bytes(b"this is not a plist")
        truncated = make_app(self.tmp, CUSTOM_NAME, CUSTOM_SHORT, "f.app")      # cut off in the middle of a tag: the XML parser's own error, not a ValueError
        whole = (truncated / "Contents" / "Info.plist").read_bytes()
        (truncated / "Contents" / "Info.plist").write_bytes(whole[:whole.index(b"<dict>") + 12])
        binary = make_app(self.tmp, CUSTOM_NAME, CUSTOM_SHORT, "g.app")
        with open(binary / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleName": CUSTOM_SHORT}, handle, fmt=plistlib.FMT_BINARY)
        (binary / "Contents" / "Info.plist").write_bytes((binary / "Contents" / "Info.plist").read_bytes()[:20])
        for app in (bad_values, wrong_types, garbage, truncated, binary):
            self.assertEqual(appinfo.resolve([app]), (appinfo.DEFAULT_APP_NAME, appinfo.DEFAULT_APP_SHORT_NAME), app.name)

    def test_the_candidate_is_the_app_that_holds_the_package_and_nothing_else(self) -> None:
        app = make_app(self.tmp, CUSTOM_NAME, CUSTOM_SHORT)
        inside = app / "Contents" / "Resources" / "mcap" / "pipeline" / "mcap"
        inside.mkdir(parents=True)
        self.assertEqual(appinfo.candidate_apps(str(inside / "appinfo.py")), [app])
        self.assertEqual(appinfo.candidate_apps(str(self.tmp / "checkout" / "pipeline" / "mcap" / "appinfo.py")), [], "a checkout has no app around it, and no folder is scanned")


class PlacesTest(unittest.TestCase):
    def test_the_help_text_names_the_app(self) -> None:
        with mock.patch.object(appinfo, "display_name", return_value=CUSTOM_NAME):
            self.assertEqual(cli.build_parser().description, f"{CUSTOM_NAME} post-processing pipeline")
        self.assertNotIn("Meeting Capture", cli.build_parser().format_help())

    def test_the_sign_in_page_title_is_the_human_name(self) -> None:
        for name in (CUSTOM_NAME, appinfo.DEFAULT_APP_NAME):
            handler = object.__new__(gcal._Callback)
            handler.wfile = io.BytesIO()
            handler.send_response = lambda *a, **k: None
            handler.send_header = lambda *a, **k: None
            handler.end_headers = lambda: None
            with mock.patch.object(appinfo, "display_name", return_value=name):
                handler._reply(200, "Signed in.")
            body = handler.wfile.getvalue().decode("ascii")
            self.assertIn(f"<title>{name}</title>", body)
            self.assertIn("<p>Signed in.</p>", body)


if __name__ == "__main__":
    unittest.main()
