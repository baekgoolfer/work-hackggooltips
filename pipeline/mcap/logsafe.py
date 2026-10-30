"""Log-safe views of meeting content (``LOG_CONTENT``).

The pipeline log may carry short pieces of transcript text (the removed segments and the suppressed echo of ``asr.py``): useful for
tuning, but meeting content all the same. ``configure(False)`` (``LOG_CONTENT=0``, the company baseline) turns every such piece into
its length and a short hash, enough to tell two pieces apart without reading them:

    snip("Thanks for watching, see you next week")  ->  "Thanks for watching, see you next week"      (default: unchanged)
    configure(False); snip("Thanks for watching, see you next week")  ->  "<38 chars sha1:3b6370>"

The default (``content=True``) returns exactly ``text[:n]``, the slice the log calls used before this module existed, so nothing
changes for a personal install. The setting is process-wide (a run applies it from its config before it logs anything).

``prune_logs`` is the age rule for the pipeline logs: ``LOG_RETENTION_DAYS`` (default 0 = keep: today nothing
in LOG_DIR is ever deleted, so switching it on is a decision of the installation, the company template sets 30). It looks at
``pipeline-*.log`` only; ``app.log`` and its archives belong to the Swift app (LogRotation).
"""
from __future__ import annotations

import hashlib
import logging
import os
import re
import stat as statmod
import time
from datetime import datetime
from pathlib import Path
from typing import Optional, Union

log = logging.getLogger("mcap.logsafe")

_content = True            # True: pieces of text may appear in the log (today's behaviour)
PIPELINE_LOG = re.compile(r"pipeline-[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.log\Z")      # what PipelineLauncher writes (session id, reprocess-<epoch>, retry-sweep)


def configure(content: bool) -> None:
    """``content`` False = never log text, only ``<N chars sha1:xxxxxx>`` (LOG_CONTENT=0)."""
    global _content
    _content = bool(content)


def content_allowed() -> bool:
    return _content


def snip(text, n: int = 60) -> str:
    """At most ``n`` characters of ``text`` for a log line; with content logging off ``<LEN chars sha1:6hex>`` of the WHOLE text
    (the length and the digest identify it without revealing it). Anything that is not a string is converted with ``str``."""
    if text is None:
        text = ""
    elif not isinstance(text, str):
        text = str(text)
    if _content:
        return text[:n]
    return f"<{len(text)} chars sha1:{hashlib.sha1(text.encode('utf-8', 'surrogatepass'), usedforsecurity=False).hexdigest()[:6]}>"


def prune_logs(cfg, now: Optional[Union[float, datetime]] = None, dry_run: bool = False) -> list[Path]:
    """Delete the ``pipeline-*.log`` files of ``cfg.log_dir`` that were last written more than ``LOG_RETENTION_DAYS`` days ago; returns the
    paths (deleted, or with ``dry_run`` the ones that would be). ``LOG_RETENTION_DAYS`` 0 (the default) keeps everything and returns [].

    Only regular files directly in the log directory with the exact name shape of a pipeline log are considered (no symbolic link is
    followed or removed, ``app.log`` and its archives are never touched, nothing outside LOG_DIR). A log that is being written has a recent
    modification time, so the age rule cannot reach it. ``now`` is an epoch or a datetime (tests). Never raises: housekeeping must not be
    able to influence the result of a run."""
    days = int(getattr(cfg, "log_retention_days", 0) or 0)
    if days <= 0:
        return []
    moment = time.time() if now is None else (now.timestamp() if isinstance(now, datetime) else float(now))
    cutoff = moment - days * 86400.0
    removed: list[Path] = []
    try:
        directory = Path(cfg.log_dir)
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    for name in names:
        if not PIPELINE_LOG.fullmatch(name):
            continue
        path = directory / name
        try:
            info = os.lstat(path)
            if not statmod.S_ISREG(info.st_mode) or info.st_mtime >= cutoff:          # lstat: a symbolic link is not a regular file
                continue
            if not dry_run:
                os.unlink(path)
            removed.append(path)
        except OSError as exc:
            log.debug("log %s was not removed: %s", name, exc)
    return removed
