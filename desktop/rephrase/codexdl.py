"""Rephrase's own copy of OpenAI's Codex CLI (the ChatGPT engine), so you don't install anything.

Downloaded once from OpenAI's official GitHub releases, checked against the SHA-256 GitHub publishes
for it, and kept next to config.json. It signs in with the same ChatGPT account as any other Codex
on this computer (~/.codex).
"""

import hashlib
import json
import os
import platform
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.request

from . import config

# Shown by the popup while the one-time download runs: {"text": str, "progress": float | None}.
STATUS = {"text": "", "progress": None}


def managed_path() -> str:
    return str(config.config_dir() / "bin" / ("codex.exe" if sys.platform == "win32" else "codex"))


def has_chatgpt_sign_in() -> bool:
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    return os.path.exists(os.path.join(home, "auth.json"))


def _asset_name() -> str:
    machine = platform.machine().lower()
    arch = "aarch64" if machine in ("arm64", "aarch64") else "x86_64"
    if sys.platform == "win32":
        return f"codex-{arch}-pc-windows-msvc.exe.tar.gz"
    if sys.platform == "darwin":
        return f"codex-{arch}-apple-darwin.tar.gz"
    return f"codex-{arch}-unknown-linux-musl.tar.gz"


def ensure() -> str:
    """Returns Codex's path, downloading it first if needed. Raises OSError / ValueError on failure."""
    from .engines import find
    existing = find("codex")
    if existing:
        return existing
    config.log("codex: downloading private copy")
    STATUS.update(text="Setting up ChatGPT… (one-time download)", progress=None)
    try:
        req = urllib.request.Request("https://api.github.com/repos/openai/codex/releases/latest",
                                     headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            release = json.loads(resp.read().decode("utf-8"))
        name = _asset_name()
        asset = next((a for a in release.get("assets", []) if a.get("name") == name), None)
        if not asset or not str(asset.get("digest", "")).startswith("sha256:"):
            raise ValueError(f"Couldn't find {name} in OpenAI's latest Codex release.")
        expected = asset["digest"].split(":", 1)[1].lower()

        with tempfile.TemporaryDirectory(prefix="rephrase-codex-") as tmp:
            archive = os.path.join(tmp, name)
            sha = hashlib.sha256()
            with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as resp, open(archive, "wb") as f:
                total = int(resp.headers.get("Content-Length") or asset.get("size") or 0)
                done = 0
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    sha.update(chunk)
                    done += len(chunk)
                    if total:
                        STATUS.update(text=f"Setting up ChatGPT… {done * 100 // total}% (one-time download)",
                                      progress=done / total)
            if sha.hexdigest() != expected:
                raise ValueError("The Codex download didn't match OpenAI's checksum, so it wasn't used.")

            STATUS.update(text="Setting up ChatGPT… unpacking", progress=None)
            out_dir = os.path.join(tmp, "out")
            with tarfile.open(archive, "r:gz") as tar:
                members = [m for m in tar.getmembers() if m.isfile() and os.path.basename(m.name).startswith("codex")]
                if not members:
                    raise ValueError("The Codex download was empty.")
                member = members[0]
                member.name = os.path.basename(member.name)   # never write outside out_dir
                tar.extract(member, out_dir)
            dest = managed_path()
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.exists(dest):
                os.remove(dest)
            shutil.move(os.path.join(out_dir, member.name), dest)
            os.chmod(dest, os.stat(dest).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        config.log(f"codex: ready at {dest}")
        return dest
    finally:
        STATUS.update(text="", progress=None)
