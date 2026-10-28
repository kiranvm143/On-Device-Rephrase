"""Rewrite engines.

Claude and ChatGPT run your own installed CLI (Claude Code / Codex), which uses the account you
signed into it with. Rephrase never sees or stores a login. Ollama is a free local model.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from . import prompts

ENGINES = ["claude", "chatgpt", "ollama"]

TITLES = {
    "claude": "Claude (your Claude Code login)",
    "chatgpt": "ChatGPT (your Codex login)",
    "ollama": "Local model (Ollama, free)",
}

TIMEOUT = 90


class EngineError(Exception):
    pass


def _find(name: str):
    found = shutil.which(name)
    if found:
        return found
    home = os.path.expanduser("~")
    extra = [
        os.path.join(home, ".local", "bin"),
        os.path.join(home, ".claude", "local"),
        os.path.join(home, ".npm-global", "bin"),
        os.path.join(home, "AppData", "Roaming", "npm"),
        os.path.join(home, "AppData", "Local", "Programs", "claude"),
        "/usr/local/bin",
    ]
    return shutil.which(name, path=os.pathsep.join(extra))


def available(engine: str) -> bool:
    if engine == "claude":
        return _find("claude") is not None
    if engine == "chatgpt":
        return _find("codex") is not None
    if engine == "ollama":
        return _find("ollama") is not None
    return False


def default_engine() -> str:
    for e in ENGINES:
        if available(e):
            return e
    return "claude"


def _run(cmd, stdin_text: str):
    kwargs = {}
    if sys.platform == "win32":
        kwargs["creationflags"] = 0x08000000  # CREATE_NO_WINDOW: no console flash under pythonw
    try:
        return subprocess.run(
            cmd, input=stdin_text, capture_output=True, text=True, encoding="utf-8",
            timeout=TIMEOUT, cwd=tempfile.gettempdir(), **kwargs,
        )
    except subprocess.TimeoutExpired:
        raise EngineError(f"{os.path.basename(cmd[0])} took longer than {TIMEOUT} s.")
    except OSError as e:
        raise EngineError(f"Couldn't start {cmd[0]}: {e}")


def _looks_like_auth_error(text: str) -> bool:
    t = text.lower()
    return any(w in t for w in ("login", "log in", "sign in", "auth", "unauthorized", "401"))


def rewrite_claude(text: str, mode: str, cfg: dict) -> str:
    exe = _find("claude")
    if not exe:
        raise EngineError("Claude Code isn't installed. Install it from claude.com/code, run `claude` once and sign in.")
    # Instructions go in through stdin: Windows .cmd launchers mangle multi-line arguments.
    cmd = [exe, "-p", "--model", cfg.get("claude_model", "haiku"),
           "--tools", "", "--safe-mode", "--no-session-persistence"]
    r = _run(cmd, prompts.instructions(mode) + "\n\n" + prompts.wrap(text))
    out = (r.stdout or "").strip()
    if r.returncode != 0 or not out:
        err = (r.stderr or "") + out
        if _looks_like_auth_error(err):
            raise EngineError("Claude Code isn't signed in. Run `claude` in a terminal and sign in.")
        raise EngineError("Claude Code failed: " + (err.strip().splitlines() or ["unknown error"])[0][:200])
    return out


def rewrite_chatgpt(text: str, mode: str, cfg: dict) -> str:
    exe = _find("codex")
    if not exe:
        raise EngineError("Codex CLI isn't installed. Install it (npm i -g @openai/codex), then run `codex login`.")
    fd, out_file = tempfile.mkstemp(prefix="rephrase-", suffix=".txt")
    os.close(fd)
    try:
        cmd = [exe, "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
               "-c", "model_reasoning_effort=low", "--output-last-message", out_file, "-"]
        r = _run(cmd, prompts.instructions(mode) + "\n\n" + prompts.wrap(text))
        try:
            with open(out_file, encoding="utf-8") as f:
                answer = f.read().strip()
        except OSError:
            answer = ""
        if r.returncode != 0 or not answer:
            err = (r.stderr or "") + (r.stdout or "")
            if _looks_like_auth_error(err):
                raise EngineError("Codex isn't signed in. Run `codex login` and sign in with ChatGPT.")
            raise EngineError("Codex failed: " + (err.strip().splitlines() or ["unknown error"])[-1][:200])
        return answer
    finally:
        try:
            os.remove(out_file)
        except OSError:
            pass


def rewrite_ollama(text: str, mode: str, cfg: dict) -> str:
    body = json.dumps({
        "model": cfg.get("ollama_model", "llama3.2"),
        "stream": False,
        "messages": [
            {"role": "system", "content": prompts.instructions(mode)},
            {"role": "user", "content": prompts.wrap(text)},
        ],
        "options": {"temperature": 0.1 if mode == "fix" else 0.7},
    }).encode()
    url = cfg.get("ollama_url", "http://localhost:11434").rstrip("/") + "/api/chat"
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise EngineError(f"Ollama model not found. Run: ollama pull {cfg.get('ollama_model', 'llama3.2')}")
        raise EngineError(f"Ollama error {e.code}.")
    except (urllib.error.URLError, OSError):
        raise EngineError("Ollama isn't running. Install it from ollama.com and start it.")
    return data.get("message", {}).get("content", "").strip()


def rewrite(text: str, mode: str, engine: str, cfg: dict) -> str:
    fn = {"claude": rewrite_claude, "chatgpt": rewrite_chatgpt, "ollama": rewrite_ollama}[engine]
    return prompts.clean(fn(text, mode, cfg), text)
