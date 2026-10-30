"""The app installer (scripts/build_dmg.sh) puts the Python package at <app>/Contents/Resources/mcap/pipeline/mcap and the config examples at
<app>/Contents/Resources/mcap/config. The Swift app starts the pipeline from there (Config.swift ``bundledProjectDir``), with no PROJECT_DIR in config.env.
These tests copy the package into a fake bundle and run it from there, the way the launcher does (cwd = mcap/pipeline), and check that the Python side
finds what it needs next to itself: the prompts through ``note.prompt_candidates`` (the checkout the package lives in), the vocabulary through the copy the
first-run helper puts into SUPPORT_DIR."""
from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from mcap import appinfo

REPO = Path(__file__).resolve().parents[2]
CONFIG_FILES = ("note_prompt.md", "cleanup_prompt.md", "verify_prompt.md", "vocabulary.txt", "config.env.example")

PROBE = """
import json, sys
from pathlib import Path
from mcap import appinfo, note, pipeline
from mcap.config import Config
cfg = Config()
cfg.support_dir = Path(sys.argv[1])
cfg.project_dir = Path(sys.argv[2])
out = {"module": str(Path(note.__file__).resolve()),
       "prompts": {name: str(note.resolve_prompt(cfg, name)) for name in ("note_prompt.md", "cleanup_prompt.md", "verify_prompt.md")},
       "vocab_terms": len(pipeline.load_vocab_for(cfg).terms),
       "names": list(appinfo.resolve())}
print(json.dumps(out))
"""


class BundleLayoutTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="mcap-bundle-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.mcap = self.tmp / f"{appinfo.DEFAULT_APP_SHORT_NAME}.app" / "Contents" / "Resources" / "mcap"
        (self.mcap / "pipeline").mkdir(parents=True)
        shutil.copytree(REPO / "pipeline" / "mcap", self.mcap / "pipeline" / "mcap", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        (self.mcap / "config").mkdir()
        for name in CONFIG_FILES:
            shutil.copy(REPO / "config" / name, self.mcap / "config" / name)
        self.support = self.tmp / "support"
        self.support.mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()

    def run_probe(self) -> dict:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home), "PYTHONPATH": str(self.mcap / "pipeline"), "PYTHONDONTWRITEBYTECODE": "1"}
        done = subprocess.run([sys.executable, "-c", PROBE, str(self.support), str(self.tmp / "no-such-project-dir")], cwd=self.mcap / "pipeline", env=env,
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout.strip().splitlines()[-1])

    def test_the_names_come_from_the_app_that_holds_the_package(self) -> None:
        self.assertEqual(self.run_probe()["names"], [appinfo.DEFAULT_APP_NAME, appinfo.DEFAULT_APP_SHORT_NAME], "no names in the plist, no environment: the defaults")
        app = self.mcap.parents[2]                                   # <app>/Contents/Resources/mcap -> <app>
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleDisplayName": "Example Recorder", "CFBundleName": "ExampleRecorder"}, handle)
        self.assertEqual(self.run_probe()["names"], ["Example Recorder", "ExampleRecorder"], "the Info.plist of the app is the one source, as for the Swift app and the scripts")

    def test_prompts_come_from_the_bundle_without_project_dir(self) -> None:
        got = self.run_probe()
        self.assertTrue(got["module"].startswith(str(self.mcap / "pipeline")), "the package of the bundle is the one that ran: %s" % got["module"])
        for name, path in got["prompts"].items():
            self.assertEqual(Path(path).resolve(), (self.mcap / "config" / name).resolve(), name)

    def test_a_user_override_in_support_dir_still_wins(self) -> None:
        (self.support / "note_prompt.md").write_text("my own prompt\n", encoding="utf-8")
        got = self.run_probe()
        self.assertEqual(Path(got["prompts"]["note_prompt.md"]).resolve(), (self.support / "note_prompt.md").resolve())
        self.assertEqual(Path(got["prompts"]["cleanup_prompt.md"]).resolve(), (self.mcap / "config" / "cleanup_prompt.md").resolve())

    def test_the_vocabulary_is_the_copy_in_support_dir(self) -> None:
        self.assertEqual(self.run_probe()["vocab_terms"], 0, "without the helper's copy there is no vocabulary (and no error)")
        shutil.copy(self.mcap / "config" / "vocabulary.txt", self.support / "vocabulary.txt")      # what scripts/first_run_install.sh does
        self.assertGreater(self.run_probe()["vocab_terms"], 0)

    def test_the_file_lists_of_build_dmg_are_what_this_layout_test_copies_and_exist(self) -> None:
        # The layout itself is checked where it is built: scripts/test_scripts.sh runs build_dmg.sh (stub hdiutil and codesign) with the real package and runs
        # the probe above's logic against the result. Here only the lists the script copies are read from it (not grepped for literal lines), so the copy
        # of this test and the script cannot drift apart unnoticed.
        build = (REPO / "scripts" / "build_dmg.sh").read_text(encoding="utf-8")
        lists = {}
        for name in ("PIPELINE_FILES", "CONFIG_FILES", "SCRIPT_FILES"):
            found = re.search(r'^%s="([^"]*)"' % name, build, re.M)
            self.assertIsNotNone(found, name)
            lists[name] = found.group(1).split()
        self.assertEqual(lists["CONFIG_FILES"], list(CONFIG_FILES))
        for name, folder in (("PIPELINE_FILES", "pipeline"), ("CONFIG_FILES", "config"), ("SCRIPT_FILES", "scripts")):
            for f in lists[name]:
                self.assertTrue((REPO / folder / f).is_file(), "%s names %s/%s, which does not exist" % (name, folder, f))


if __name__ == "__main__":
    unittest.main()
