"""The names of the app, learned the way scripts/bundle_id.sh and the Swift app (``AppInfo``) learn them.

The app has a human name (``CFBundleDisplayName``, build input ``MCAP_APP_NAME``, default "Catch Everything") and a file-safe short name
(``CFBundleName``, ``MCAP_APP_SHORT_NAME``, default "CATE": the app folder ``<short>.app`` and its program). The Info.plist of the app that holds this
package (the disk-image install keeps the pipeline inside the app) comes first, then the environment, then the defaults. A pipeline run from a checkout or
from a company release has no app around it: the environment answers there, and the app hands it its own two names whenever it starts the pipeline
(``PipelineLauncher.sanitizedEnvironment``; the company shim sets them too), so the same build gives the same names in the app and here. Run by hand
without that environment, a checkout shows the defaults. Nothing outside the package's own folders is looked at (no scan of ~/Applications). A value that
breaks the rules of scripts/bundle_id.sh is ignored (a damaged plist) and never reaches a message or a page.

Not names of the product, and not derived from these: the data folder and the Keychain items (``MeetingCapture``), the package ``mcap``.
"""
from __future__ import annotations

import os
import plistlib
import re
from pathlib import Path
from typing import Iterable, NamedTuple, Optional

# Equal to MCAP_DEFAULT_APP_NAME / MCAP_DEFAULT_APP_SHORT_NAME of scripts/bundle_id.sh and to AppInfo.defaultDisplayName / defaultShortName of
# app/Sources/App.swift: scripts/test_scripts.sh and the tests of this module check it.
DEFAULT_APP_NAME = "Catch Everything"
DEFAULT_APP_SHORT_NAME = "CATE"

# the rules of scripts/bundle_id.sh (ASCII only; fullmatch, so a trailing newline does not slip through)
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 .-]{0,39}", re.ASCII)
_SHORT_NAME = re.compile(r"[A-Za-z][A-Za-z0-9]{0,31}", re.ASCII)


class AppNames(NamedTuple):
    name: str          # the human name
    short_name: str    # the file-safe short name


def valid_name(value: object) -> bool:
    return isinstance(value, str) and _NAME.fullmatch(value) is not None and not value.endswith(" ")


def valid_short_name(value: object) -> bool:
    return isinstance(value, str) and _SHORT_NAME.fullmatch(value) is not None


def _plist_names(app: Path) -> tuple[Optional[str], Optional[str]]:
    """(CFBundleDisplayName, CFBundleName) of ``app``/Contents/Info.plist, each None when missing or not valid."""
    try:
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except Exception:       # a damaged plist is ignored, whatever way the parser fails (truncated XML raises ExpatError, not ValueError): this runs on every CLI start
        return None, None
    if not isinstance(info, dict):
        return None, None
    name, short = info.get("CFBundleDisplayName"), info.get("CFBundleName")
    return (name if valid_name(name) else None), (short if valid_short_name(short) else None)


def _env_name(variable: str, ok, default: str) -> str:
    value = os.environ.get(variable, "")
    return value if value and ok(value) else default      # an empty value counts as unset; a bad one is not used (the build scripts refuse it)


def _enclosing_app(start: Path) -> Optional[Path]:
    """The ``*.app`` folder that holds ``start`` (the pipeline of a disk-image install lives in <app>/Contents/Resources/mcap), else None."""
    for parent in start.resolve().parents:
        if parent.suffix == ".app":
            return parent
    return None


def candidate_apps(module_file: Optional[str] = None) -> list[Path]:
    """The apps whose Info.plist may tell the names: the app this package sits in, if any."""
    own = _enclosing_app(Path(module_file or __file__))
    return [own] if own is not None else []


def resolve(apps: Optional[Iterable[Path]] = None) -> AppNames:
    """The names: the first app in ``apps`` (default: ``candidate_apps()``) that has a valid value, else the environment, else the defaults."""
    name = short = None
    for app in (candidate_apps() if apps is None else apps):
        plist_name, plist_short = _plist_names(app)
        name, short = name or plist_name, short or plist_short
        if name and short:
            break
    return AppNames(name or _env_name("MCAP_APP_NAME", valid_name, DEFAULT_APP_NAME),
                    short or _env_name("MCAP_APP_SHORT_NAME", valid_short_name, DEFAULT_APP_SHORT_NAME))


def display_name() -> str:
    return resolve().name


def short_name() -> str:
    return resolve().short_name
